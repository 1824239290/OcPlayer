using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace OcPlayer.Core;

/// Owns a Core handle and its UTF-8 C ABI. The shared native image stays loaded
/// for the process; each SafeHandle survives all native calls that borrow it.
public sealed class OcpCore : IDisposable
{
    private readonly CoreHandle _handle;
    private readonly object _state = new();
    private readonly HashSet<string> _requests = new(StringComparer.Ordinal);
    private readonly CancellationTokenSource _shutdown = new();
    private bool _disposed;

    public OcpCore(string configJson = "{}", string? libraryPath = null)
    {
        Native.Configure(libraryPath);
        ValidateObject(configJson, nameof(configJson));
        if (AbiVersion != 1) throw new InvalidOperationException("Unsupported OcPlayer Core ABI version.");
        var pointer = Native.Create(configJson);
        if (pointer == IntPtr.Zero) throw new InvalidOperationException(LastError());
        _handle = new CoreHandle(pointer);
    }

    public static uint AbiVersion => Native.AbiVersion();

    public string Call(string method, string argumentsJson = "{}")
    {
        ValidateName(method, nameof(method));
        ValidateObject(argumentsJson, nameof(argumentsJson));
        ThrowIfDisposed();
        return CallNative(method, argumentsJson);
    }

    /// Reserves the request before registering cancellation or dispatching work.
    /// Control calls remain available while a blocking command is executing.
    public async Task<string> CallAsync(string method, string argumentsJson = "{}", CancellationToken cancellationToken = default)
    {
        ValidateName(method, nameof(method));
        ValidateObject(argumentsJson, nameof(argumentsJson));
        cancellationToken.ThrowIfCancellationRequested();
        CancellationTokenSource linked;
        lock (_state)
        {
            ThrowIfDisposedLocked();
            linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _shutdown.Token);
        }
        using (linked)
        {
            var token = linked.Token;
            token.ThrowIfCancellationRequested();
            if (method is "request.prepare" or "request.cancel")
            {
                var control = await Task.Run(() => Call(method, argumentsJson), CancellationToken.None).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
                return control;
            }
            var arguments = JsonNode.Parse(argumentsJson)!.AsObject();
            string id;
            if (arguments.TryGetPropertyValue("requestId", out var existing) && existing is not null)
            {
                if (existing is not JsonValue value || !value.TryGetValue<string>(out var supplied))
                    throw new ArgumentException("requestId must be a string.", nameof(argumentsJson));
                id = supplied;
            }
            else id = Guid.NewGuid().ToString("N");
            ValidateName(id, "requestId");
            arguments["requestId"] = id;
            var json = arguments.ToJsonString();
            var controlJson = JsonSerializer.Serialize(new { requestId = id });
            lock (_state)
            {
                ThrowIfDisposedLocked();
                token.ThrowIfCancellationRequested();
                if (!_requests.Add(id)) throw new InvalidOperationException("requestId is already in use.");
                try
                {
                    using var result = JsonDocument.Parse(CallNative("request.prepare", controlJson));
                    if (!result.RootElement.GetProperty("ok").GetBoolean())
                        throw new InvalidOperationException(result.RootElement.GetProperty("message").GetString());
                }
                catch { _requests.Remove(id); throw; }
            }
            try
            {
                using var registration = token.Register(() => CancelNative(controlJson));
                // Even a cancelled queued command enters Core to consume its
                // reserved token. SafeHandle protects a running call on Dispose.
                var result = await Task.Run(() => CallNative(method, json), CancellationToken.None).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
                return result;
            }
            catch (ObjectDisposedException) when (token.IsCancellationRequested)
            {
                throw new OperationCanceledException(token);
            }
            finally { lock (_state) _requests.Remove(id); }
        }
    }

    public string Snapshot(string kind = "core")
    {
        ValidateName(kind, nameof(kind));
        ThrowIfDisposed();
        return TakeString(Native.Snapshot(_handle, kind));
    }

    public string? PollEvent()
    {
        ThrowIfDisposed();
        var result = Native.PollEvent(_handle, out var pointer);
        if (result < 0) throw new InvalidOperationException(LastError());
        return result == 0 ? null : TakeString(pointer);
    }

    public void AttachSurface(ulong nativeHandle, uint width, uint height, double scale, uint kind)
    {
        ValidateScale(scale);
        ThrowIfDisposed();
        Native.AttachSurface(_handle, nativeHandle, width, height, scale, kind);
    }
    public void ResizeSurface(uint width, uint height, double scale)
    {
        ValidateScale(scale);
        ThrowIfDisposed();
        Native.ResizeSurface(_handle, width, height, scale);
    }
    public void DetachSurface() { ThrowIfDisposed(); Native.DetachSurface(_handle); }
    public void RenderTick(double timeSeconds)
    {
        if (!double.IsFinite(timeSeconds)) throw new ArgumentOutOfRangeException(nameof(timeSeconds));
        ThrowIfDisposed();
        Native.RenderTick(_handle, timeSeconds);
    }

    public void Dispose()
    {
        lock (_state)
        {
            if (_disposed) return;
            _disposed = true;
        }
        try { _shutdown.Cancel(); }
        finally { _handle.Dispose(); _shutdown.Dispose(); }
        GC.SuppressFinalize(this);
    }

    private void ThrowIfDisposed() { lock (_state) ThrowIfDisposedLocked(); }
    private void ThrowIfDisposedLocked()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(OcpCore));
    }
    private string CallNative(string method, string argumentsJson) => TakeString(Native.Call(_handle, method, argumentsJson));
    private void CancelNative(string controlJson)
    {
        try { _ = CallNative("request.cancel", controlJson); }
        catch (ObjectDisposedException) { }
        catch (InvalidOperationException) { /* Cancellation is best effort; preserve the original call outcome. */ }
    }
    private static void ValidateScale(double scale)
    {
        if (!double.IsFinite(scale) || scale <= 0) throw new ArgumentOutOfRangeException(nameof(scale));
    }
    private static void ValidateName(string name, string parameter)
    {
        if (string.IsNullOrEmpty(name) || name.IndexOf('\0') >= 0)
            throw new ArgumentException("A nonempty UTF-8 name without NUL is required.", parameter);
    }
    private static void ValidateObject(string json, string parameter)
    {
        ArgumentNullException.ThrowIfNull(json, parameter);
        using var document = JsonDocument.Parse(json);
        if (document.RootElement.ValueKind != JsonValueKind.Object)
            throw new ArgumentException("Core JSON arguments must be an object.", parameter);
    }
    private static string TakeString(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero) throw new InvalidOperationException(LastError());
        try { return Marshal.PtrToStringUTF8(pointer) ?? string.Empty; }
        finally { Native.FreeString(pointer); }
    }
    private static string LastError()
    {
        var pointer = Native.LastErrorMessage();
        if (pointer == IntPtr.Zero) return "OcPlayer Core call failed.";
        try { return Marshal.PtrToStringUTF8(pointer) ?? "OcPlayer Core call failed."; }
        finally { Native.FreeString(pointer); }
    }

    private sealed class CoreHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        internal CoreHandle(IntPtr pointer) : base(true) => SetHandle(pointer);
        protected override bool ReleaseHandle() { Native.Destroy(handle); return true; }
    }

    private static class Native
    {
        private const string Library = "ocp_ffi";
        private static readonly object ImageLock = new();
        private static string? _path;
        private static IntPtr _image;
        private static readonly string[] Exports = {
            "ocp_core_create", "ocp_core_destroy", "ocp_core_abi_version", "ocp_call",
            "ocp_snapshot", "ocp_poll_event", "ocp_attach_surface", "ocp_resize_surface",
            "ocp_detach_surface", "ocp_render_tick", "ocp_string_free", "ocp_last_error_message"
        };
        static Native() => NativeLibrary.SetDllImportResolver(typeof(OcpCore).Assembly, Resolve);
        internal static void Configure(string? path)
        {
            if (path is null) return;
            path = Path.GetFullPath(path);
            lock (ImageLock)
            {
                if (_image != IntPtr.Zero && !(OperatingSystem.IsWindows() ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal).Equals(path, _path))
                    throw new InvalidOperationException("Configure the Core library before its first native call; one image is used per assembly.");
                _path = path;
            }
        }
        private static IntPtr Resolve(string name, Assembly assembly, DllImportSearchPath? searchPath)
        {
            if (name != Library) return IntPtr.Zero;
            lock (ImageLock)
            {
                if (_image != IntPtr.Zero) return _image;
                _path ??= Environment.GetEnvironmentVariable("OCP_CORE_LIBRARY_PATH");
                if (!string.IsNullOrEmpty(_path)) _path = Path.GetFullPath(_path);
                var image = string.IsNullOrEmpty(_path) ? NativeLibrary.Load(name, assembly, searchPath) : NativeLibrary.Load(_path);
                try { foreach (var symbol in Exports) _ = NativeLibrary.GetExport(image, symbol); }
                catch { NativeLibrary.Free(image); throw; }
                _image = image;
                return image;
            }
        }
        [DllImport(Library, EntryPoint = "ocp_core_create", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr Create([MarshalAs(UnmanagedType.LPUTF8Str)] string json);
        [DllImport(Library, EntryPoint = "ocp_core_destroy", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void Destroy(IntPtr core);
        [DllImport(Library, EntryPoint = "ocp_core_abi_version", CallingConvention = CallingConvention.Cdecl)]
        internal static extern uint AbiVersion();
        [DllImport(Library, EntryPoint = "ocp_call", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr Call(CoreHandle core, [MarshalAs(UnmanagedType.LPUTF8Str)] string method, [MarshalAs(UnmanagedType.LPUTF8Str)] string arguments);
        [DllImport(Library, EntryPoint = "ocp_snapshot", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr Snapshot(CoreHandle core, [MarshalAs(UnmanagedType.LPUTF8Str)] string kind);
        [DllImport(Library, EntryPoint = "ocp_poll_event", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int PollEvent(CoreHandle core, out IntPtr json);
        [DllImport(Library, EntryPoint = "ocp_attach_surface", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void AttachSurface(CoreHandle core, ulong handle, uint width, uint height, double scale, uint kind);
        [DllImport(Library, EntryPoint = "ocp_resize_surface", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void ResizeSurface(CoreHandle core, uint width, uint height, double scale);
        [DllImport(Library, EntryPoint = "ocp_detach_surface", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void DetachSurface(CoreHandle core);
        [DllImport(Library, EntryPoint = "ocp_render_tick", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void RenderTick(CoreHandle core, double seconds);
        [DllImport(Library, EntryPoint = "ocp_string_free", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void FreeString(IntPtr value);
        [DllImport(Library, EntryPoint = "ocp_last_error_message", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr LastErrorMessage();
    }
}

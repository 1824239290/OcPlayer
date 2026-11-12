using System.Text.Json;
using System.Runtime.InteropServices;

namespace OcPlayer.CoreAdapter;

public sealed class OcpCoreClient : IDisposable
{
    private readonly IntPtr _handle;
    private bool _disposed;

    public OcpCoreClient(string? configJson = null)
    {
        _handle = OcpCoreNative.Create(configJson ?? "{}");
        if (_handle == IntPtr.Zero)
            throw new InvalidOperationException(ReadLastError("Unable to create OcPlayer core."));
    }

    public static uint AbiVersion => OcpCoreNative.AbiVersion();

    public OcpResponse Ping() => Call("ping", "{}");

    public OcpResponse Call(string method, object? arguments = null)
    {
        ThrowIfDisposed();
        var argumentsJson = arguments is null ? "{}" : JsonSerializer.Serialize(arguments);
        var value = OcpCoreNative.Call(_handle, method, argumentsJson);
        return DeserializeResponse(value);
    }

    public JsonDocument Snapshot(string kind = "core")
    {
        ThrowIfDisposed();
        var value = OcpCoreNative.Snapshot(_handle, kind);
        return DeserializeDocument(value);
    }

    public bool TryPollEvent(out OcpEvent? value)
    {
        ThrowIfDisposed();
        var result = OcpCoreNative.PollEvent(_handle, out var eventPointer);
        if (result < 0)
            throw new InvalidOperationException(ReadLastError("Unable to poll core event."));
        if (result == 0)
        {
            value = null;
            return false;
        }

        using var document = ReadAndFree(eventPointer);
        value = document.Deserialize<OcpEvent>();
        return value is not null;
    }

    public void AttachSurface(ulong nativeHandle, uint width, uint height, double scale, uint surfaceKind = 1)
        => OcpCoreNative.AttachSurface(_handle, nativeHandle, width, height, scale, surfaceKind);

    public void ResizeSurface(uint width, uint height, double scale)
        => OcpCoreNative.ResizeSurface(_handle, width, height, scale);

    public void DetachSurface() => OcpCoreNative.DetachSurface(_handle);

    public void RenderTick(double timeSeconds) => OcpCoreNative.RenderTick(_handle, timeSeconds);

    public void Dispose()
    {
        if (_disposed) return;
        OcpCoreNative.Destroy(_handle);
        _disposed = true;
        GC.SuppressFinalize(this);
    }

    private OcpResponse DeserializeResponse(IntPtr pointer)
    {
        using var document = ReadAndFree(pointer);
        return document.Deserialize<OcpResponse>()
            ?? throw new InvalidOperationException("OcPlayer core returned an empty response.");
    }

    private static JsonDocument DeserializeDocument(IntPtr pointer)
    {
        return ReadAndFree(pointer);
    }

    private static JsonDocument ReadAndFree(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero)
            throw new InvalidOperationException(ReadLastError("OcPlayer core returned a null string."));
        try
        {
            var json = Marshal.PtrToStringUTF8(pointer)
                ?? throw new InvalidOperationException("OcPlayer core returned invalid UTF-8.");
            return JsonDocument.Parse(json);
        }
        finally
        {
            OcpCoreNative.FreeString(pointer);
        }
    }

    private static string ReadLastError(string fallback)
    {
        var pointer = OcpCoreNative.LastErrorMessage();
        if (pointer == IntPtr.Zero) return fallback;
        try { return Marshal.PtrToStringUTF8(pointer) ?? fallback; }
        finally { OcpCoreNative.FreeString(pointer); }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(OcpCoreClient));
    }
}

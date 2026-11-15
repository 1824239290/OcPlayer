using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace OcPlayer.CoreAdapter;

/// Native Windows decoding, WASAPI audio and D3D11 presentation. All calls on
/// one presenter belong to its creating UI thread, as required by Erika's ABI.
public sealed class ErikaPresenter : IDisposable
{
    private readonly PresenterHandle _handle;
    private readonly int _threadId = Environment.CurrentManagedThreadId;
    private bool _disposed;

    public ErikaPresenter()
    {
        var pointer = Native.Create(new PresenterConfig { OutputMode = 3, Headroom = 10000f / 203f });
        if (pointer == IntPtr.Zero) throw new InvalidOperationException(LastError());
        _handle = new PresenterHandle(pointer);
    }

    public void Attach(ulong hwnd, uint width, uint height, double scale)
    {
        CheckThread();
        Check(Native.Attach(_handle, 4, hwnd, 0, width, height, scale,
            new OutputCapabilities { DirectComposition = true, DesiredHeadroom = 10000f / 203f }));
    }

    public void Resize(uint width, uint height, double scale)
    {
        CheckThread();
        Check(Native.Resize(_handle, width, height, scale));
    }

    /// Returns an owned COM reference. The caller must Marshal.Release it.
    public IntPtr GetSwapChain()
    {
        CheckThread();
        Check(Native.SwapChain(_handle, out var pointer));
        return pointer;
    }

    public JsonElement Invoke(string method, object? arguments = null)
    {
        CheckThread();
        var pointer = Native.Invoke(_handle, method, JsonSerializer.Serialize(arguments ?? new { }));
        return ReadResponse(pointer);
    }

    public JsonElement RenderTick(double seconds)
    {
        CheckThread();
        return ReadResponse(Native.Tick(_handle, seconds));
    }

    public JsonElement? PollEvent()
    {
        CheckThread();
        var pointer = Native.PollEvent(_handle);
        return pointer == IntPtr.Zero ? null : ReadResponse(pointer);
    }

    public void Detach() { CheckThread(); Check(Native.Detach(_handle)); }

    public void Dispose()
    {
        if (_disposed) return;
        CheckThread();
        _disposed = true;
        _handle.Dispose();
    }

    private void CheckThread()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (Environment.CurrentManagedThreadId != _threadId)
            throw new InvalidOperationException("The native presenter must be used on its creating thread.");
    }

    private static JsonElement ReadResponse(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero) throw new InvalidOperationException(LastError());
        try
        {
            using var document = JsonDocument.Parse(Marshal.PtrToStringUTF8(pointer)!);
            var root = document.RootElement;
            if (!root.GetProperty("ok").GetBoolean())
                throw new InvalidOperationException(root.GetProperty("error").GetString());
            return root.GetProperty("value").Clone();
        }
        finally { Native.FreeString(pointer); }
    }

    private static void Check(int status)
    {
        if (status != 0) throw new InvalidOperationException(LastError());
    }

    private static string LastError()
    {
        var pointer = Native.LastError();
        if (pointer == IntPtr.Zero) return "Native player call failed.";
        try { return Marshal.PtrToStringUTF8(pointer) ?? "Native player call failed."; }
        finally { Native.FreeString(pointer); }
    }

    private sealed class PresenterHandle : SafeHandleZeroOrMinusOneIsInvalid
    {
        // SafeHandle also releases the native session if window initialization fails.
        internal PresenterHandle(IntPtr pointer) : base(true) => SetHandle(pointer);
        protected override bool ReleaseHandle() { Native.Destroy(handle); return true; }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PresenterConfig { public int OutputMode; public float Headroom; public int Upscaler; public int AlphaMode; }
    [StructLayout(LayoutKind.Sequential)]
    private struct OutputCapabilities
    {
        [MarshalAs(UnmanagedType.I1)] public bool ExtendedLinear;
        [MarshalAs(UnmanagedType.I1)] public bool DirectComposition;
        public float DesiredHeadroom;
        public int FallbackReason;
    }

    private static class Native
    {
        private const string Library = "erika_capi";
        [DllImport(Library, EntryPoint = "erika_presenter_create_with_config", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr Create(PresenterConfig config);
        [DllImport(Library, EntryPoint = "erika_presenter_destroy", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void Destroy(IntPtr handle);
        [DllImport(Library, EntryPoint = "erika_presenter_attach_wgpu_surface_with_output_capabilities", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int Attach(PresenterHandle handle, int kind, ulong window, ulong display, uint width, uint height, double scale, OutputCapabilities capabilities);
        [DllImport(Library, EntryPoint = "erika_presenter_resize_surface", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int Resize(PresenterHandle handle, uint width, uint height, double scale);
        [DllImport(Library, EntryPoint = "erika_presenter_detach_surface", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int Detach(PresenterHandle handle);
        [DllImport(Library, EntryPoint = "erika_presenter_windows_composition_swapchain_iunknown", CallingConvention = CallingConvention.Cdecl)]
        internal static extern int SwapChain(PresenterHandle handle, out IntPtr swapChain);
        [DllImport(Library, EntryPoint = "erika_presenter_invoke_json", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr Invoke(PresenterHandle handle, [MarshalAs(UnmanagedType.LPUTF8Str)] string method, [MarshalAs(UnmanagedType.LPUTF8Str)] string arguments);
        [DllImport(Library, EntryPoint = "erika_presenter_render_tick_json", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr Tick(PresenterHandle handle, double seconds);
        [DllImport(Library, EntryPoint = "erika_presenter_poll_event_json", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr PollEvent(PresenterHandle handle);
        [DllImport(Library, EntryPoint = "erika_string_free", CallingConvention = CallingConvention.Cdecl)]
        internal static extern void FreeString(IntPtr value);
        [DllImport(Library, EntryPoint = "erika_last_error_message", CallingConvention = CallingConvention.Cdecl)]
        internal static extern IntPtr LastError();
    }
}

using System;
using System.Runtime.InteropServices;

namespace OcPlayer.Core;

/// Minimal P/Invoke surface for the shared C ABI. UI and media-surface code
/// should keep the returned JSON as a projection and never retain native
/// pointers beyond the call that owns them.
public sealed class OcpCore : IDisposable
{
    private const string Library = "ocp_ffi";
    private IntPtr _handle;

    public OcpCore(string configJson = "{}")
    {
        _handle = ocp_core_create(configJson);
        if (_handle == IntPtr.Zero)
            throw new InvalidOperationException(LastError());
    }

    public static uint AbiVersion => ocp_core_abi_version();

    public string Call(string method, string argumentsJson = "{}")
        => TakeString(ocp_call(_handle, method, argumentsJson));

    public string Snapshot(string kind = "core")
        => TakeString(ocp_snapshot(_handle, kind));

    public string? PollEvent()
    {
        var pointer = IntPtr.Zero;
        var result = ocp_poll_event(_handle, ref pointer);
        if (result < 0) throw new InvalidOperationException(LastError());
        return result == 0 ? null : TakeString(pointer);
    }

    public void AttachSurface(ulong nativeHandle, uint width, uint height, double scale, uint kind)
        => ocp_attach_surface(_handle, nativeHandle, width, height, scale, kind);

    public void ResizeSurface(uint width, uint height, double scale)
        => ocp_resize_surface(_handle, width, height, scale);

    public void DetachSurface() => ocp_detach_surface(_handle);
    public void RenderTick(double timeSeconds) => ocp_render_tick(_handle, timeSeconds);

    public void Dispose()
    {
        if (_handle == IntPtr.Zero) return;
        ocp_core_destroy(_handle);
        _handle = IntPtr.Zero;
        GC.SuppressFinalize(this);
    }

    ~OcpCore() => Dispose();

    private static string TakeString(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero) throw new InvalidOperationException(LastError());
        try { return Marshal.PtrToStringUTF8(pointer) ?? string.Empty; }
        finally { ocp_string_free(pointer); }
    }

    private static string LastError()
    {
        var pointer = ocp_last_error_message();
        if (pointer == IntPtr.Zero) return "OcPlayer Core call failed";
        try { return Marshal.PtrToStringUTF8(pointer) ?? "OcPlayer Core call failed"; }
        finally { ocp_string_free(pointer); }
    }

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr ocp_core_create([MarshalAs(UnmanagedType.LPUTF8Str)] string configJson);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void ocp_core_destroy(IntPtr core);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern uint ocp_core_abi_version();
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr ocp_call(IntPtr core, [MarshalAs(UnmanagedType.LPUTF8Str)] string method, [MarshalAs(UnmanagedType.LPUTF8Str)] string argumentsJson);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr ocp_snapshot(IntPtr core, [MarshalAs(UnmanagedType.LPUTF8Str)] string kind);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern int ocp_poll_event(IntPtr core, ref IntPtr eventJson);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void ocp_attach_surface(IntPtr core, ulong nativeHandle, uint width, uint height, double scale, uint kind);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void ocp_resize_surface(IntPtr core, uint width, uint height, double scale);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void ocp_detach_surface(IntPtr core);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void ocp_render_tick(IntPtr core, double timeSeconds);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern void ocp_string_free(IntPtr value);
    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr ocp_last_error_message();
}

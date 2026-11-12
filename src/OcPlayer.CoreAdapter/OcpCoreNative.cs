using System.Runtime.InteropServices;

namespace OcPlayer.CoreAdapter;

internal static partial class OcpCoreNative
{
    private const string LibraryName = "ocp_ffi";

    [LibraryImport(LibraryName, EntryPoint = "ocp_core_create", StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr Create(string? configJson);

    [LibraryImport(LibraryName, EntryPoint = "ocp_core_destroy")]
    internal static partial void Destroy(IntPtr core);

    [LibraryImport(LibraryName, EntryPoint = "ocp_core_abi_version")]
    internal static partial uint AbiVersion();

    [LibraryImport(LibraryName, EntryPoint = "ocp_call", StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr Call(IntPtr core, string method, string? argumentsJson);

    [LibraryImport(LibraryName, EntryPoint = "ocp_snapshot", StringMarshalling = StringMarshalling.Utf8)]
    internal static partial IntPtr Snapshot(IntPtr core, string? snapshotKind);

    [LibraryImport(LibraryName, EntryPoint = "ocp_poll_event")]
    internal static partial int PollEvent(IntPtr core, out IntPtr eventJson);

    [LibraryImport(LibraryName, EntryPoint = "ocp_attach_surface")]
    internal static partial void AttachSurface(IntPtr core, ulong nativeHandle, uint width, uint height, double scale, uint surfaceKind);

    [LibraryImport(LibraryName, EntryPoint = "ocp_resize_surface")]
    internal static partial void ResizeSurface(IntPtr core, uint width, uint height, double scale);

    [LibraryImport(LibraryName, EntryPoint = "ocp_detach_surface")]
    internal static partial void DetachSurface(IntPtr core);

    [LibraryImport(LibraryName, EntryPoint = "ocp_render_tick")]
    internal static partial void RenderTick(IntPtr core, double timeSeconds);

    [LibraryImport(LibraryName, EntryPoint = "ocp_string_free")]
    internal static partial void FreeString(IntPtr value);

    [LibraryImport(LibraryName, EntryPoint = "ocp_last_error_message")]
    internal static partial IntPtr LastErrorMessage();
}

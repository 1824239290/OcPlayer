namespace OcPlayer.CoreAdapter;

public interface IWindowsPlayerSurface
{
    ulong NativeHandle { get; }
    uint Width { get; }
    uint Height { get; }
    double Scale { get; }
    void Attach(OcpCoreClient core);
    void Resize(OcpCoreClient core, uint width, uint height, double scale);
    void Detach(OcpCoreClient core);
}

/// WinUI 3 integration point. The implementation owns HWND/DirectComposition
/// setup; the core only receives the opaque native handle and resize lifecycle.
public sealed class WindowsPlayerSurface : IWindowsPlayerSurface
{
    public WindowsPlayerSurface(ulong nativeHandle, uint width, uint height, double scale = 1.0)
        => (NativeHandle, Width, Height, Scale) = (nativeHandle, width, height, scale);

    public ulong NativeHandle { get; private set; }
    public uint Width { get; private set; }
    public uint Height { get; private set; }
    public double Scale { get; private set; }

    public void Attach(OcpCoreClient core) => core.AttachSurface(NativeHandle, Width, Height, Scale);

    public void Resize(OcpCoreClient core, uint width, uint height, double scale)
    {
        core.ResizeSurface(width, height, scale);
        (Width, Height, Scale) = (width, height, scale);
    }

    public void Detach(OcpCoreClient core) => core.DetachSurface();
}

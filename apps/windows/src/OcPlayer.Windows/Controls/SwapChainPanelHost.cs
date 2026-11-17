using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Controls;

namespace OcPlayer.Windows.Controls;

internal sealed class SwapChainPanelHost(SwapChainPanel panel) : IDisposable
{
    private IntPtr _bound;
    private static readonly Guid NativeId = new("63aad0b8-7c24-40ff-85a8-640d944cc325");
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int SetSwapChain(IntPtr instance, IntPtr swapChain);

    public void Bind(IntPtr ownedSwapChain)
    {
        if (_bound == ownedSwapChain) { if (ownedSwapChain != IntPtr.Zero) Marshal.Release(ownedSwapChain); return; }
        try { Set(ownedSwapChain); }
        catch { if (ownedSwapChain != IntPtr.Zero) Marshal.Release(ownedSwapChain); throw; }
        if (_bound != IntPtr.Zero) Marshal.Release(_bound);
        _bound = ownedSwapChain;
    }

    private void Set(IntPtr swapChain)
    {
        var inspectable = ((WinRT.IWinRTObject)panel).NativeObject.ThisPtr;
        var id = NativeId;
        Marshal.ThrowExceptionForHR(Marshal.QueryInterface(inspectable, in id, out var native));
        try
        {
            var table = Marshal.ReadIntPtr(native);
            var method = Marshal.GetDelegateForFunctionPointer<SetSwapChain>(Marshal.ReadIntPtr(table, 3 * IntPtr.Size));
            Marshal.ThrowExceptionForHR(method(native, swapChain));
        }
        finally { Marshal.Release(native); }
    }

    public void Dispose() => Bind(IntPtr.Zero);
}

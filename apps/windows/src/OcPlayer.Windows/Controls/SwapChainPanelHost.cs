using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Controls;

namespace OcPlayer.Windows.Controls;

internal sealed class SwapChainPanelHost : IDisposable
{
    private readonly SwapChainPanel _panel;
    private IntPtr _bound;
    private static readonly Guid NativeId = new("63aad0b8-7c24-40ff-85a8-640d944cc325");
    private static readonly Guid SwapChain2Id = new("a8be2ac4-199f-4946-b331-79599fb98de7");

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int SetSwapChain(IntPtr instance, IntPtr swapChain);

    [StructLayout(LayoutKind.Sequential)]
    private struct DXGI_MATRIX_3X2_F
    {
        public float _11;
        public float _12;
        public float _21;
        public float _22;
        public float _31;
        public float _32;
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int SetMatrixTransform(IntPtr instance, in DXGI_MATRIX_3X2_F matrix);

    public event EventHandler? CompositionScaleChanged;

    public SwapChainPanelHost(SwapChainPanel panel)
    {
        _panel = panel;
        _panel.CompositionScaleChanged += OnCompositionScaleChanged;
    }

    public void Bind(IntPtr ownedSwapChain)
    {
        if (_bound == ownedSwapChain)
        {
            if (ownedSwapChain != IntPtr.Zero)
            {
                ApplyInverseScale();
                Marshal.Release(ownedSwapChain);
            }
            return;
        }
        try
        {
            Set(ownedSwapChain);
            if (ownedSwapChain != IntPtr.Zero) ApplyInverseScale(ownedSwapChain);
        }
        catch
        {
            if (ownedSwapChain != IntPtr.Zero) Marshal.Release(ownedSwapChain);
            throw;
        }
        if (_bound != IntPtr.Zero) Marshal.Release(_bound);
        _bound = ownedSwapChain;
    }

    public void ApplyInverseScale() => ApplyInverseScale(_bound);

    private void ApplyInverseScale(IntPtr swapChain)
    {
        if (swapChain == IntPtr.Zero) return;
        var swapChain2Id = SwapChain2Id;
        if (Marshal.QueryInterface(swapChain, in swapChain2Id, out var swapChain2) != 0) return;
        try
        {
            var table = Marshal.ReadIntPtr(swapChain2);
            var method = Marshal.GetDelegateForFunctionPointer<SetMatrixTransform>(Marshal.ReadIntPtr(table, 34 * IntPtr.Size));
            var scaleX = (float)_panel.CompositionScaleX;
            var scaleY = (float)_panel.CompositionScaleY;
            if (!float.IsFinite(scaleX) || scaleX <= 0) scaleX = 1.0f;
            if (!float.IsFinite(scaleY) || scaleY <= 0) scaleY = 1.0f;
            var matrix = new DXGI_MATRIX_3X2_F
            {
                _11 = 1.0f / scaleX,
                _22 = 1.0f / scaleY,
            };
            Marshal.ThrowExceptionForHR(method(swapChain2, in matrix));
        }
        catch (Exception ex)
        {
            System.Diagnostics.Trace.WriteLine($"SwapChainPanelHost ApplyInverseScale failed: {ex.Message}");
        }
        finally
        {
            Marshal.Release(swapChain2);
        }
    }

    private void OnCompositionScaleChanged(SwapChainPanel sender, object args)
    {
        ApplyInverseScale();
        CompositionScaleChanged?.Invoke(this, EventArgs.Empty);
    }

    private void Set(IntPtr swapChain)
    {
        var inspectable = ((WinRT.IWinRTObject)_panel).NativeObject.ThisPtr;
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

    public void Dispose()
    {
        _panel.CompositionScaleChanged -= OnCompositionScaleChanged;
        Bind(IntPtr.Zero);
    }
}

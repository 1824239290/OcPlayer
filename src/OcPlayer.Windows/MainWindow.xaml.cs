using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.CoreAdapter;

namespace OcPlayer.Windows;

public sealed partial class MainWindow : Window
{
    private OcpCoreClient? _core;

    public MainWindow()
    {
        InitializeComponent();
        Closed += (_, _) => _core?.Dispose();
        Title = "OcPlayer Windows";

        try
        {
            _core = new OcpCoreClient();
            StatusText.Text = $"OcPlayer Windows · 核心已连接（ABI {OcpCoreClient.AbiVersion}）";
        }
        catch (Exception ex) when (ex is DllNotFoundException or BadImageFormatException or InvalidOperationException)
        {
            // ocp_ffi.dll 还没构建或与 ABI 不匹配时，不要阻塞 WinUI 壳启动。
            // 原生核心就绪后这里会走上面的正常分支。
            StatusText.Text = "OcPlayer Windows · 原生核心未就绪";
            ToolTipService.SetToolTip(StatusText, ex.Message);
        }
    }
}

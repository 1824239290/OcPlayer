using Microsoft.UI.Xaml;
using OcPlayer.CoreAdapter;

namespace OcPlayer.Windows;

public sealed partial class MainWindow : Window
{
    private readonly OcpCoreClient _core = new();

    public MainWindow()
    {
        InitializeComponent();
        var ping = _core.Ping();
        Title = $"OcPlayer Windows (ABI {OcpCoreClient.AbiVersion})";
    }
}

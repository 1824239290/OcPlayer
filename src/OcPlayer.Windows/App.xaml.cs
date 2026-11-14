using Microsoft.UI.Xaml;

namespace OcPlayer.Windows;

public partial class App : Application
{
    private Window? _window;

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = Environment.GetCommandLineArgs().Contains("--demo-route=player")
            ? new PlayerWindow(Preview.DemoCatalog.All[4]) : new MainWindow();
#if DEBUG
        Preview.DemoCapture.Attach(_window);
#endif
        _window.Activate();
    }
}

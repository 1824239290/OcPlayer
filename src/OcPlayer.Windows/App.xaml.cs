using Microsoft.UI.Xaml;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows;

public partial class App : Application
{
    private Window? _window;
    internal static CoreRuntime? Core { get; private set; }
    internal static string? CoreError { get; private set; }
    internal static bool DemoMode { get; private set; } = Environment.GetCommandLineArgs().Any(x => x.StartsWith("--demo-"));

    internal static CoreRuntime EnsureCore()
    {
        if (Core is not null) return Core;
        try { Core = new CoreRuntime(); CoreError = null; return Core; }
        catch (Exception ex) { CoreError = ex.Message; throw; }
    }

    internal static void LeaveDemo() => DemoMode = false;

    public App() => InitializeComponent();

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (Environment.GetCommandLineArgs().Contains("--detail-controls-preview"))
        {
            _window = new Features.DetailControlsPreviewWindow();
#if DEBUG
            Preview.DemoCapture.Attach(_window);
#endif
            _window.Activate();
            return;
        }
        if (Environment.GetCommandLineArgs().Contains("--header-actions-preview"))
        {
            _window = new Features.HeaderActionsPreviewWindow();
#if DEBUG
            Preview.DemoCapture.Attach(_window);
#endif
            _window.Activate();
            return;
        }
        if (Environment.GetCommandLineArgs().Contains("--nav-preview"))
        {
            _window = new Features.NavigationPreviewWindow();
            _window.Activate();
            return;
        }
        if (!DemoMode)
        {
            try { EnsureCore(); }
            catch { /* The main window displays the load failure. */ }
        }
        _window = Environment.GetCommandLineArgs().Contains("--demo-route=player")
            ? new PlayerWindow(Preview.DemoCatalog.All[4]) : new MainWindow();
#if DEBUG
        Preview.DemoCapture.Attach(_window);
#endif
        _window.Closed += (_, _) => { Core?.Dispose(); Core = null; };
        _window.Activate();
    }
}

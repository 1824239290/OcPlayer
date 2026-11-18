using Microsoft.UI.Xaml;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows;

public partial class App : Application
{
    private Window? _window;
    internal static CoreRuntime? Core { get; private set; }
    internal static string? CoreError { get; private set; }
    internal static bool DemoMode { get; private set; } = Environment.GetCommandLineArgs().Any(x => x.StartsWith("--demo-"));

    internal static CoreRuntime EnsureCore(string credentialResource = "OcPlayer.Windows")
    {
        if (Core is not null) return Core;
        try { Core = new CoreRuntime(credentialResource); CoreError = null; return Core; }
        catch (Exception ex) { CoreError = ex.Message; throw; }
    }

    internal static void LeaveDemo() => DemoMode = false;

    public App()
    {
        UnhandledException += (_, args) =>
        {
            AppDiagnostics.Write("error", args.Exception.ToString());
            Console.Error.WriteLine(args.Exception.ToString());
        };
        InitializeComponent();
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var launchArguments = Environment.GetCommandLineArgs();
        var migration = launchArguments.FirstOrDefault(x => x.StartsWith(AppDataMigration.Argument, StringComparison.Ordinal));
        if (migration is not null)
        {
            try { AppDataMigration.Import(migration[AppDataMigration.Argument.Length..], AppPaths.DataDirectory); }
            catch (Exception ex) { Console.Error.WriteLine(ex.Message); Environment.ExitCode = 1; }
            Exit(); return;
        }
        var runtimeProbe = launchArguments.FirstOrDefault(x => x.StartsWith("--verify-runtime=", StringComparison.Ordinal));
        if (runtimeProbe is not null)
        {
            var output = runtimeProbe.Split('=', 2)[1];
            try
            {
                using var runtime = new CoreRuntime("OcPlayer.RuntimeProbe." + Guid.NewGuid().ToString("N"));
                using var presenter = new OcPlayer.CoreAdapter.ErikaPresenter();
                Core = runtime;
                var probeWindow = new MainWindow();
                probeWindow.Close();
                Core = null;
                var modules = System.Diagnostics.Process.GetCurrentProcess().Modules.Cast<System.Diagnostics.ProcessModule>()
                    .Where(x => new[] { "Microsoft.UI.Xaml.dll", "coreclr.dll", "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll" }.Contains(x.ModuleName, StringComparer.OrdinalIgnoreCase))
                    .ToDictionary(x => x.ModuleName, x => x.FileName);
                File.WriteAllText(output, System.Text.Json.JsonSerializer.Serialize(new { passed = true, version = AppReleaseService.Version,
                    coreVersion = runtime.Version, kernelVersion = KernelVersion.Read(), modules, dataDirectory = runtime.DataDirectory }));
            }
            catch (Exception ex) { File.WriteAllText(output, System.Text.Json.JsonSerializer.Serialize(new { passed = false, error = ex.ToString() })); Environment.ExitCode = 1; }
            Exit(); return;
        }
        if (launchArguments.Contains(BangumiOAuthBrowser.RegisterArgument))
        {
            try { BangumiOAuthBrowser.RegisterProtocol(); }
            catch (Exception ex) { Console.Error.WriteLine(ex.Message); Environment.ExitCode = 1; }
            Exit(); return;
        }
        var callbackIndex = Array.IndexOf(launchArguments, BangumiOAuthBrowser.CallbackArgument);
        if (callbackIndex >= 0)
        {
            try
            {
                if (callbackIndex + 1 >= launchArguments.Length) throw new InvalidOperationException("缺少回调。");
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                await BangumiOAuthBrowser.Forward(launchArguments[callbackIndex + 1], deadline.Token);
                Exit();
            }
            catch
            {
                // No Core, credentials or media session is opened in this process.
                _window = new Window { Title = "Bangumi 授权" };
                var message = new Microsoft.UI.Xaml.Controls.StackPanel { Spacing = 18, Padding = new Thickness(24) };
                message.Children.Add(new Microsoft.UI.Xaml.Controls.TextBlock { Text = "登录已取消、过期，或发起登录的窗口已关闭。请回到 OcPlayer 设置重新登录。", TextWrapping = TextWrapping.Wrap });
                var close = new Microsoft.UI.Xaml.Controls.Button { Content = "关闭" }; close.Click += (_, _) => _window.Close(); message.Children.Add(close);
                _window.Content = message; _window.AppWindow.ResizeClient(new global::Windows.Graphics.SizeInt32(420, 180)); _window.Activate();
            }
            return;
        }
#if DEBUG
        var cadenceVerification = launchArguments.FirstOrDefault(x => x.StartsWith("--verify-danmaku-cadence="));
        if (cadenceVerification is not null)
        {
            var mediaPath = launchArguments.First(x => x.StartsWith("--open=")).Split('=', 2)[1];
            var resource = "OcPlayer.UiCadenceTest." + Guid.NewGuid().ToString("N");
            EnsureCore(resource);
            _window = new Preview.DanmakuCadenceVerification(mediaPath, cadenceVerification.Split('=', 2)[1], resource);
            _window.Closed += (_, _) => { Core?.Dispose(); Core = null; };
            _window.Activate(); return;
        }
        var serverConnectionVerification = launchArguments.FirstOrDefault(x => x.StartsWith("--verify-server-connection="));
        if (serverConnectionVerification is not null)
        {
            _window = new Preview.ServerConnectionVerification(serverConnectionVerification.Split('=', 2)[1]);
            _window.Activate(); return;
        }
        var nativeVerification = launchArguments.FirstOrDefault(x => x.StartsWith("--verify-native-player="));
        if (nativeVerification is not null)
        {
            var mediaPath = launchArguments.First(x => x.StartsWith("--open=")).Split('=', 2)[1];
            var resource = "OcPlayer.UiNativeTest." + Guid.NewGuid().ToString("N");
            EnsureCore(resource);
            _window = new Preview.NativePlayerVerification(mediaPath, nativeVerification.Split('=', 2)[1], resource);
            _window.Closed += (_, _) => { Core?.Dispose(); Core = null; };
            _window.Activate();
            return;
        }
        if (launchArguments.Contains("--verify-danmaku-ui"))
        {
            var mediaPath = launchArguments.First(x => x.StartsWith("--open=")).Split('=', 2)[1];
            var resource = "OcPlayer.UiDanmakuTest." + Guid.NewGuid().ToString("N");
            EnsureCore(resource);
            _window = new Preview.DanmakuVerificationWindow(mediaPath, resource);
            _window.Closed += (_, _) => { Core?.Dispose(); Core = null; };
            _window.Activate();
            return;
        }
        var moviePilotVerification = launchArguments.FirstOrDefault(x => x.StartsWith("--verify-moviepilot="));
        if (moviePilotVerification is not null)
        {
            _window = new Preview.MoviePilotPageVerification(moviePilotVerification.Split('=', 2)[1]);
            _window.Activate(); return;
        }
        var viewingVerification = Environment.GetCommandLineArgs().FirstOrDefault(x => x.StartsWith("--verify-viewing="));
        if (viewingVerification is not null)
        {
            EnsureCore("OcPlayer.UiViewingTest." + Guid.NewGuid().ToString("N"));
            _window = new Preview.ViewingPageVerification(viewingVerification.Split('=', 2)[1]);
            _window.Closed += (_, _) => { Core?.Dispose(); Core = null; };
            _window.Activate();
            return;
        }
        var verification = Environment.GetCommandLineArgs().FirstOrDefault(x => x.StartsWith("--demo-verify-transitions="));
        if (verification is not null)
        {
            _window = new Preview.PageTransitionVerification(verification.Split('=', 2)[1]);
            _window.Activate();
            return;
        }
#endif
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
        var main = new MainWindow(); _window = main;
        var instance = Microsoft.Windows.AppLifecycle.AppInstance.GetCurrent();
        instance.Activated += (_, activation) => main.DispatcherQueue.TryEnqueue(() => main.HandleExternalActivation(activation));
        ((FrameworkElement)main.Content).Loaded += (_, _) => main.HandleExternalActivation(instance.GetActivatedEventArgs());
#if DEBUG
        Preview.DemoCapture.Attach(_window);
#endif
        _window.Closed += (_, _) => { Core?.Dispose(); Core = null; };
        _window.Activate();
    }
}

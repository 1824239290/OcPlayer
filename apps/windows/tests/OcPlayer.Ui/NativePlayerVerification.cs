#if DEBUG
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using OcPlayer.CoreAdapter;
using OcPlayer.Tests;
using OcPlayer.Windows.Services;
using OcPlayer.Windows.Features;
using OcPlayer.Windows.ViewModels;
using Windows.Graphics.Imaging;
using Windows.Media;

namespace OcPlayer.Windows.Preview;

// Exercises the real dispatcher, decoder clock and app-layer renderer with isolated local fixtures.
internal sealed class NativePlayerVerification : Window
{
    public NativePlayerVerification(string mediaPath, string directory, string resource)
    {
        Title = "原生播放器回归验证";
        AppWindow.ResizeClient(new global::Windows.Graphics.SizeInt32(1120, 760));
        var gateway = new DanmakuFixture();
        var core = App.Core!;
        RuntimeSettings.Save(new RuntimePreferences(SkipIntro: false, SkipOutro: false));
        var preferences = new DanmakuPreferences(GatewayUrl: gateway.Url, ApiKey: "local-fixture-key", AutoLoad: false, UseKernelRenderer: false);
        core.Danmaku.Settings.Save(preferences);
        var media = new DemoMedia("native-ui-1", "原生播放器测试", "", "", "", "", "", SourceUri: mediaPath);
        var player = new PlayerView(this, media, new PlaybackSource(media.Id, media.Title, mediaPath));
        Content = player;
        player.Loaded += async (_, _) =>
        {
            Directory.CreateDirectory(directory);
            var assertions = new List<string>();
            const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
            T Field<T>(string name) => (T)typeof(PlayerView).GetField(name, flags)!.GetValue(player)!;
            void Invoke(string method, params object[] args) => typeof(PlayerView).GetMethod(method, flags)!.Invoke(player, args);
            void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); assertions.Add(message); }
            async Task Wait(Func<bool> condition)
            {
                var watch = Stopwatch.StartNew();
                while (!condition())
                {
                    if (watch.Elapsed.TotalSeconds > 15) throw new TimeoutException("Native UI condition did not settle.");
                    if (Field<InfoBar>("PlaybackError").IsOpen) throw new InvalidOperationException(Field<InfoBar>("PlaybackError").Message);
                    await Task.Delay(33);
                }
            }
            async Task Capture(string name, FrameworkElement? element = null)
            {
                var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(element ?? player);
                var pixels = await bitmap.GetPixelsAsync();
                using var file = File.Create(Path.Combine(directory, name + ".png")); using var stream = file.AsRandomAccessStream();
                var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
                encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels.ToArray());
                await encoder.FlushAsync();
            }
            try
            {
                var rendererEditor = new DanmakuSettingsEditor(preferences with { UseKernelRenderer = true });
                var rendererToggle = (ToggleSwitch)typeof(DanmakuSettingsEditor).GetField("_kernel", flags)!.GetValue(rendererEditor)!;
                rendererToggle.IsOn = false;
                Check(!rendererEditor.Read().UseKernelRenderer,
                    "renderer settings editor reads the app-renderer toggle state before saving");
                rendererToggle.IsOn = true;
                Check(!core.Danmaku.Settings.Current.UseKernelRenderer,
                    "player-dialog editor keeps switch changes pending until explicit save");
                var failedSettings = new DanmakuSettings(() => JsonSerializer.Serialize(preferences with { UseKernelRenderer = true }),
                    _ => throw new IOException("fixture save failure"));
                var failedEditor = new DanmakuSettingsEditor(failedSettings.Current);
                string? failedStatus = null;
                failedEditor.EnableToggleAutoSave(failedSettings, message => failedStatus = message);
                var failedToggle = (ToggleSwitch)typeof(DanmakuSettingsEditor).GetField("_kernel", flags)!.GetValue(failedEditor)!;
                failedToggle.IsOn = false;
                Check(failedToggle.IsOn && failedSettings.Current.UseKernelRenderer && failedStatus == "fixture save failure",
                    "failed automatic save restores the renderer switch and reports the storage error");
                await Wait(() => Field<PlaybackSession>("_session") is { Ready: true, HasFirstFrame: true });
                var session = Field<PlaybackSession>("_session");
                Check(session.VideoWidth > 0 && session.Stats.GetProperty("decodedVideoFrames").GetUInt64() > 0,
                    "WinUI player attaches its swap chain and decodes real video");
                Invoke("SetPlaying", false); session.Seek(2);
                await Wait(() => !session.Playing && session.PlaybackState == 4 && Math.Abs(session.PositionSeconds - 2) < .15);
                Invoke("ShowDanmakuSettings");
                await Wait(() => Field<ContentDialog?>("_danmakuDialog")?.IsLoaded == true);
                var settingsDialog = Field<ContentDialog>("_danmakuDialog");
                settingsDialog.RequestedTheme = ElementTheme.Dark;
                await Task.Delay(150);
                await Capture("settings-danmaku-player-dialog", settingsDialog);
                Walk(settingsDialog).OfType<ToggleSwitch>().Single(x =>
                    Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x) == "用内核渲染弹幕").IsOn = true;
                ((ScrollViewer)settingsDialog.Content).ChangeView(null, double.MaxValue, null, true);
                await Task.Delay(150);
                await Capture("settings-danmaku-player-dialog-lower", settingsDialog);
                settingsDialog.Hide();
                await Wait(() => Field<ContentDialog?>("_danmakuDialog") is null);
                Check(!core.Danmaku.Settings.Current.UseKernelRenderer,
                    "cancelling the actual player settings dialog discards its pending renderer switch");
                var xml = Path.Combine(directory, "overlay.xml");
                File.WriteAllText(xml, "<i><d p=\"0,1,22,16777215\">滚动弹幕</d><d p=\"0,5,22,16711680\">顶部弹幕</d><d p=\"0,4,22,65280\">底部弹幕</d></i>");
                Invoke("ImportLocalDanmaku", xml);
                var canvas = Field<Canvas>("_danmakuCanvas");
                await Wait(() => canvas.Children.Count == 3);
                Check(session.DanmakuTracks.GetArrayLength() == 0 && canvas.Children.OfType<TextBlock>().Count() == 3,
                    "local XML uses the app overlay without loading a second native danmaku track");
                var scrolling = canvas.Children.OfType<TextBlock>().Single(x => x.Text == "滚动弹幕");
                var left = ((TranslateTransform)scrolling.RenderTransform).X; await Task.Delay(250);
                Check(Math.Abs(((TranslateTransform)scrolling.RenderTransform).X - left) < .1, "paused app-layer danmaku stays on the native media clock");
                await Capture("app-overlay-paused");
                core.Danmaku.Settings.Save(preferences with { FontSize = 44, Opacity = .5, BlockTop = true });
                await Wait(() => canvas.Children.Count == 2);
                Check(canvas.Children.OfType<TextBlock>().All(x => x.FontSize == 44) && canvas.Opacity == .5
                    && canvas.Children.OfType<TextBlock>().All(x => x.Text != "顶部弹幕"),
                    "font size, opacity and top-comment filtering apply to the visible app overlay");
                session.Seek(20); await Wait(() => session.PositionSeconds > 19 && canvas.Children.Count == 0);
                session.Seek(2); await Wait(() => session.PositionSeconds < 3 && canvas.Children.Count == 2);
                Check(canvas.Children.Count == 2, "seeking beyond and back into a comment recreates the expected app overlay");
                core.Danmaku.Settings.Save(preferences with { Enabled = false });
                await Wait(() => canvas.Visibility == Visibility.Collapsed);
                core.Danmaku.Settings.Save(preferences with { UseKernelRenderer = true });
                await Wait(() => canvas.Visibility == Visibility.Visible && canvas.Children.Count == 3);
                Check(!Field<bool>("_useKernelDanmaku"), "renderer preference waits until the next media source");
                var next = media with { Id = "native-ui-2", Title = "切换片源测试" };
                player.SetMedia(next, new PlaybackSource(next.Id, next.Title, mediaPath));
                await Wait(() => session.Ready && session.HasFirstFrame);
                Check(Field<bool>("_useKernelDanmaku") && canvas.Children.Count == 0 && session.DanmakuTracks.GetArrayLength() == 0,
                    "changing media selects the native renderer and clears previous app comments");
                var json = Path.Combine(directory, "overlay.json");
                File.WriteAllText(json, "{\"comments\":[{\"time\":0,\"type\":1,\"color\":16777215,\"content\":\"原生弹幕\"}]}");
                Invoke("ImportLocalDanmaku", json);
                Check(session.DanmakuTracks.GetArrayLength() == 1 && canvas.Children.Count == 0,
                    "local JSON loads exactly one native danmaku track after switching renderers");
                Invoke("SetPlaying", false);
                var system = Field<PlaybackSystemSession>("_systemSession");
                Check(system is not null, "real player creates a Windows system media session");
                var controls = (SystemMediaTransportControls)typeof(PlaybackSystemSession).GetField("_controls", flags)!.GetValue(system)!;
                await Wait(() => controls.PlaybackStatus == MediaPlaybackStatus.Paused && controls.DisplayUpdater.VideoProperties.Title == next.Title);
                Check(controls.IsEnabled && controls.IsPlayEnabled && controls.IsPauseEnabled,
                    "Windows media controls receive the current title and paused playback state");
                player.Dispose();
                Check(!controls.IsEnabled && controls.PlaybackStatus == MediaPlaybackStatus.Closed && player.IsDisposed,
                    "closing the player releases native playback and its Windows media session");
                static IEnumerable<DependencyObject> Walk(DependencyObject root)
                {
                    yield return root;
                    for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
                        foreach (var child in Walk(VisualTreeHelper.GetChild(root, i))) yield return child;
                }
                var settingsPages = new DemoSettings(new DemoViewModel(), new Controls.PageLayout(), _ => { }, _ => { });
                async Task<FrameworkElement> ShowDanmakuSettingsPage()
                {
                    var page = (FrameworkElement)settingsPages.Subpage("弹幕");
                    Content = page;
                    await Task.Delay(200); page.UpdateLayout();
                    return page;
                }
                ToggleSwitch KernelToggle(DependencyObject page) => Walk(page).OfType<ToggleSwitch>()
                    .Single(x => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x) == "用内核渲染弹幕");
                var danmakuPage = await ShowDanmakuSettingsPage();
                KernelToggle(danmakuPage).IsOn = false;
                Check(!core.Danmaku.Settings.Current.UseKernelRenderer && !new DanmakuSettings(resource).Current.UseKernelRenderer,
                    "standalone settings page saves the renderer switch without pressing Save");
                Content = settingsPages.Hub(); await Task.Delay(100);
                danmakuPage = await ShowDanmakuSettingsPage();
                Check(!KernelToggle(danmakuPage).IsOn,
                    "returning to the danmaku settings page retains the app-renderer switch");
                var savedGateway = core.Danmaku.Settings.Current.GatewayUrl;
                var savedClient = core.Danmaku.Settings.Current.AnimeSkipClientId;
                Walk(danmakuPage).OfType<TextBox>().Single(x => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x) == "anime-skip Client ID（可选）").Text = "pending-client-id";
                KernelToggle(danmakuPage).IsOn = true;
                Check(core.Danmaku.Settings.Current.UseKernelRenderer && core.Danmaku.Settings.Current.GatewayUrl == savedGateway
                    && core.Danmaku.Settings.Current.AnimeSkipClientId == savedClient
                    && new DanmakuSettings(resource).Current.UseKernelRenderer,
                    "automatic switch save preserves the last gateway while unrelated text input is unfinished");
                danmakuPage = await ShowDanmakuSettingsPage();
                KernelToggle(danmakuPage).IsOn = false;
                danmakuPage = await ShowDanmakuSettingsPage();
                Check(!KernelToggle(danmakuPage).IsOn && !new DanmakuSettings(resource).Current.UseKernelRenderer,
                    "renderer can be toggled on and off repeatedly and survives page recreation and credential reload");
                danmakuPage.RequestedTheme = ElementTheme.Dark;
                ((ScrollViewer)danmakuPage).Background = new SolidColorBrush(Microsoft.UI.Colors.Black);
                await Task.Delay(150);
                await Capture("settings-danmaku-switch-saved", danmakuPage);
                var configure = Walk(danmakuPage).OfType<Button>().Single(x => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x) == "配置弹幕网关");
                ((IInvokeProvider)new ButtonAutomationPeer(configure).GetPattern(PatternInterface.Invoke)).Invoke();
                ContentDialog? GatewayDialog() => VisualTreeHelper.GetOpenPopupsForXamlRoot(danmakuPage.XamlRoot)
                    .SelectMany(x => Walk(x.Child)).OfType<ContentDialog>().SingleOrDefault();
                await Wait(() => GatewayDialog()?.IsLoaded == true);
                var gatewayDialog = GatewayDialog()!;
                await Capture("settings-danmaku-gateway-dialog", gatewayDialog);
                Walk(gatewayDialog).OfType<TextBox>().Single(x => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x) == "弹幕网关地址").Text = "https://";
                var gatewaySave = Walk(gatewayDialog).OfType<Button>().Single(x => x.Name == "PrimaryButton");
                ((IInvokeProvider)new ButtonAutomationPeer(gatewaySave).GetPattern(PatternInterface.Invoke)).Invoke();
                await Task.Delay(150);
                Check(gatewayDialog.IsLoaded && core.Danmaku.Settings.Current.GatewayUrl == savedGateway,
                    "gateway configuration rejects an invalid URL without replacing the saved gateway");
                var configuredGateway = savedGateway.TrimEnd('/') + "/configured";
                Walk(gatewayDialog).OfType<TextBox>().Single(x => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x) == "弹幕网关地址").Text = configuredGateway;
                ((IInvokeProvider)new ButtonAutomationPeer(gatewaySave).GetPattern(PatternInterface.Invoke)).Invoke();
                await Wait(() => GatewayDialog() is null);
                Check(core.Danmaku.Settings.Current.GatewayUrl == configuredGateway && new DanmakuSettings(resource).Current.GatewayUrl == configuredGateway,
                    "saving the gateway dialog persists its address and updates credentials");
                danmakuPage = await ShowDanmakuSettingsPage();
                Check(Walk(danmakuPage).OfType<TextBlock>().Any(x => x.Text == configuredGateway),
                    "gateway summary shows the saved address after recreating the settings page");
                configure = Walk(danmakuPage).OfType<Button>().Single(x => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x) == "配置弹幕网关");
                ((IInvokeProvider)new ButtonAutomationPeer(configure).GetPattern(PatternInterface.Invoke)).Invoke();
                await Wait(() => GatewayDialog()?.IsLoaded == true);
                gatewayDialog = GatewayDialog()!;
                Walk(gatewayDialog).OfType<TextBox>().Single(x => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x) == "弹幕网关地址").Text = savedGateway;
                gatewayDialog.Hide(); await Wait(() => GatewayDialog() is null);
                Check(core.Danmaku.Settings.Current.GatewayUrl == configuredGateway,
                    "cancelling gateway configuration discards the pending address");
                core.Danmaku.Settings.Save(core.Danmaku.Settings.Current with { GatewayUrl = savedGateway });
                danmakuPage = await ShowDanmakuSettingsPage();
                danmakuPage.RequestedTheme = ElementTheme.Dark;
                ((ScrollViewer)danmakuPage).Background = new SolidColorBrush(Microsoft.UI.Colors.Black);
                var displayOptions = Walk(danmakuPage).OfType<Expander>().Single();
                displayOptions.IsExpanded = true;
                await Task.Delay(150);
                ((ScrollViewer)danmakuPage).ChangeView(null, double.MaxValue, null, true);
                await Task.Delay(150);
                await Capture("settings-danmaku-dark-lower", danmakuPage);
                var fontInput = Walk(danmakuPage).OfType<NumberBox>().Single(x => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x) == "字号（11–44 pt）");
                fontInput.Focus(FocusState.Programmatic); fontInput.Value = 33;
                KernelToggle(danmakuPage).Focus(FocusState.Programmatic);
                await Task.Delay(100);
                Check(core.Danmaku.Settings.Current.FontSize == 33 && new DanmakuSettings(resource).Current.FontSize == 33,
                    "display value saves when leaving the field and persists in credentials");
                displayOptions.IsExpanded = false;
                ((ScrollViewer)danmakuPage).ChangeView(null, 0, null, true);
                danmakuPage.RequestedTheme = ElementTheme.Light;
                ((ScrollViewer)danmakuPage).Background = new SolidColorBrush(Microsoft.UI.Colors.White);
                await Task.Delay(150);
                await Capture("settings-danmaku-light", danmakuPage);
                AppWindow.ResizeClient(new(640, 720));
                await Task.Delay(150);
                await Capture("settings-danmaku-compact", danmakuPage);
                AppWindow.ResizeClient(new(1120, 760));
                foreach (var name in new[] { "设置", "媒体服务器", "网络", "播放", "TMDB 元数据补全", "首页栏目", "维护", "关于", "开源许可证" })
                {
                    var scroll = (ScrollViewer)(name == "设置" ? settingsPages.Hub() : settingsPages.Subpage(name));
                    scroll.RequestedTheme = ElementTheme.Dark;
                    scroll.Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 16, 16, 16));
                    Content = scroll;
                    await Task.Delay(200); scroll.UpdateLayout();
                    await Capture("settings-" + name, scroll);
                    foreach (var expander in Walk(scroll).OfType<Expander>().ToArray()) expander.IsExpanded = true;
                    await Task.Delay(100); scroll.UpdateLayout();
                    var descendants = Walk(scroll).ToArray(); var choices = descendants.OfType<ComboBox>().ToArray();
                    string Name(DependencyObject element) => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(element);
                    if (name == "播放")
                    {
                        foreach (var (header, count) in new[] { ("网络预读缓冲", 4), ("回退缓冲", 4), ("片尾保留", 6), ("默认字幕语言", 4), ("位置", 5), ("加粗", 3), ("画质增强", 4), ("主题", 3) })
                            Check(choices.Any(x => Name(x) == header && x.Items.Count == count), "playback settings exposes every option for " + header);
                        Check(descendants.OfType<NumberBox>().Any(x => x.Maximum == 200 && x.SmallChange == 10)
                            && descendants.OfType<NumberBox>().Any(x => x.Maximum == 32 && x.SmallChange == 1),
                            "subtitle margin and outline width expose their full ranges");
                        choices.Single(x => Name(x) == "网络预读缓冲").SelectedIndex = 2;
                        descendants.OfType<ToggleSwitch>().Single(x => Name(x) == "跳过片头").IsOn = true;
                        var reloaded = JsonSerializer.Deserialize<RuntimePreferences>(File.ReadAllText(Path.Combine(AppPaths.DataDirectory, "runtime-settings.json")))!;
                        Check(reloaded.NetworkBufferMiB == 16 && reloaded.SkipIntro && RuntimeSettings.Current.NetworkBufferMiB == 16,
                            "horizontal playback choices and switches persist together in the runtime settings file");
                        var subtitleColor = descendants.OfType<TextBox>().Single(x => Name(x) == "字幕颜色（RGBA）");
                        subtitleColor.Focus(FocusState.Programmatic); subtitleColor.Text = "#12345678";
                        choices.Single(x => Name(x) == "位置").Focus(FocusState.Programmatic); await Task.Delay(50);
                        Check(RuntimeSettings.Current.SubtitleColor == "#12345678", "subtitle RGBA input applies when focus leaves the horizontal field");
                    }
                    if (name == "网络")
                    {
                        descendants.OfType<TextBox>().Single(x => Name(x) == "User-Agent").Text = "OcPlayer-layout-test";
                        var save = descendants.OfType<Button>().Single(x => Equals(x.Content, "保存 User-Agent"));
                        ((IInvokeProvider)new ButtonAutomationPeer(save).GetPattern(PatternInterface.Invoke)).Invoke();
                        Check(RuntimeSettings.Current.UserAgent == "OcPlayer-layout-test", "horizontal User-Agent field saves through the existing explicit action");
                    }
                    if (name == "TMDB 元数据补全") Check(choices.Any(x => Name(x) == "元数据语言" && x.Items.Count == 5), "TMDB settings exposes all five metadata languages without credentials");
                    if (name == "维护") Check(descendants.OfType<Button>().Any(x => Equals(x.Content, "导出诊断包…"))
                        && descendants.OfType<Button>().Any(x => Equals(x.Content, "从文件恢复配置…")), "maintenance exposes diagnostic export and configuration restore");
                    if (name == "开源许可证") Check(descendants.OfType<Button>().Count(x => x.Style == (Style)Application.Current.Resources["SettingsActionStyle"]) == OpenSourceCatalog.Entries.Length, "license page exposes each bundled component");
                    if (name == "首页栏目")
                    {
                        var toggle = descendants.OfType<ToggleSwitch>().First(); var title = Name(toggle)[2..]; toggle.IsOn = false;
                        Check(new DemoViewModel().HiddenSections.Contains(title), "home-section visibility persists after changing its compact switch"); toggle.IsOn = true;
                    }
                    Check(descendants.OfType<TextBlock>().Any(x => x.Text.Length > 0), "runtime settings page builds and renders: " + name);
                    scroll.ChangeView(null, double.MaxValue, null, true); await Task.Delay(100);
                    await Capture("settings-" + name + "-expanded-lower", scroll);
                    foreach (var expander in Walk(scroll).OfType<Expander>().ToArray()) expander.IsExpanded = false;
                    scroll.ChangeView(null, 0, null, true); scroll.RequestedTheme = ElementTheme.Light;
                    scroll.Background = new SolidColorBrush(Microsoft.UI.Colors.White); await Task.Delay(100);
                    await Capture("settings-" + name + "-light", scroll);
                    AppWindow.ResizeClient(new(640, 720)); await Task.Delay(100); scroll.UpdateLayout();
                    bool Visible(FrameworkElement element)
                    {
                        if (!element.IsLoaded) return false;
                        for (DependencyObject? parent = element; parent is not null; parent = VisualTreeHelper.GetParent(parent))
                        {
                            if (parent is UIElement { Visibility: Visibility.Collapsed }) return false;
                            if (parent is Expander { IsExpanded: false } && parent != element) return false;
                        }
                        return true;
                    }
                    var bounds = Walk(scroll).OfType<FrameworkElement>().Where(x => Visible(x) && x.ActualWidth > 0 && x is TextBox or PasswordBox or ComboBox or NumberBox or ToggleSwitch or Expander)
                        .Select(x => (Element: x, Point: x.TransformToVisual(scroll).TransformPoint(new()))).ToArray();
                    await Capture("settings-" + name + "-compact", scroll);
                    Check(bounds.All(x => x.Point.X >= 0 && x.Point.X + x.Element.ActualWidth <= scroll.ActualWidth + 1), "settings controls stay inside a 640-pixel viewport: " + name);
                    AppWindow.ResizeClient(new(1120, 760));
                }
                File.WriteAllText(Path.Combine(directory, "results.json"), JsonSerializer.Serialize(new { passed = true, assertions }, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch (Exception ex) { File.WriteAllText(Path.Combine(directory, "results.json"), JsonSerializer.Serialize(new { passed = false, error = ex.ToString(), assertions })); }
            finally
            {
                player.Dispose(); gateway.Dispose();
                var vault = new global::Windows.Security.Credentials.PasswordVault();
                try { vault.Remove(vault.Retrieve(resource, "danmaku-settings")); } catch (System.Runtime.InteropServices.COMException) { }
                Close();
            }
        };
    }
}
#endif

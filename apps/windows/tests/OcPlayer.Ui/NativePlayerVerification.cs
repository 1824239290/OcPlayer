#if DEBUG
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using Microsoft.UI.Xaml;
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
                await Wait(() => Field<PlaybackSession>("_session") is { Ready: true, HasFirstFrame: true });
                var session = Field<PlaybackSession>("_session");
                Check(session.VideoWidth > 0 && session.Stats.GetProperty("decodedVideoFrames").GetUInt64() > 0,
                    "WinUI player attaches its swap chain and decodes real video");
                Invoke("SetPlaying", false); session.Seek(2);
                await Wait(() => !session.Playing && session.PlaybackState == 4 && Math.Abs(session.PositionSeconds - 2) < .15);
                var xml = Path.Combine(directory, "overlay.xml");
                File.WriteAllText(xml, "<i><d p=\"0,1,22,16777215\">滚动弹幕</d><d p=\"0,5,22,16711680\">顶部弹幕</d><d p=\"0,4,22,65280\">底部弹幕</d></i>");
                Invoke("ImportLocalDanmaku", xml);
                var canvas = Field<Canvas>("_danmakuCanvas");
                await Wait(() => canvas.Children.Count == 3);
                Check(session.DanmakuTracks.GetArrayLength() == 0 && canvas.Children.OfType<TextBlock>().Count() == 3,
                    "local XML uses the app overlay without loading a second native danmaku track");
                var scrolling = canvas.Children.OfType<TextBlock>().Single(x => x.Text == "滚动弹幕");
                var left = Canvas.GetLeft(scrolling); await Task.Delay(250);
                Check(Math.Abs(Canvas.GetLeft(scrolling) - left) < .1, "paused app-layer danmaku stays on the native media clock");
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
                foreach (var name in new[] { "网络", "播放", "TMDB 元数据补全", "维护", "关于", "开源许可证" })
                {
                    var panel = new StackPanel { Spacing = 12, Width = 680, HorizontalAlignment = HorizontalAlignment.Center };
                    new RuntimeSettingsPages(new DemoViewModel(), _ => { }, _ => { }).Build(name, panel);
                    var scroll = new Controls.PageLayout().Scroll(panel);
                    scroll.RequestedTheme = ElementTheme.Dark;
                    scroll.Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 16, 16, 16));
                    Content = scroll;
                    await Task.Delay(200); scroll.UpdateLayout();
                    var descendants = Walk(scroll).ToArray(); var choices = descendants.OfType<ComboBox>().ToArray();
                    if (name == "播放")
                    {
                        foreach (var (header, count) in new[] { ("网络预读缓冲", 4), ("回退缓冲", 4), ("片尾保留", 6), ("默认字幕语言", 4), ("位置", 5), ("加粗", 3), ("画质增强", 4), ("主题", 3) })
                            Check(choices.Any(x => Equals(x.Header, header) && x.Items.Count == count), "playback settings exposes every option for " + header);
                        Check(descendants.OfType<NumberBox>().Any(x => x.Maximum == 200 && x.SmallChange == 10)
                            && descendants.OfType<NumberBox>().Any(x => x.Maximum == 32 && x.SmallChange == 1),
                            "subtitle margin and outline width expose their full ranges");
                    }
                    if (name == "TMDB 元数据补全") Check(choices.Any(x => Equals(x.Header, "元数据语言") && x.Items.Count == 5), "TMDB settings exposes all five metadata languages without credentials");
                    if (name == "维护") Check(descendants.OfType<Button>().Any(x => Equals(x.Content, "导出诊断包…"))
                        && descendants.OfType<Button>().Any(x => Equals(x.Content, "从文件恢复配置…")), "maintenance exposes diagnostic export and configuration restore");
                    if (name == "开源许可证") Check(descendants.OfType<Button>().Count() == OpenSourceCatalog.Entries.Length, "license page exposes each bundled component");
                    Check(panel.Children.Count > 2, "runtime settings page builds and renders: " + name);
                    await Capture("settings-" + name, scroll);
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

#if DEBUG
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Features;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows;

public sealed partial class MainWindow
{
    private void AttachBrowsingVerification()
    {
        var output = Environment.GetCommandLineArgs().FirstOrDefault(x => x.StartsWith("--demo-verify-browser="))?.Split('=', 2)[1];
        if (output is null) return;
        WindowRoot.Loaded += async (_, _) =>
        {
            var assertions = new List<string>();
            void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); assertions.Add(message); }
            static IEnumerable<DependencyObject> Walk(DependencyObject root)
            { yield return root; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var item in Walk(VisualTreeHelper.GetChild(root, i))) yield return item; }
            string[] Texts() => Walk(PageHost).OfType<TextBlock>().Select(x => x.Text).ToArray();
            async Task Settle() { for (var i = 0; i < 50 && _transitions.IsTransitioning; i++) await Task.Delay(50); PageHost.UpdateLayout(); Check(!_transitions.IsTransitioning, "route transition finishes before inspecting controls"); }
            async Task Refresh(string route) { Navigate(route); await Task.Delay(120); await Settle(); }
            void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
            try
            {
                _transitions.SetAnimationsEnabled(false);
                _model.HiddenSections.UnionWith(_model.HomeSections); await Refresh("home");
                Check(Texts().Contains("首页栏目都已关闭") && Walk(PageHost).OfType<Button>().Any(x => Equals(x.Content, "去设置")), "all-disabled home explains state and exposes settings action");
                _model.HiddenSections.Clear(); _model.HomeLoading = true; await Refresh("home");
                Check(Walk(PageHost).OfType<ProgressBar>().Any(x => x.IsIndeterminate), "home refresh exposes a busy indicator"); _model.HomeLoading = false;
                var media = DemoCatalog.All[4] with { Id = "parity-long", Description = new string('长', 2000), CommunityRating = 8.8, OfficialRating = "TV-14", SeasonNumber = 1,
                    SelectedSeasonId = "s1", Seasons = [new("s1", "第1季", 1)], EpisodeNumber = 65, EpisodeLabel = "S1E65",
                    Episodes = Enumerable.Range(1, 70).Select(n => new DemoEpisode(n, "标题" + n, "", MediaId: "e" + n, Overview: "简介" + n)).ToArray() };
                _model.SelectedMedia = media; _model.SelectedEpisode = 65; await Refresh("detail");
                var ranges = Walk(PageHost).OfType<ComboBox>().Single(x => Equals(x.Header, "分集范围"));
                Check(ranges.Items.Count == 3 && ranges.SelectedIndex == 2, "seventy episodes divide into thirty-entry ranges and reveal selected episode");
                Check(Texts().Contains("TV-14") && Texts().Any(x => x.Contains("8.8")), "real rating and official rating are visible in detail header");
                var expand = Walk(PageHost).OfType<Button>().Single(x => Equals(x.Content, "展开全文")); Invoke(expand); await Task.Delay(300);
                var synopsisDialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(WindowRoot.XamlRoot).SelectMany(x => Walk(x.Child)).OfType<ContentDialog>().Single();
                Check(synopsisDialog.Content is ScrollViewer { Content: TextBlock { MaxLines: 0, IsTextSelectionEnabled: true } fullSynopsis }
                    && fullSynopsis.Text == media.Description, "expand synopsis opens a dialog with complete selectable text");
                Check(Equals(expand.Content, "展开全文") && Walk(PageHost).OfType<TextBlock>().Any(x => x.Text == media.Description && x.MaxLines == 3), "opening synopsis keeps the detail preview at three lines");
                var synopsisScroll = (ScrollViewer)synopsisDialog.Content;
                Check(synopsisScroll.ScrollableHeight > 0, "long synopsis scrolls within the dialog");
                synopsisScroll.ChangeView(null, synopsisScroll.ScrollableHeight, null, true); await Task.Delay(60);
                Check(_model.Route == "detail", "scrolling the synopsis dialog keeps the current detail page");
                Invoke(Walk(synopsisDialog).OfType<Button>().Single(x => Equals(x.Content, "关闭"))); await Task.Delay(300);
                Check(expand.IsEnabled && _model.Route == "detail", "closing the synopsis dialog restores the detail page");
                var reverse = Walk(PageHost).OfType<Button>().Single(x => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x) == "分集排序：正序"); Invoke(reverse); await Task.Delay(150); await Settle();
                Check(_model.EpisodesDescending, "episode direction action changes saved ordering");
                Check(Walk(PageHost).OfType<Button>().Any(x => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x) == "分集排序：倒序"), "episode direction toggle renders descending control");
                await Refresh("detail-info");
                Check(Texts().Contains("简介65"), "second detail page uses selected episode overview");
                var restored = new ViewModels.DemoViewModel(); Check(restored.EpisodesDescending, "new view-model restores episode order");
                _model.ThemeMode = "light"; SetTheme(false); await Task.Delay(100); Check(Root.RequestedTheme == ElementTheme.Light, "manual light theme is applied");
                _model.ThemeMode = "system"; SetTheme(false); await Task.Delay(100); Check(Root.RequestedTheme == ElementTheme.Default, "follow-system theme returns to platform default");
                var settings = new StackPanel(); new RuntimeSettingsPages(_model, Navigate, SetTheme).Build("播放", settings);
                Check(settings.Children.Count > 4, "real playback settings page builds all sections without an account");
                Check(WindowRoot.KeyboardAccelerators.Count(x => x.Key == global::Windows.System.VirtualKey.O) == 2, "file and link shortcuts stay registered above the player overlay");
                await VerifySilentDetailCache(Check, Path.GetDirectoryName(Path.GetFullPath(output))!);
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output))!);
                File.WriteAllText(output, JsonSerializer.Serialize(new { passed = true, assertions }, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch (Exception ex) { Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(output))!); File.WriteAllText(output, JsonSerializer.Serialize(new { passed = false, error = ex.ToString(), assertions })); }
            finally { Close(); }
        };
    }
    private async Task VerifySilentDetailCache(Action<bool, string> check, string outputDirectory)
    {
        static IEnumerable<DependencyObject> Walk(DependencyObject root)
        { yield return root; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var child in Walk(VisualTreeHelper.GetChild(root, i))) yield return child; }
        async Task WaitFor(Func<bool> condition)
        {
            for (var i = 0; i < 100 && !condition(); i++) await Task.Delay(50);
            check(condition(), "detail refresh reaches the expected completion state");
        }
        void CheckQuiet(string stage)
        {
            PageHost.UpdateLayout();
            check(_model.SelectedMedia.DetailWarning is null && !Notice.IsOpen, stage + " keeps refresh warnings out of the foreground");
            check(!Walk(PageHost).OfType<Button>().Any(x => Equals(x.Content, "重试"))
                && !Walk(PageHost).OfType<TextBlock>().Any(x => x.Text.Contains("缓存详情") || x.Text.Contains("更新失败")),
                stage + " renders no cache-update text or retry action");
        }
        ListView EpisodeNumbers() => Walk(_transitions.Content!).OfType<ListView>()
            .Single(x => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(x) == "集号");
        ScrollViewer DetailScroll() => Walk(_transitions.Content!).OfType<ScrollViewer>()
            .Single(x => x.Content is DependencyObject body && Walk(body).OfType<Controls.PlaybackProgressButton>().Any());
        async Task Capture(string name)
        {
            Directory.CreateDirectory(outputDirectory); await Task.Delay(150); PageHost.UpdateLayout();
            var bitmap = new Microsoft.UI.Xaml.Media.Imaging.RenderTargetBitmap();
            await bitmap.RenderAsync(WindowRoot); var pixels = await bitmap.GetPixelsAsync();
            using var file = File.Create(Path.Combine(outputDirectory, name + ".png")); using var stream = file.AsRandomAccessStream();
            var encoder = await global::Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(global::Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
            encoder.SetPixelData(global::Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, global::Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
                (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels.ToArray());
            await encoder.FlushAsync();
        }
        using var fixture = new DetailCacheFixture();
        var core = App.EnsureCore("OcPlayer.UiDetailCache." + Guid.NewGuid().ToString("N"));
        var profile = new ServerProfile("ui-detail-cache", "jellyfin", fixture.Url, "user", "fixture-only");
        var server = new MediaServer(core.Client, profile);
        var input = new DemoMedia("series", "Series", "", "", "", "", "", Kind: "series");
        var seed = await server.Detail(input, default);
        new BrowserCache(profile).Save("detail:series:", seed with { DetailWarning = "old optional metadata warning" });
        App.LeaveDemo(); core.SetServer(server); _model.EpisodesDescending = false; Notice.IsOpen = false;
        _transitions.SetAnimationsEnabled(false);
        try
        {
            fixture.PauseDetails(); fixture.DetailName = "Refreshed series";
            OpenDetail(input); await fixture.DetailStarted.WaitAsync(TimeSpan.FromSeconds(5));
            await WaitFor(() => !_transitions.IsTransitioning); PageHost.UpdateLayout();
            check(_model.Route == "detail" && _model.SelectedMedia.Title == seed.Title,
                "cached detail is visible while the real server response remains pending");
            check(_transitions.Content is { Opacity: 1, IsHitTestVisible: true }
                && Walk(_transitions.Content!).OfType<TextBlock>().Any(x => x.Text == seed.Title),
                "cached foreground finishes appearing and accepting input before the refresh completes");
            CheckQuiet("pending background refresh");
            check(Walk(PageHost).OfType<Controls.PlaybackProgressButton>().Single().IsEnabled,
                "cached episodes remain playable during a background refresh");
            check(!Walk(_transitions.Content!).OfType<ProgressBar>().Any(x => x.IsIndeterminate),
                "background detail refresh adds no busy indicator to cached content");
            EpisodeNumbers().SelectedIndex = 0;
            check(_model.SelectedEpisode == 1, "episode selection remains interactive during a background refresh");
            var scroll = DetailScroll();
            check(scroll.ScrollableHeight > 50, "cached detail provides a real scrollable viewport for refresh verification");
            scroll.ChangeView(null, 50, null, true); await Task.Delay(60);
            var offset = scroll.VerticalOffset;
            check(offset > 0, "cached detail remains scrollable while a server refresh is pending");
            await Capture("detail-cache-pending"); fixture.ReleaseDetails();
            await WaitFor(() => _model.SelectedMedia.Title == "Refreshed series");
            check(_model.SelectedEpisode == 1, "successful background refresh preserves the user's selected episode");
            await Task.Delay(60);
            check(Math.Abs(DetailScroll().VerticalOffset - offset) < .5, "successful background refresh preserves the detail scroll position");
            check(server.CachedDetail(input)?.Title == "Refreshed series", "successful UI refresh also updates the disk cache");
            CheckQuiet("successful background refresh");

            fixture.PauseDetails(); fixture.DetailName = "Partial series"; fixture.FailSimilar = true;
            OpenDetail(input); await fixture.DetailStarted.WaitAsync(TimeSpan.FromSeconds(5)); fixture.ReleaseDetails();
            await WaitFor(() => _model.SelectedMedia.Title == "Partial series"); CheckQuiet("optional recommendation failure");

            fixture.PauseDetails(); fixture.FailDetail = true;
            OpenDetail(input); await fixture.DetailStarted.WaitAsync(TimeSpan.FromSeconds(5));
            var cachedPageMedia = _model.SelectedMedia; CheckQuiet("cached optional warning");
            EpisodeNumbers().SelectedIndex = 0; fixture.ReleaseDetails();
            await WaitFor(() => !ReferenceEquals(_model.SelectedMedia, cachedPageMedia));
            check(_model.SelectedMedia.Title == "Partial series" && _model.SelectedMedia.Episodes?.Length == 2,
                "failed background refresh retains the cached title and playable episodes");
            check(_model.SelectedEpisode == 1, "failed background refresh also preserves the user's episode selection");
            CheckQuiet("failed background refresh"); await Capture("detail-cache-fallback");

            fixture.FailDetail = false; fixture.FailSimilar = false; fixture.PauseDetails();
            OpenDetail(input); await fixture.DetailStarted.WaitAsync(TimeSpan.FromSeconds(5));
            Navigate("settings"); fixture.ReleaseDetails(); await Task.Delay(200);
            check(_model.Route == "settings" && !Notice.IsOpen, "leaving detail cancels the pending refresh without late navigation or notices");

            fixture.FailDetail = true; OpenDetail(input with { Id = "uncached" }); await WaitFor(() => Notice.IsOpen);
            check(Notice.Message.StartsWith("无法加载详情："), "a first-load failure without cached content still explains the error");
        }
        finally { fixture.ReleaseDetails(); _load?.Cancel(); core.DisconnectServer(); core.Servers.Delete(profile.Id); }
    }

    private sealed class DetailCacheFixture : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource _stop = new();
        private TaskCompletionSource? _detailGate;
        private TaskCompletionSource _detailStarted = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public string Url { get; }
        public string DetailName = "Cached series";
        public bool FailDetail, FailSimilar;
        public Task DetailStarted => _detailStarted.Task;
        public DetailCacheFixture() { _listener.Start(); Url = "http://127.0.0.1:" + ((IPEndPoint)_listener.LocalEndpoint).Port; _ = Listen(); }
        public void PauseDetails()
        { _detailStarted = new(TaskCreationOptions.RunContinuationsAsynchronously); _detailGate = new(TaskCreationOptions.RunContinuationsAsynchronously); }
        public void ReleaseDetails() => _detailGate?.TrySetResult();
        private async Task Listen()
        {
            try { while (!_stop.IsCancellationRequested) { var client = await _listener.AcceptTcpClientAsync(_stop.Token); _ = Respond(client); } }
            catch (Exception ex) when (ex is OperationCanceledException or SocketException or ObjectDisposedException) { }
        }
        private async Task Respond(TcpClient client)
        {
            using (client) try
            {
                using var stream = client.GetStream(); using var reader = new StreamReader(stream, Encoding.UTF8, false, leaveOpen: true);
                var line = await reader.ReadLineAsync(_stop.Token); if (line is null) return;
                var uri = new Uri(Url + line.Split(' ')[1]); var path = uri.AbsolutePath;
                while (await reader.ReadLineAsync(_stop.Token) is { Length: > 0 }) { }
                var status = 200; object body;
                if (path.EndsWith("/Items/series") || path.EndsWith("/Items/uncached"))
                {
                    _detailStarted.TrySetResult(); if (_detailGate is { } gate) await gate.Task.WaitAsync(_stop.Token);
                    status = FailDetail ? 503 : 200;
                    body = new { Id = "series", Name = DetailName, Type = "Series", OriginalTitle = string.Concat(Enumerable.Repeat("Cached original title. ", 50)),
                        Overview = "The cached synopsis stays available during refresh." };
                }
                else if (path.EndsWith("/Seasons") || Uri.UnescapeDataString(uri.Query).Contains("includeItemTypes=Season", StringComparison.OrdinalIgnoreCase))
                    body = new { Items = new[] { new { Id = "s1", Name = "第 1 季", Type = "Season", IndexNumber = 1 } } };
                else if (path.EndsWith("/Episodes")) body = new { Items = Enumerable.Range(1, 2).Select(n => new { Id = "e" + n, Name = "Episode " + n,
                    Type = "Episode", SeriesId = "series", SeasonId = "s1", IndexNumber = n, ParentIndexNumber = 1, RunTimeTicks = 12000000000L,
                    UserData = new { Played = n == 1 } }).ToArray() };
                else if (path.EndsWith("/Similar")) { status = FailSimilar ? 503 : 200; body = new { Items = Array.Empty<object>() }; }
                else body = new { Items = Array.Empty<object>() };
                var payload = JsonSerializer.SerializeToUtf8Bytes(body);
                await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {payload.Length}\r\nConnection: close\r\n\r\n"), _stop.Token);
                await stream.WriteAsync(payload, _stop.Token);
            }
            catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException) { }
        }
        public void Dispose() { ReleaseDetails(); _stop.Cancel(); _listener.Stop(); _stop.Dispose(); }
    }
}
#endif

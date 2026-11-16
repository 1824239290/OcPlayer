#if DEBUG
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.Features;
using OcPlayer.Windows.Services;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Imaging;

namespace OcPlayer.Windows.Preview;

internal sealed partial class ViewingPageVerification : Window
{
    public ViewingPageVerification(string directory)
    {
        Title = "观影页面验证";
        AppWindow.ResizeClient(new global::Windows.Graphics.SizeInt32(1130, 800));
        var root = new Grid { RequestedTheme = ElementTheme.Dark, Background = new SolidColorBrush(Microsoft.UI.Colors.Black) };
        Content = root;
        root.Loaded += async (_, _) =>
        {
            Directory.CreateDirectory(directory); var assertions = new List<string>();
            void Fatal(object sender, Microsoft.UI.Xaml.UnhandledExceptionEventArgs args) => File.WriteAllText(Path.Combine(directory, "fatal.json"), JsonSerializer.Serialize(new { error = args.Exception.ToString(), args.Message, assertions }));
            Application.Current.UnhandledException += Fatal;
            // Serve bundled artwork on loopback so fixture images exercise the real image cache.
            var portProbe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0); portProbe.Start();
            var posterPort = ((System.Net.IPEndPoint)portProbe.LocalEndpoint).Port; portProbe.Stop();
            using var artworkServer = new System.Net.HttpListener(); artworkServer.Prefixes.Add($"http://localhost:{posterPort}/"); artworkServer.Start();
            var artworkTask = Task.Run(async () =>
            {
                try
                {
                    while (artworkServer.IsListening)
                    {
                        var request = await artworkServer.GetContextAsync(); var fileName = Path.GetFileName(request.Request.Url!.AbsolutePath);
                        var file = Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", fileName);
                        if (File.Exists(file) && fileName.EndsWith(".jpg")) { var bytes = await File.ReadAllBytesAsync(file); request.Response.ContentType = "image/jpeg"; request.Response.ContentLength64 = bytes.Length; await request.Response.OutputStream.WriteAsync(bytes); }
                        else request.Response.StatusCode = 404;
                        request.Response.Close();
                    }
                }
                catch (Exception ex) when (ex is System.Net.HttpListenerException or ObjectDisposedException) { }
            });
            var fixtureTitles = new[] { "学生会也有洞！", "凡人修仙传", "FX战士久留美", "药屋少女的呢喃" };
            var fixturePosters = new[] { "mac-4-primary.jpg", "mac-7-primary.jpg", "mac-6-primary.jpg", "mac-5-primary.jpg" };
            string Poster(int i) => $"http://localhost:{posterPort}/" + fixturePosters[i % 4];
            var subjectStates = new Dictionary<long, (int Type, int Rate)>();
            var chapterStates = new Dictionary<long, int>();
            (int Type, int Rate) StateFor(long id) => subjectStates.GetValueOrDefault(id, (Type: id < 1000 ? 3 : (int)(id / 1000 % 10), Rate: 8));
            object SubjectData(long id, int category = 2) => new
            {
                id, type = category, nameCN = fixtureTitles[(int)(id % 4)], name = "原文标题 " + id, eps = 12,
                date = "2026-10-01", platform = new { typeCN = "TV" }, poster = Poster((int)(id % 4)), images = new { common = $"http://localhost:{posterPort}/fanren.jpg" },
                rating = new { score = 8.1, rank = 100, total = 658 }, interest = new { type = StateFor(id).Type, rate = StateFor(id).Rate, epStatus = 6 },
                summary = string.Join("\n\n", Enumerable.Repeat("用于验证 Windows 集成页面的作品介绍、收藏状态与章节操作。介绍全文应在独立弹窗内显示，背景详情页的滚动位置保持不变。", 12)),
                infobox = Enumerable.Range(0, 20).Select(i => new { key = new[] { "中文名", "别名", "话数", "放送开始", "导演" }[i % 5], values = i % 5 == 1 ? JsonSerializer.SerializeToElement(new[] { new { k = "英文", v = "A longer alternate title that wraps over several lines" } }) : JsonSerializer.SerializeToElement("作品信息 " + i) }).ToArray(),
                tags = new[] { new { name = "校园", count = 125 }, new { name = "喜剧", count = 85 }, new { name = "动画", count = 100 } },
                collection = new { wish = 20, collect = 421, doing = 8, on_hold = 17, dropped = 10 }
            };
            object Collections(JsonElement input)
            {
                var kind = (int)Json.Number(input, "collectionType"); var category = (int)Json.Number(input, "subjectType"); var total = category == 6 ? 0 : category == 2 ? kind == 1 ? 20 : kind == 2 ? 31 : kind == 3 ? 8 : 3 : kind == 2 ? 5 : kind == 1 ? 1 : 0; var offset = (int)Json.Number(input, "offset"); var limit = (int)Json.Number(input, "limit", 100);
                long Id(int i) => category == 2 && kind == 3 ? i + 1 : category * 10000 + kind * 1000 + i + 1;
                var items = Enumerable.Range(0, total).Where(i => !subjectStates.TryGetValue(Id(i), out var state) || state.Type == kind).ToArray();
                return new { total = items.Length, data = items.Skip(offset).Take(limit).Select(i => new { type = kind, subject = SubjectData(Id(i), category) }).ToArray() };
            }
            JsonElement[] NormalEpisodes(long subject) => Enumerable.Range(1, 12).Select(n => JsonSerializer.SerializeToElement(new
                { id = subject * 100 + n, type = 0, sort = n, airdate = n <= 7 ? "2000-01-01" : "2099-01-01", nameCN = "第 " + n + " 集", collection = new { status = chapterStates.GetValueOrDefault(subject * 100 + n, n <= 6 ? 2 : 0) } }))
                .Concat(new[] { (type: 1, sort: 1), (type: 2, sort: 1), (type: 3, sort: 2) }.Select(x => JsonSerializer.SerializeToElement(new
                { id = subject * 100 + 20 + x.type, x.type, x.sort, airdate = "2000-01-01", nameCN = "其他章节", collection = new { status = chapterStates.GetValueOrDefault(subject * 100 + 20 + x.type, 0) } }))).ToArray();
            var resource = "OcPlayer.UiViewingFixture." + Guid.NewGuid().ToString("N");
            var inlineTesting = false; var episodeRequests = 0; var episodeUpdates = 0; var downloadRequests = 0; var failDownloads = false;
            var inlineStates = Enumerable.Range(1, 12).ToDictionary(n => n, n => n <= 6 ? 2 : 0);
            JsonElement[] InlineEpisodes() => Enumerable.Range(1, 12).Select(n => JsonSerializer.SerializeToElement(new
                { id = 100 + n, type = 0, sort = n, airdate = n <= 7 ? "2000-01-01" : "2099-01-01", nameCN = "第 " + n + " 集", collection = new { status = inlineStates[n] } }))
                .Concat(new[] { (id: 201, type: 1, sort: 1), (id: 202, type: 2, sort: 1), (id: 203, type: 3, sort: 2) }.Select(x => JsonSerializer.SerializeToElement(new
                { x.id, x.type, x.sort, airdate = "2000-01-01", nameCN = "其他章节", collection = new { status = 0 } }))).ToArray();
            Task<OcpResponse> Call(string method, string args, CancellationToken token)
            {
                token.ThrowIfCancellationRequested(); var input = JsonDocument.Parse(args).RootElement;
                if (method == "moviepilot.download.list") { downloadRequests++; if (failDownloads) throw new InvalidOperationException("下载器暂时不可用"); }
                if (inlineTesting && method == "bangumi.episodes") episodeRequests++;
                if (inlineTesting && method == "bangumi.updateEpisode")
                {
                    episodeUpdates++; var selected = (int)Json.Number(input, "episodeId") - 100; var state = (int)Json.Number(input, "collectionType");
                    foreach (var number in inlineStates.Keys.ToArray()) if (number == selected || Json.Get(input, "batch").ValueKind == JsonValueKind.True && number <= selected && number <= 7) inlineStates[number] = state;
                }
                if (!inlineTesting && method == "bangumi.updateEpisode")
                {
                    var selected = (long)Json.Number(input, "episodeId"); var state = (int)Json.Number(input, "collectionType"); chapterStates[selected] = state;
                    if (Json.Get(input, "batch").ValueKind == JsonValueKind.True) for (var n = 1; n <= selected % 100 && n <= 7; n++) chapterStates[selected / 100 * 100 + n] = state;
                }
                if (method == "bangumi.updateSubject")
                {
                    var id = (long)Json.Number(input, "subjectId"); var body = Json.Get(input, "body"); var previous = StateFor(id);
                    subjectStates[id] = ((int)Json.Number(body, "type", previous.Type), (int)Json.Number(body, "rate", previous.Rate));
                }
                if (method == "bangumi.request" && Json.Text(input, "url").Contains("/v1/bangumi/oauth/"))
                {
                    var uri = new Uri(Json.Text(input, "url"));
                    object payload = uri.AbsolutePath.EndsWith("authorize")
                        ? new { authorize_url = "https://bgm.tv/oauth/authorize?state=" + BangumiOAuthCallback.Query(uri)["state"] }
                        : new { access_token = "ui-oauth-token", refresh_token = "ui-refresh", expires_in = 3600 };
                    return Task.FromResult(new OcpResponse(true, 0, false, "", JsonSerializer.SerializeToElement(new { status = 200, body = JsonSerializer.Serialize(payload) })));
                }
                object value = method switch
                {
                    "bangumi.request" when Json.Text(input, "url").Contains("/collections/") => new { status = 200, body = JsonSerializer.Serialize(new { type = StateFor(long.Parse(Json.Text(input, "url").Split('/').Last())).Type, rate = StateFor(long.Parse(Json.Text(input, "url").Split('/').Last())).Rate }) },
                    "bangumi.request" => new { status = 200, body = JsonSerializer.Serialize(new { username = "test", nickname = "观影测试", sign = "此处是用户的个人签名", avatar = new { large = $"http://localhost:{posterPort}/avatar.jpg" } }) },
                    "moviepilot.login" => new { accessToken = "ui-fixture-only", user = new { name = "资源测试" } },
                    "bangumi.collections" => Collections(input),
                    "bangumi.search" => new { total = 1, data = new[] { SubjectData(901) } },
                    "bangumi.subject" => SubjectData((long)Json.Number(input, "subjectId", 1)),
                    "bangumi.episodes" when inlineTesting => new { total = 15, data = InlineEpisodes() },
                    "bangumi.episodes" => new { total = 15, data = NormalEpisodes((long)Json.Number(input, "subjectId", 1)) },
                    "bangumi.subjectCollection" => new { type = 3 },
                    "bangumi.calendar" => new[] { new { weekday = new { cn = "今天", id = ((int)DateTime.Today.DayOfWeek + 6) % 7 + 1 }, items = new[] { new { id = 1, name_cn = "测试番剧" } } } },
                    "moviepilot.subscription.list" => new { items = Enumerable.Range(0, 4).Select(i => new { id = i + 1, name = fixtureTitles[i], poster = Poster(i), total_episode = i == 1 ? 226 : 12, lack_episode = i == 1 ? 26 : 5, state = "R", season = 1 }).ToArray() },
                    "moviepilot.download.list" => new { items = new[] { new { hash = "one", name = "测试下载", progress = 45, state = "downloading", dlspeed = "3 MiB/s" } } },
                    "moviepilot.sites" => new { items = new[] { new { id = 7, name = "测试站点" } } },
                    "moviepilot.mediaSearch" => new { items = new[] { new { title = "测试媒体", type = "电视剧", tmdb_id = 123 } } },
                    _ => new { accepted = true }
                };
                return Task.FromResult(new OcpResponse(true, 0, false, "", JsonSerializer.SerializeToElement(value)));
            }
            var service = new ViewingIntegrations(Call, resource);
            try
            {
                await service.ConnectBangumi("https://example.invalid", "ui-fixture-only", default);
                await service.ConnectMoviePilot("https://example.invalid", "test", "test", default);
                await service.ConnectBangumiOAuth("https://api.bgm.tv", "https://gateway.invalid", "ui-fixture-key", async (_, state, token) =>
                {
                    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token); deadline.CancelAfter(TimeSpan.FromSeconds(15));
                    System.Diagnostics.Process? child = null;
                    try
                    {
                        var received = await BangumiOAuthBrowser.Receive(state, () =>
                        {
                            var launch = new System.Diagnostics.ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true, WindowStyle = System.Diagnostics.ProcessWindowStyle.Hidden };
                            if (string.Equals(Path.GetFileName(Environment.ProcessPath), "dotnet.exe", StringComparison.OrdinalIgnoreCase)) launch.ArgumentList.Add(Path.Combine(AppContext.BaseDirectory, "OcPlayer.Windows.dll"));
                            launch.ArgumentList.Add(BangumiOAuthBrowser.CallbackArgument);
                            launch.ArgumentList.Add("ocplayer://oauth/callback?code=ui-code&state=" + state);
                            child = System.Diagnostics.Process.Start(launch);
                        }, deadline.Token);
                        await child!.WaitForExitAsync(deadline.Token);
                        if (child.ExitCode != 0) throw new Exception("OAuth callback process failed");
                        assertions.Add("Separate callback process forwards OAuth and exits without loading the main window");
                        return received;
                    }
                    finally { if (child is { HasExited: false }) child.Kill(); child?.Dispose(); }
                }, default);
                if (service.Bangumi?.AccessToken != "ui-oauth-token") throw new Exception("OAuth UI credentials were not committed");
                var movie = new DemoMedia("viewing-ui", "测试影片", "", "2026", "科幻 / 冒险", "", "", DurationSeconds: 600);
                App.Core!.ViewingHistory.SaveActual(new ViewingRecord("ui-fixture", "local", movie, DateTimeOffset.Now, 240, false));
                for (var i = 0; i < 21; i++)
                {
                    var media = movie with { Id = "dashboard-" + i % 4, Title = fixtureTitles[i % 4], Artwork = fixturePosters[i % 4], Category = i % 2 == 0 ? "动画 / 喜剧" : "动画 / 奇幻", Kind = "episode", EpisodeLabel = "S1E" + (i + 1), Progress = 20 + i % 4 * 18 };
                    var date = i == 20 ? DateTimeOffset.Now.AddMonths(-1) : DateTimeOffset.Now.AddDays(-i);
                    App.Core.ViewingHistory.SaveActual(new ViewingRecord("dashboard-session-" + i, "local", media, date, i == 1 ? 3900 : 300 + i % 4 * 500, false));
                    if (i < 4) App.Core.LocalMedia.Add(media);
                }
                var routes = new List<string>(); var opened = new List<DemoMedia>();
                var pages = new IntegrationPages(new PageLayout(), routes.Add, opened.Add, service);
                async Task CaptureElement(FrameworkElement element, string name)
                {
                    var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(element); var pixels = await bitmap.GetPixelsAsync();
                    using var file = File.Create(Path.Combine(directory, name + ".png")); using var stream = file.AsRandomAccessStream();
                    var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
                    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels.ToArray()); await encoder.FlushAsync();
                }
                async Task Capture(string name)
                {
                    var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(root); var pixels = await bitmap.GetPixelsAsync();
                    using var file = File.Create(Path.Combine(directory, name + ".png")); using var stream = file.AsRandomAccessStream();
                    var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
                    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels.ToArray()); await encoder.FlushAsync();
                }
                foreach (var route in new[] { "viewing", "viewing:calendar", "viewing:moviepilot", "viewing:downloads", "viewing:resources:测试", "viewing:history", "settings:Bangumi", "settings:MoviePilot" })
                {
                    var page = route == "viewing" ? pages.Dashboard() : route.StartsWith("settings:") ? pages.Settings(route.EndsWith("Bangumi")) : pages.Route(route);
                    root.Children.Clear(); root.Children.Add(page);
                    await Task.Delay(500); root.UpdateLayout();
                    var messages = Descendants(root).OfType<TextBlock>().Select(x => x.Text).ToArray();
                    if (messages.Any(x => x.Contains("请求失败") || x.Contains("无法识别") || x.Contains("正在加载"))) throw new InvalidOperationException(route + ": " + string.Join(" | ", messages));
                    var combos = Descendants(root).OfType<ComboBox>().ToArray();
                    if (route == "viewing:calendar" && !combos.Any(x => x.Header?.ToString() == "星期" && x.Items.Count == 9)) throw new Exception("Calendar weekday filters are incomplete");
                    if (route == "viewing:resources:测试" && !combos.Any(x => x.Header?.ToString() == "排序" && x.Items.Count == 5)) throw new Exception("Resource sort options are incomplete");
                    assertions.Add(route + " loads without errors");
                    await Capture(route.Replace(':', '-'));
                    if (route == "viewing")
                    {
                        var dashboard = (ScrollViewer)page;
                        ((Grid)dashboard.Content).Background = new SolidColorBrush(Microsoft.UI.Colors.Black);
                        await CaptureElement((FrameworkElement)dashboard.Content, "dashboard-dark-full");
                        Button Named(string label) => Descendants(root).OfType<Button>().Single(x => AutomationProperties.GetName(x) == label);
                        void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
                        Invoke(Named("待看 20")); if (routes.LastOrDefault() != "viewing:bangumi:1") throw new Exception("Wish card does not open the wish list");
                        Invoke(Named("在看 8")); if (routes.LastOrDefault() != "viewing:bangumi:3") throw new Exception("Watching card does not open the watching list");
                        Invoke(Named("继续观看：" + fixtureTitles[0])); if (opened.LastOrDefault()?.Id != "dashboard-0") throw new Exception("Continue watching opens a different item");
                        Invoke(Named("查找订阅资源：" + fixtureTitles[0])); if (!routes.LastOrDefault()!.StartsWith("viewing:resources:media=")) throw new Exception("Subscription row lost the original media payload");
                        Invoke(Named("管理下载：测试下载")); if (routes.LastOrDefault() != "viewing:downloads") throw new Exception("Download row does not open management");
                        var menu = pages.ViewingMenu();
                        foreach (var action in menu.Items.OfType<MenuFlyoutItem>()) ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(action).GetPattern(PatternInterface.Invoke)).Invoke();
                        if (!routes.TakeLast(4).SequenceEqual(new[] { "viewing:bangumi:3", "viewing:profile", "viewing:moviepilot", "settings" })) throw new Exception("Dashboard overflow destinations differ from the reference menu");
                        var yesterday = DateTime.Today.AddDays(-1);
                        Invoke(Descendants(root).OfType<Button>().Single(x => AutomationProperties.GetName(x).StartsWith(yesterday.ToString("yyyy-MM-dd") + " ·")));
                        Invoke(Named("观看统计 上个月")); await Task.Delay(100);
                        if (!Descendants(root).OfType<TextBlock>().Any(x => x.Text == new DateTime(DateTime.Today.Year, DateTime.Today.Month, 1).AddMonths(-1).ToString("yyyy年M月"))) throw new Exception("Month navigation did not change the chart period");
                        var priorDownloads = downloadRequests; await pages.RefreshDashboard();
                        if (downloadRequests <= priorDownloads || !Descendants(root).OfType<TextBlock>().Any(x => x.Text == "当天观看")) throw new Exception("Refresh does not reload data or resets the selected day");
                        assertions.Add("Dashboard list cards, continuation, subscription payload, downloads and all overflow routes work");
                        assertions.Add("Heatmap day selection and month navigation work, and refresh retains selection");
                        failDownloads = true; await pages.RefreshDashboard(); root.UpdateLayout(); await Task.Delay(100);
                        var failureText = Descendants(root).OfType<TextBlock>().Select(x => x.Text).ToArray();
                        if (!failureText.Contains("测试下载") || !failureText.Any(x => x.Contains("下载器暂时不可用"))) throw new Exception("Failed download refresh does not retain the item and show its error: " + string.Join(" | ", failureText));
                        failDownloads = false; await pages.RefreshDashboard(); assertions.Add("Failed dashboard refresh retains existing download data and recovers on retry");
                        Invoke(Named("观看统计 下个月"));
                        dashboard.ChangeView(null, dashboard.ScrollableHeight, null, true); await Task.Delay(250); await Capture("dashboard-dark-lower");
                        root.RequestedTheme = ElementTheme.Light; root.Background = new SolidColorBrush(Microsoft.UI.Colors.White); root.UpdateLayout(); await Task.Delay(150);
                        ((Grid)dashboard.Content).Background = new SolidColorBrush(Microsoft.UI.Colors.White);
                        var themeLabels = Descendants(root).OfType<TextBlock>().Where(x => x.Text is "小时" or "Bangumi" or "点击日期查看当天统计").ToArray();
                        if (themeLabels.Length == 0 || themeLabels.Any(x => x.Foreground is SolidColorBrush brush && brush.Color.R + brush.Color.G + brush.Color.B > 500)) throw new Exception("Dashboard secondary text retains light foregrounds after switching to the light theme");
                        assertions.Add("Dashboard secondary text and graph accents update when the theme changes");
                        dashboard.ChangeView(null, 0, null, true); await Task.Delay(100); await Capture("dashboard-light-top"); await CaptureElement((FrameworkElement)dashboard.Content, "dashboard-light-full");
                        AppWindow.ResizeClient(new(650, 800)); await Task.Delay(180); root.UpdateLayout(); await CaptureElement((FrameworkElement)dashboard.Content, "dashboard-compact-full");
                        var overflowing = Descendants(root).OfType<Button>().Where(x => x.IsLoaded && x.ActualWidth > root.ActualWidth).ToArray();
                        if (overflowing.Length > 0) throw new Exception("Dashboard buttons overflow the compact viewport");
                        assertions.Add("Dashboard remains contained in a compact window in light and dark themes");
                        AppWindow.ResizeClient(new(1130, 800)); root.RequestedTheme = ElementTheme.Dark; root.Background = new SolidColorBrush(Microsoft.UI.Colors.Black);
                    }
                }
                await VerifyBangumiPages(root, pages, routes, assertions, Capture, CaptureElement);
                inlineTesting = true;
                var series = movie with { Id = "inline-bangumi", Title = "学生会也有洞！", Kind = "series", SeriesId = "inline-series", SeasonNumber = 1 };
                service.LinkBangumi(ViewingHistory.Source(App.Core?.Server), series, 1, series.Title);
                root.Children.Clear();
                var inlineHost = new Grid { Margin = new Thickness(52, 32, 52, 32), VerticalAlignment = VerticalAlignment.Top, Children = { pages.MediaAssociation(series) } };
                root.Children.Add(inlineHost); await Task.Delay(500); root.UpdateLayout();
                Button[] Chapters() => Descendants(root).OfType<Button>().Where(x => x.Tag is JsonElement).ToArray();
                var chapterButtons = Chapters();
                if (chapterButtons.Length != 15 || chapterButtons.Count(x => !x.IsEnabled) != 5) throw new Exception("Inline chapters lost main, SP, OP or ED episodes, or future episodes became actionable");
                if (Descendants(root).OfType<ComboBox>().Any() || !Descendants(root).OfType<TextBlock>().Any(x => x.Text == "其他")) throw new Exception("Inline chapters do not display their groups directly");
                if (chapterButtons.Any(x => x.ActualWidth != 56 || x.ActualHeight != 52 || x.Content is not StackPanel { Children.Count: 2 })) throw new Exception("Inline chapter tiles are not compact two-line controls");
                if (!Descendants(root).OfType<Button>().Any(x => AutomationProperties.GetName(x) == "打开 Bangumi 条目：" + series.Title)) throw new Exception("Inline subject link is missing from the header");
                var optionsButton = Descendants(root).OfType<Button>().Single(x => AutomationProperties.GetName(x) == "Bangumi 关联选项");
                if (optionsButton.Flyout is not MenuFlyout optionsMenu || !optionsMenu.Items.OfType<MenuFlyoutItem>().Any(x => x.Text == "重新关联")) throw new Exception("Association actions were lost when compacting the header");
                assertions.Add("Inline Bangumi header and two-line chapter tiles display all groups and disable unaired episodes");
                await Capture("detail-bangumi-dark");
                var seventh = chapterButtons.Single(x => x.Tag is JsonElement episode && Json.Number(episode, "id") == 107);
                var watchedMenu = (MenuFlyout)seventh.Flyout;
                var batchAction = watchedMenu.Items.OfType<MenuFlyoutItem>().Single(x => x.Text == "看到此集");
                ((IInvokeProvider)new MenuFlyoutItemAutomationPeer(batchAction).GetPattern(PatternInterface.Invoke)).Invoke();
                for (var attempt = 0; attempt < 100 && !Chapters().Any(x => AutomationProperties.GetName(x) == "Bangumi 本篇 07 · 看过"); attempt++) await Task.Delay(30);
                if (episodeUpdates != 1 || !Chapters().Any(x => AutomationProperties.GetName(x) == "Bangumi 本篇 07 · 看过") || inlineStates[8] != 0) throw new Exception("Inline chapter action did not refresh watched state or modified unaired chapters");
                assertions.Add("Inline chapter batch action updates watched state and refreshes without marking unaired episodes");
                var refreshButton = Descendants(root).OfType<Button>().Single(x => AutomationProperties.GetName(x) == "刷新 Bangumi 章节"); var priorRequests = episodeRequests;
                ((IInvokeProvider)new ButtonAutomationPeer(refreshButton).GetPattern(PatternInterface.Invoke)).Invoke(); await Task.Delay(200);
                if (episodeRequests <= priorRequests || Chapters().Length != 15) throw new Exception("Inline refresh icon does not reload all chapters");
                assertions.Add("Inline refresh icon reloads both chapter groups");
                root.RequestedTheme = ElementTheme.Light; root.Background = new SolidColorBrush(Microsoft.UI.Colors.White); await Task.Delay(150); await Capture("detail-bangumi-light");
                AppWindow.ResizeClient(new(650, 800)); await Task.Delay(200); root.UpdateLayout(); await Capture("detail-bangumi-compact");
                if (inlineHost.ActualWidth > root.ActualWidth || !Descendants(root).OfType<OcPlayer.Windows.Controls.HorizontalMediaRail>().Any()) throw new Exception("Inline chapters overflow a narrow window");
                assertions.Add("Inline Bangumi groups remain contained in horizontal rails in a narrow window");
                service.Enable("bangumi", false); service.Enable("moviepilot", false);
                root.Children.Clear(); root.Children.Add(pages.Dashboard()); await Task.Delay(300);
                var disabled = Descendants(root).OfType<TextBlock>().Select(x => x.Text).ToArray();
                if (disabled.Contains("番剧放送") || disabled.Contains("订阅追更") || disabled.Contains("下载任务")) throw new Exception("Disabled integration remains visible");
                assertions.Add("Disabled integration modules disappear");
                File.WriteAllText(Path.Combine(directory, "results.json"), JsonSerializer.Serialize(new { passed = true, assertions }, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch (Exception ex) { File.WriteAllText(Path.Combine(directory, "results.json"), JsonSerializer.Serialize(new { passed = false, error = ex.ToString(), assertions })); }
            finally { Application.Current.UnhandledException -= Fatal; artworkServer.Stop(); await artworkTask; await service.Logout("bangumi"); await service.Logout("moviepilot"); Close(); }
        };
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = VisualTreeHelper.GetChild(root, i); yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
#endif

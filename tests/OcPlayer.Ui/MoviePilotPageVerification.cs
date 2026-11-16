#if DEBUG
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.Features;
using OcPlayer.Windows.Services;
using Windows.Graphics.Imaging;

namespace OcPlayer.Windows.Preview;

internal sealed class MoviePilotPageVerification : Window
{
    public MoviePilotPageVerification(string directory)
    {
        Title = "MoviePilot 布局验证"; AppWindow.ResizeClient(new(1432, 768));
        var root = new Grid { RequestedTheme = ElementTheme.Dark, Background = new SolidColorBrush(Microsoft.UI.Colors.Black) }; Content = root;
        root.Loaded += async (_, _) =>
        {
            Directory.CreateDirectory(directory); var assertions = new List<string>(); var routes = new List<string>();
            void Resize(double width, double height) => AppWindow.ResizeClient(new((int)(width * root.XamlRoot.RasterizationScale), (int)(height * root.XamlRoot.RasterizationScale)));
            Resize(1432, 768);
            void Assert(bool passed, string message) { if (!passed) throw new Exception(message); assertions.Add(message); }
            using var server = new System.Net.HttpListener();
            var probe = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0); probe.Start(); var port = ((System.Net.IPEndPoint)probe.LocalEndpoint).Port; probe.Stop();
            server.Prefixes.Add($"http://localhost:{port}/"); server.Start();
            var serve = Task.Run(async () =>
            {
                try
                {
                    while (server.IsListening)
                    {
                        var request = await server.GetContextAsync(); var name = Path.GetFileName(request.Request.Url!.AbsolutePath); var path = Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", name);
                        if (name.EndsWith(".jpg") && File.Exists(path)) { var bytes = await File.ReadAllBytesAsync(path); request.Response.ContentType = "image/jpeg"; request.Response.ContentLength64 = bytes.Length; await request.Response.OutputStream.WriteAsync(bytes); }
                        else request.Response.StatusCode = 404; request.Response.Close();
                    }
                }
                catch (Exception ex) when (ex is System.Net.HttpListenerException or ObjectDisposedException) { }
            });
            var names = new[] { "凡人修仙传", "学生会也有洞！", "FX战士久留美", "药屋少女的呢喃", "冰之城墙", "沙丘" };
            var posters = new[] { "mac-7-primary.jpg", "mac-4-primary.jpg", "mac-6-primary.jpg", "mac-5-primary.jpg", "ice-castle.jpg", "dune.jpg" };
            JsonElement Media(int i, bool subscription = false) => JsonSerializer.SerializeToElement(new
            {
                id = i + 1, name = names[i % 6], title = names[i % 6], year = i == 0 ? "2020" : "2026", title_year = names[i % 6] + (i == 0 ? " (2020)" : " (2026)"),
                type = i % 6 == 5 ? "电影" : "电视剧", media_source = i == 0 ? "bangumi" : "themoviedb", media_id = i == 0 ? "bangumi:101" : "tmdb:" + (101 + i), tmdb_id = i == 0 ? (int?)null : 101 + i,
                bangumi_id = i == 0 ? (int?)101 : null, poster = $"http://localhost:{port}/" + posters[i % 6], vote_average = 8.5,
                overview = "看机智的凡人小子韩立如何稳健发展、步步为营，战魔道、夺至宝，成为纵横三界的强者。用于检查媒体摘要、来源、订阅状态和资源下载。",
                total_episode = subscription ? i == 0 ? 226 : 12 : 0, lack_episode = i == 0 ? 26 : 5, state = "R", season = i == 4 ? 6 : 1
            });
            JsonElement Torrent(int i) => JsonSerializer.SerializeToElement(new
            {
                torrent = new { title = $"A Record Of Mortals Journey To Immortality S01E{200 - i} 2020 2160p Bilibili WEB-DL HDR H265 AAC-ADWeb", description = $"[连载] 凡人修仙传 / A Record Of Mortals Journey To Immortality 第 {200 - i} 集", site_name = i % 2 == 0 ? "观众" : "测试站点", labels = new[] { "官方", "国语" }, size = (1.29 + i * .1) * 1073741824, seeders = 467 - i, pubdate = "2天12时", pri_order = 10 - i },
                meta = new { season_episode = "S01", video_encode = "H265", edition = "WEB-DL", resource_pix = "2160p", resource_team = "ADWeb" }
            });
            var finish = new TaskCompletionSource<JsonElement>(); var searchId = ""; JsonElement downloaded = default;
            Task<OcpResponse> Call(string method, string args, CancellationToken token)
            {
                var input = JsonDocument.Parse(args).RootElement.Clone();
                if (method == "moviepilot.torrentSearch") { searchId = Json.Text(input, "requestId"); return CompleteSearch(); }
                if (method == "moviepilot.download.add") downloaded = input;
                object value = method switch
                {
                    "moviepilot.login" => new { accessToken = "ui-fixture", user = new { name = "布局验证" } },
                    "moviepilot.subscription.list" => new { items = Enumerable.Range(0, 6).Select(i => Media(i, true)).ToArray() },
                    "moviepilot.mediaSearch" => new { items = Enumerable.Range(0, 19).Select(i => Media(i)).ToArray() },
                    "moviepilot.sites" => new { items = new[] { new { id = 7, name = "观众" }, new { id = 8, name = "测试站点" } } },
                    _ => new { accepted = true }
                };
                return Task.FromResult(new OcpResponse(true, 0, false, "", JsonSerializer.SerializeToElement(value)));
                async Task<OcpResponse> CompleteSearch() => new(true, 0, false, "", await finish.Task.WaitAsync(token));
            }
            var service = new ViewingIntegrations(Call, "OcPlayer.MoviePilotUi." + Guid.NewGuid().ToString("N"));
            try
            {
                await service.ConnectMoviePilot("https://example.invalid", "test", "test", default);
                var pages = new IntegrationPages(new PageLayout(), routes.Add, _ => { }, service);
                async Task Capture(string name)
                {
                    root.UpdateLayout(); var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(root); var pixels = await bitmap.GetPixelsAsync();
                    using var file = File.Create(Path.Combine(directory, name + ".png")); using var stream = file.AsRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
                    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels.ToArray()); await encoder.FlushAsync();
                }
                async Task Wait(Func<bool> condition)
                { for (var i = 0; i < 200 && !condition(); i++) await Task.Delay(25); root.UpdateLayout(); if (!condition()) throw new Exception("Timed out waiting for MoviePilot UI"); }
                async Task Mount(string route)
                {
                    root.Children.Clear(); root.Children.Add(pages.Route(route));
                    var header = new Grid { Height = 48, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(52, 0, 52, 0), ColumnSpacing = 12 };
                    header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new ColumnDefinition());
                    var title = new TextBlock { Text = pages.HeaderTitle, FontSize = 14, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center }; header.Children.Add(title);
                    if (pages.HeaderLeading is { } leading) { Grid.SetColumn(leading, 1); leading.VerticalAlignment = VerticalAlignment.Center; header.Children.Add(leading); }
                    if (pages.HeaderTrailing is { } trailing)
                    {
                        Grid.SetColumn(trailing, 2); trailing.HorizontalAlignment = HorizontalAlignment.Right; trailing.VerticalAlignment = VerticalAlignment.Center; header.Children.Add(trailing);
                        if (trailing is AutoSuggestBox search) { void FitSearch() => search.Width = root.ActualWidth < 800 ? 170 : 280; header.SizeChanged += (_, _) => FitSearch(); FitSearch(); }
                    }
                    root.Children.Add(header); await Task.Delay(350); root.UpdateLayout();
                }
                Button Named(string name) => Descendants(root).OfType<Button>().Single(x => AutomationProperties.GetName(x) == name);
                void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
                Border[] Cards(string tag) => Descendants(root).OfType<Border>().Where(x => Equals(x.Tag, tag)).ToArray();
                Button[] Subscriptions() => Descendants(root).OfType<Button>().Where(x => AutomationProperties.GetName(x).StartsWith("MoviePilot 订阅 ")).ToArray();
                ContentDialog? Dialog() => VisualTreeHelper.GetOpenPopupsForXamlRoot(root.XamlRoot).SelectMany(x => Descendants(x.Child).Prepend(x.Child)).OfType<ContentDialog>().FirstOrDefault();
                await Mount("viewing:moviepilot"); await Wait(() => Subscriptions().Length == 6);
                await Wait(() => Descendants(root).OfType<Image>().Count(x => x.Source is not null) == 6);
                var subscriptionCards = Subscriptions();
                await Capture("subscriptions-dark");
                Assert(subscriptionCards.Select(x => x.TransformToVisual(root).TransformPoint(new()).Y).Distinct().Count() == 1, "Wide subscription layout shows six posters in one row");
                Assert(subscriptionCards.All(x => Descendants(x).OfType<Grid>().Any(frame => Equals(frame.Tag, "MoviePilot.PosterFrame") && Math.Abs(frame.ActualHeight / frame.ActualWidth - 1.5) < .01)), "All subscription posters keep the 2:3 aspect ratio");
                Assert(subscriptionCards.All(x => x.ContextFlyout is MenuFlyout menu && menu.Items.Count == 5), "Subscription context menus retain edit, search, refresh and delete actions");
                await Capture("subscriptions-dark");
                var category = Descendants(root).OfType<SelectorBar>().Single();
                Assert(category.Items.All(item => Descendants(item).OfType<TextBlock>().Any(label =>
                {
                    var top = label.TransformToVisual(item).TransformPoint(new()).Y;
                    return label.Text == item.Text && top >= 0 && top + label.ActualHeight <= item.ActualHeight;
                })), "Category labels fit entirely within their compact controls without clipping");
                category.SelectedItem = category.Items[1]; await Task.Delay(50);
                Assert(Subscriptions().Length == 1, "Movie category filters subscription posters"); category.SelectedItem = category.Items[2]; await Task.Delay(50); Assert(Subscriptions().Length == 5, "TV category filters subscription posters"); category.SelectedItem = category.Items[0];
                Resize(650, 800); await Task.Delay(150); root.UpdateLayout(); Assert(Subscriptions().All(x => x.ActualWidth <= 240), "Compact subscription grid adjusts its column widths"); await Capture("subscriptions-compact");
                root.RequestedTheme = ElementTheme.Light; root.Background = new SolidColorBrush(Microsoft.UI.Colors.White); await Capture("subscriptions-light");
                Resize(1432, 768); root.RequestedTheme = ElementTheme.Dark; root.Background = new SolidColorBrush(Microsoft.UI.Colors.Black);
                await Mount("viewing:moviepilot:" + Uri.EscapeDataString("凡人修仙传")); await Wait(() => Cards("MoviePilot.MediaResult").Length == 19);
                Assert(Descendants(root).OfType<SelectorBar>().All(x => VisualTreeHelper.GetParent(x) is FrameworkElement parent && VisualTreeHelper.GetParent(parent) is FrameworkElement controls && controls.Visibility == Visibility.Collapsed), "Media search hides subscription category controls");
                var firstResult = Cards("MoviePilot.MediaResult")[0]; var action = Descendants(firstResult).OfType<Button>().Single(x => AutomationProperties.GetName(x).StartsWith("MoviePilot 查资源 "));
                Assert(action.TransformToVisual(firstResult).TransformPoint(new()).X > firstResult.ActualWidth / 2, "Media result actions align to the right of the poster and metadata");
                var subscribed = Descendants(firstResult).OfType<DropDownButton>().Single(); Assert(!subscribed.IsEnabled, "Matching subscribed media shows a disabled subscribed control");
                await Capture("media-results-dark"); Resize(650, 800); await Task.Delay(150); root.UpdateLayout(); await Capture("media-results-compact");
                Assert(Cards("MoviePilot.MediaResult").All(x => x.ActualWidth <= root.ActualWidth - 104), "Compact media rows remain within page margins");
                Resize(1432, 768); await Mount(IntegrationPages.ResourceRoute(Media(0, true)));
                Assert(pages.HeaderTitle == "凡人修仙传" && pages.HeaderBackdrop?.EndsWith(posters[0]) == true, "Resource title and fixed backdrop use the selected media");
                Assert(Descendants(root).OfType<TextBlock>().Any(x => x.Text.Contains("没有 TMDB 编号")), "Resource header shows the missing TMDB warning");
                Assert(!Descendants(root).OfType<ComboBox>().Any(x => x.IsLoaded && x.ActualHeight > 0), "Initial resource page keeps media selection and sort controls out of the content flow");
                await Capture("resources-initial-dark"); Invoke(Named("搜索 MoviePilot 站点资源")); await Wait(() => searchId.Length > 0);
                var partial = Enumerable.Range(0, 4).Select(Torrent).ToArray();
                service.ReceiveCoreEvent("moviepilot.searchProgress", JsonSerializer.SerializeToElement(new { requestId = searchId, items = partial, progress = new { finished = 10, total = 32 } }));
                await Wait(() => Cards("MoviePilot.TorrentResult").Length == 4);
                Assert(Descendants(root).OfType<ProgressRing>().Any(x => x.IsActive), "Streaming resource results keep the progress card active");
                var filterButtons = Descendants(root).OfType<Button>().Where(x => AutomationProperties.GetName(x).StartsWith("MoviePilot 筛选 ")).ToArray();
                Assert(filterButtons.Length == 7 && filterButtons.Select(x => x.TransformToVisual(root).TransformPoint(new()).Y).Distinct().Count() == 1, "All seven resource filters fit on the same wide toolbar row");
                await Capture("resources-streaming-dark");
                Invoke(Named("MoviePilot 筛选 站点")); await Wait(() => Dialog() is not null);
                Assert(!finish.Task.IsCompleted, "Resource filter dialog opens while the search is still running"); Dialog()!.Hide(); await Task.Delay(100);
                var download = Descendants(root).OfType<Button>().First(x => AutomationProperties.GetName(x).StartsWith("MoviePilot 下载 A Record")); Invoke(download); await Wait(() => Dialog() is not null);
                var confirm = Descendants(Dialog()!).OfType<Button>().Single(x => x.Name == "PrimaryButton"); Invoke(confirm); await Wait(() => downloaded.ValueKind == JsonValueKind.Object);
                Assert(Json.Text(Json.Get(downloaded, "media"), "media_id") == "bangumi:101" && Json.Title(Json.Get(downloaded, "torrent")) == Json.Title(Json.Get(partial[0], "torrent")), "Download during streaming preserves the selected media and original torrent payload");
                finish.SetResult(JsonSerializer.SerializeToElement(new { items = partial })); await Wait(() => !Descendants(root).OfType<ProgressRing>().Any(x => x.IsActive));
                var sort = Descendants(root).OfType<ComboBox>().Single(x => AutomationProperties.GetName(x) == "MoviePilot 资源排序"); sort.SelectedIndex = 3; Invoke(Named("MoviePilot 切换排序方向"));
                Assert(service.Preference("moviepilot.resource.sort") == "3" && service.Preference("moviepilot.resource.ascending") == "true", "Resource sort field and direction persist");
                root.RequestedTheme = ElementTheme.Light; root.Background = new SolidColorBrush(Microsoft.UI.Colors.White); await Task.Delay(100); await Capture("resources-results-light");
                Resize(650, 800); await Task.Delay(150); root.UpdateLayout();
                Assert(filterButtons.Select(x => x.TransformToVisual(root).TransformPoint(new()).Y).Distinct().Count() > 1, "Compact resource toolbar wraps its controls");
                Assert(Cards("MoviePilot.TorrentResult").All(x => x.ActualWidth <= root.ActualWidth - 104), "Compact resource cards keep download buttons within the viewport"); await Capture("resources-results-compact");
                File.WriteAllText(Path.Combine(directory, "results.json"), JsonSerializer.Serialize(new { passed = true, assertions }, new JsonSerializerOptions { WriteIndented = true }));
            }
            catch (Exception ex) { File.WriteAllText(Path.Combine(directory, "results.json"), JsonSerializer.Serialize(new { passed = false, error = ex.ToString(), assertions }, new JsonSerializerOptions { WriteIndented = true })); }
            finally { server.Stop(); await serve; await service.Logout("moviepilot"); Close(); }
        };
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) { var child = VisualTreeHelper.GetChild(parent, i); yield return child; foreach (var descendant in Descendants(child)) yield return descendant; }
    }
}
#endif

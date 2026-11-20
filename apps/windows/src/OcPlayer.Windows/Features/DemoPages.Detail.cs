using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed partial class DemoPages
{
    private UIElement Welcome()
    {
        var root = Stack(24); root.Children.Add(Text("欢迎使用 OcPlayer", 32, true));
        root.Children.Add(Muted("连接 Jellyfin / Emby，浏览你的媒体库；也可以从标题栏打开本地文件或直连链接。"));
        var posters = Row(14);
        foreach (var media in DemoCatalog.All.Take(6)) { var poster = Poster(media, 190); poster.Width = 126; poster.Opacity = .8; posters.Children.Add(poster); }
        root.Children.Add(new OcPlayer.Windows.Controls.HorizontalMediaRail(posters, "欢迎海报墙"));
        root.Children.Add(Button("连接服务器", () => navigate("settings:连接服务器"), true));
        if (App.Core?.Servers.Items.Count > 0) root.Children.Add(Button("使用已保存的服务器", () => navigate("settings:服务器管理")));
        return pageLayout.Scroll(root, new Thickness(52, 36, 52, 36));
    }
    private static T? FindChild<T>(DependencyObject parent) where T : DependencyObject
    {
        if (parent is T found) return found;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) if (FindChild<T>(VisualTreeHelper.GetChild(parent, i)) is { } child) return child;
        return null;
    }
    private static UIElement ExpandableSynopsis(string text, int maxLines = 2)
    {
        var panel = Stack(4); var body = Text(string.IsNullOrWhiteSpace(text) ? "暂无简介" : text, 13);
        body.MaxLines = maxLines; body.LineHeight = 20; body.TextTrimming = TextTrimming.CharacterEllipsis; panel.Children.Add(body);
        var toggle = new Button { Content = "展开全文", Padding = new Thickness(8, 2, 8, 2), FontSize = 12 };
        toggle.Click += async (_, _) =>
        {
            var fullText = Text(text, 14); fullText.LineHeight = 24; fullText.IsTextSelectionEnabled = true;
            var dialog = new ContentDialog
            {
                XamlRoot = panel.XamlRoot, Title = "简介", CloseButtonText = "关闭", DefaultButton = ContentDialogButton.Close,
                RequestedTheme = panel.ActualTheme,
                Content = new ScrollViewer
                {
                    Content = fullText, MaxHeight = Math.Max(120, Math.Min(480, panel.XamlRoot.Size.Height - 200)),
                    VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                    HorizontalScrollMode = ScrollMode.Disabled
                }
            };
            void HideDialog(object sender, RoutedEventArgs args) => dialog.Hide();
            toggle.IsEnabled = false; panel.Unloaded += HideDialog;
            try { await dialog.ShowAsync(); }
            finally { panel.Unloaded -= HideDialog; toggle.IsEnabled = true; }
        };
        if (!string.IsNullOrWhiteSpace(text)) panel.Children.Add(toggle); return panel;
    }
    private UIElement CollectionMembers(DemoMedia media)
    {
        var root = Stack(12); root.Children.Add(Text("合集内容", 20, true));
        var items = (media.Members ?? []).ToList(); var list = new GridView { SelectionMode = ListViewSelectionMode.None, IsItemClickEnabled = true, MaxHeight = 600 };
        var count = Muted(""); var more = new Button { Content = "加载更多" }; var status = Muted(""); var start = items.Count;
        void Render()
        {
            list.Items.Clear(); foreach (var item in items) list.Items.Add(MediaCard(item, open, 160));
            count.Text = $"已加载 {items.Count}" + (media.MemberCount is { } total ? $" / {total}" : "");
            more.Visibility = media.MemberCount is { } n ? items.Count < n ? Visibility.Visible : Visibility.Collapsed : start % 60 == 0 && start > 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        Render(); root.Children.Add(count); root.Children.Add(list); root.Children.Add(status); root.Children.Add(more);
        more.Click += async (_, _) =>
        {
            if (App.Core?.Server is not { } server) return; more.IsEnabled = false; status.Text = "正在加载…";
            try { var page = await server.BrowsePage(media.Id, "", new LibrarySortSettings(), start, CancellationToken.None, true); start = page.NextIndex; items.AddRange(page.Items.Where(x => items.All(y => x.Id != y.Id))); Render(); more.Visibility = page.HasMore ? Visibility.Visible : Visibility.Collapsed; status.Text = ""; }
            catch (Exception ex) { status.Text = ex.Message; more.Content = "重试加载"; }
            finally { more.IsEnabled = true; }
        }; return root;
    }
    private readonly Dictionary<string, JsonElement> _fileInfoCache = [];
    private UIElement MediaInformation(DemoMedia media)
    {
        var root = Stack(10); var itemId = media.Kind == "series" ? media.Episodes?.FirstOrDefault(x => x.Number == model.SelectedEpisode)?.MediaId : media.Id;
        if (App.Core?.Server is not { } server || itemId is null || media.SourceUri is not null || media.Kind == "boxSet")
        { root.Children.Add(Muted("此条目暂无服务器媒体信息。")); return root; }
        var key = server.Profile.Id + ":" + server.Profile.UserId + ":" + itemId;
        usingPlaceholder();
        void usingPlaceholder() { root.Children.Add(new ProgressRing { IsActive = true, Width = 24, Height = 24 }); }
        var disposed = false; var cancellation = new CancellationTokenSource();
        root.Unloaded += (_, _) => { disposed = true; cancellation.Cancel(); };
        async void Load(bool force = false)
        {
            try
            {
                JsonElement file;
                if (!force && _fileInfoCache.TryGetValue(key, out var cached)) file = cached;
                else { var info = await server.Request("media.fileInfo", new { itemId }, cancellation.Token); file = info.GetProperty("fileInfo").Clone(); _fileInfoCache[key] = file; }
                if (disposed) return; root.Children.Clear();
                if (file.ValueKind != JsonValueKind.Object) { root.Children.Add(Muted("服务器未提供此文件的媒体信息。")); return; }
                root.Children.Add(Muted("共 " + J(file, "sourceCount", "1") + " 个版本"));
                if (file.TryGetProperty("video", out var video) && video.ValueKind == JsonValueKind.Object)
                {
                    var width = N(video, "width"); var height = N(video, "height");
                    Add("视频", new[] { "分辨率 / 宽高比  " + (width > 0 && height > 0 ? $"{width} × {height} · {width / height:0.###}:1" : "未知"),
                        "编码 / Profile  " + J(video, "codec") + " · " + J(video, "profile"), "码率  " + Bitrate(N(video,"bitrate")),
                        "帧率  " + J(video,"frameRate") + " fps", "动态范围  " + J(video,"videoRangeType"),
                        "色彩  " + J(video,"colorPrimaries") + " · " + J(video,"colorTransfer") + " · " + J(video,"colorSpace") + " · " + J(video,"colorRange"),
                        "位深 / 扫描  " + J(video,"bitDepth") + " bit · " + (J(video,"isInterlaced") == "True" ? "隔行" : "逐行") });
                }
                if (file.TryGetProperty("audioTracks", out var tracks) && tracks.ValueKind == JsonValueKind.Array)
                    foreach (var track in tracks.EnumerateArray()) Add("音轨", new[] { J(track,"title") + " · " + J(track,"language") + " · " + J(track,"codec"), J(track,"channels") + " 声道 · " + J(track,"channelLayout") + " · " + J(track,"sampleRate") + " Hz · " + Bitrate(N(track,"bitrate")) + Flags(track) });
                if (file.TryGetProperty("subtitleTracks", out var subtitles) && subtitles.ValueKind == JsonValueKind.Array)
                    foreach (var track in subtitles.EnumerateArray()) Add("字幕", new[] { J(track,"title") + " · " + J(track,"language") + " · " + J(track,"codec") + Flags(track) });
                Add("文件", new[] { "容器  " + J(file,"container"), "大小  " + (N(file,"sizeBytes") / 1048576).ToString("N1") + " MiB", "文件名  " + J(file,"fileName"), "时长  " + TimeSpan.FromSeconds(Math.Max(0,N(file,"durationSeconds"))).ToString(@"hh\:mm\:ss") });
                root.Children.Add(Button("刷新媒体信息", () => Load(true)));
            }
            catch (OperationCanceledException) { }
            catch (Exception ex) { if (!disposed) { root.Children.Clear(); root.Children.Add(Muted("媒体信息加载失败：" + ex.Message)); root.Children.Add(Button("重试", () => Load(true))); } }
        }
        void Add(string heading, string[] fields) { var block = Stack(8); block.Children.Add(Text(heading, 13, true)); foreach (var field in fields) block.Children.Add(Muted(field, 12)); root.Children.Add(Panel(block, new Thickness(18))); }
        root.Loaded += (_, _) => { cancellation.Dispose(); cancellation = new CancellationTokenSource(); disposed = false; Load(); }; return root;
    }
    private static string Flags(JsonElement value) => string.Join("", new[] { ("isDefault", " · 默认"), ("isForced", " · 强制"), ("isExternal", " · 外挂") }.Where(x => value.TryGetProperty(x.Item1, out var flag) && flag.ValueKind == JsonValueKind.True).Select(x => x.Item2));
    private static string J(JsonElement value, string name, string fallback = "") => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var field) && field.ValueKind is not (JsonValueKind.Null or JsonValueKind.Undefined) ? field.ToString() : fallback;
    private static double N(JsonElement value, string name) => double.TryParse(J(value, name), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var n) ? n : 0;
    private static string Bitrate(double value) => value <= 0 ? "未知" : value >= 1000000 ? $"{value / 1000000:0.##} Mbps" : $"{value / 1000:0.#} kbps";
}

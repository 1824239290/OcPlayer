using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed partial class IntegrationPages
{
    private static Style DashboardStyle(string key) => (Style)Application.Current.Resources[key];
    private static SolidColorBrush DashboardNeutral(int alpha) => new(global::Windows.UI.Color.FromArgb((byte)alpha, 128, 128, 128));
    private static Brush DashboardOrange => new SolidColorBrush(global::Windows.UI.Color.FromArgb(255, 246, 150, 48));
    private static TextBlock DashboardMuted(string text, double size = 12) => new()
    { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, Style = DashboardStyle("DashboardMutedTextStyle") };
    private static Border DashboardCard(UIElement content, double padding = 16) => new()
    { Style = DashboardStyle("DashboardCardStyle"), Child = content, Padding = new Thickness(padding), VerticalAlignment = VerticalAlignment.Top };
    private static TextBlock DashboardLabel(string text, double size = 12, bool strong = false)
    {
        var label = Text(text, size, strong); label.TextWrapping = TextWrapping.NoWrap; label.TextTrimming = TextTrimming.CharacterEllipsis; return label;
    }
    private static TextBlock DashboardEmpty(string text)
    { var label = DashboardMuted(text, 12); label.Margin = new Thickness(8, 14, 8, 14); return label; }
    private static Button DashboardAction(string text, Action action)
    {
        var button = new Button { Style = DashboardStyle("DashboardActionButtonStyle"), Content = text };
        button.Click += (_, _) => action(); return button;
    }
    private static Button DashboardLink(string text, Action action, bool chevron = true)
    {
        var button = DashboardAction(text, action); button.FontSize = 11; button.Padding = new Thickness(2, 4, 2, 4);
        var row = Row(6); row.VerticalAlignment = VerticalAlignment.Center; row.Children.Add(DashboardLabel(text, 11));
        if (chevron) row.Children.Add(new FontIcon { Glyph = "\uE76C", FontSize = 9 });
        button.Content = row; AutomationProperties.SetName(button, text); return button;
    }
    private static Grid DashboardHeading(string title, UIElement? action = null)
    {
        var grid = new Grid { ColumnSpacing = 12 }; grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = DashboardLabel(title, 13, true); label.VerticalAlignment = VerticalAlignment.Center; grid.Children.Add(label);
        if (action is FrameworkElement element) { element.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(element, 1); grid.Children.Add(element); }
        return grid;
    }
    private static StackPanel DashboardSection(string title, UIElement? action, UIElement content)
    { var section = Stack(10); section.Children.Add(DashboardHeading(title, action)); section.Children.Add(content); return section; }
    private static Grid DashboardPair(FrameworkElement left, FrameworkElement right, double breakpoint = 700)
    {
        var grid = new Grid { ColumnSpacing = 14, RowSpacing = 14 };
        grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        left.VerticalAlignment = right.VerticalAlignment = VerticalAlignment.Top; grid.Children.Add(left); grid.Children.Add(right);
        void Arrange()
        {
            var narrow = grid.ActualWidth > 0 && grid.ActualWidth < breakpoint;
            Grid.SetColumnSpan(left, narrow ? 2 : 1); Grid.SetColumnSpan(right, narrow ? 2 : 1);
            Grid.SetColumn(right, narrow ? 0 : 1); Grid.SetRow(right, narrow ? 1 : 0);
        }
        grid.SizeChanged += (_, _) => Arrange(); Arrange(); return grid;
    }
    private static Border DashboardArtwork(string url, double width, double height, double corner = 5, string glyph = "\uE714")
    {
        var image = new Border { Width = width, Height = height, CornerRadius = new CornerRadius(corner), Background = DashboardNeutral(35), VerticalAlignment = VerticalAlignment.Center };
        image.Child = string.IsNullOrEmpty(url) ? new FontIcon { Glyph = glyph, FontSize = 18, Opacity = .45 } : Image(DemoMedia.AssetPath(url));
        return image;
    }
    private static Grid DashboardProgress(double percent, Brush? color = null, double height = 3)
    {
        var grid = new Grid { Height = height }; grid.Children.Add(new Border { Background = DashboardNeutral(45), CornerRadius = new CornerRadius(height / 2) });
        var fill = new Border { Style = DashboardStyle("DashboardProgressFillStyle"), CornerRadius = new CornerRadius(height / 2), HorizontalAlignment = HorizontalAlignment.Left };
        if (color is not null) fill.Background = color;
        grid.Children.Add(fill); grid.SizeChanged += (_, _) => fill.Width = grid.ActualWidth * Math.Clamp(double.IsFinite(percent) ? percent : 0, 0, 100) / 100;
        return grid;
    }
    private static Button DashboardRow(UIElement content, Action action, string label)
    {
        var button = new Button { Style = DashboardStyle("DashboardRowButtonStyle"), Content = content };
        AutomationProperties.SetName(button, label); button.Click += (_, _) => action(); return button;
    }
    private static Grid DashboardRowContent(FrameworkElement artwork, FrameworkElement text, FrameworkElement? trailing = null)
    {
        var grid = new Grid { ColumnSpacing = 12 }; grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); grid.Children.Add(artwork);
        text.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(text, 1); grid.Children.Add(text);
        trailing ??= new FontIcon { Glyph = "\uE76C", FontSize = 10, Opacity = .45 };
        Grid.SetColumn(trailing, 2); grid.Children.Add(trailing); return grid;
    }
    private Button DashboardPrompt(string title, string subtitle, string route)
    {
        var text = Stack(3); text.Children.Add(DashboardLabel(title, 13, true)); text.Children.Add(DashboardMuted(subtitle, 11));
        var button = DashboardRow(DashboardRowContent(new FontIcon { Glyph = "\uE8F1", FontSize = 18, Opacity = .6 }, text), () => navigate(route), title);
        button.Style = DashboardStyle("DashboardCountButtonStyle"); button.Padding = new Thickness(16, 12, 16, 12); return button;
    }
    private Button DashboardCounter(string title, string provider, int? count, string glyph, string route)
    {
        var text = Stack(2); text.Children.Add(DashboardLabel(title, 12, true)); text.Children.Add(DashboardMuted(provider, 10));
        var number = DashboardLabel(count?.ToString() ?? "—", 19, true); number.VerticalAlignment = VerticalAlignment.Center;
        var button = DashboardRow(DashboardRowContent(new FontIcon { Glyph = glyph, FontSize = 16, Opacity = .6 }, text, number), () => navigate(route), title + " " + (count?.ToString() ?? "尚未加载"));
        button.Style = DashboardStyle("DashboardCountButtonStyle"); button.Padding = new Thickness(16, 12, 16, 12); return button;
    }
    private Button DashboardCollection(string title, int kind, JsonElement[]? items, double? total = null)
    {
        var count = total is { } known ? known.ToString("0") : items?.Length.ToString();
        var grid = new Grid { MinHeight = 110 };
        var labels = Stack(2); labels.Children.Add(Text(count ?? "—", 34, true)); labels.Children.Add(Text(title, 12, true)); labels.Children.Add(DashboardMuted("Bangumi", 10)); grid.Children.Add(labels);
        var arrow = new FontIcon { Glyph = "\uE76C", FontSize = 10, Opacity = .45, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 0, 0) }; grid.Children.Add(arrow);
        var collage = new Grid { Width = 92, Height = 70, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, IsHitTestVisible = false };
        var covers = (items ?? []).Select(x => Cover(Json.Subject(x))).Where(x => x.Length > 0).Take(3).ToArray();
        for (var i = 0; i < covers.Length; i++)
        {
            var poster = DashboardArtwork(covers[i], 42, 62, 4); poster.HorizontalAlignment = HorizontalAlignment.Left;
            poster.Margin = new Thickness(i * 22 + 2, 0, 0, 0); poster.RenderTransformOrigin = new(.5, .5); poster.RenderTransform = new RotateTransform { Angle = (i - 1) * 9 }; collage.Children.Add(poster);
        }
        grid.Children.Add(collage); var button = DashboardRow(grid, () => navigate("viewing:bangumi:" + kind), title + " " + (count ?? "尚未加载"));
        button.Style = DashboardStyle("DashboardCountButtonStyle"); return button;
    }
    private UIElement DashboardBroadcast(JsonElement subject, DateTimeOffset? time)
    {
        var stack = Stack(5); stack.Children.Add(DashboardArtwork(Cover(subject), 92, 134, 7));
        var title = Text(Json.Title(subject), 12, true); title.MaxLines = 2; title.TextTrimming = TextTrimming.CharacterEllipsis; stack.Children.Add(title);
        stack.Children.Add(DashboardMuted(time?.LocalDateTime.ToString("HH:mm 更新") ?? "时间待定", 10));
        var button = DashboardRow(stack, () => navigate("viewing:subject:" + Json.Number(subject, "id")), Json.Title(subject) + " 更新安排");
        button.Width = 92; button.Padding = new Thickness(0); return button;
    }
    private UIElement DashboardMediaRow(Page page, DemoMedia media)
    {
        var text = Stack(5); text.Children.Add(DashboardLabel(media.SeriesTitle ?? media.Title, 13, true));
        var subtitle = string.Join(" · ", new[] { media.SeriesTitle is { Length: > 0 } ? media.Title : null, media.EpisodeLabel }.Where(x => !string.IsNullOrWhiteSpace(x)));
        if (subtitle.Length > 0) text.Children.Add(DashboardLabel(subtitle, 11));
        var progress = DashboardProgress(media.Progress); text.Children.Add(progress);
        var picture = DashboardArtwork(App.Core?.Server is not null && media.Kind is "episode" or "season" ? "" : media.Artwork, 42, 60);
        picture.Loaded += async (_, _) =>
        {
            try { if (App.Core?.Server is { } server) { var poster = await server.Poster(media, page.Token); if (!page.Token.IsCancellationRequested && poster.Length > 0) picture.Child = Image(poster); } }
            catch (Exception ex) when (ex is OperationCanceledException or InvalidOperationException) { }
        };
        return DashboardRow(DashboardRowContent(picture, text), () => open(media), "继续观看：" + (media.SeriesTitle ?? media.Title));
    }
    private UIElement DashboardHistoryRow(Page page, ViewingRecord record)
    {
        var text = Stack(3); text.Children.Add(DashboardLabel(record.Media.SeriesTitle ?? record.Media.Title, 12, true));
        if (record.Media.SeriesTitle is { Length: > 0 }) text.Children.Add(DashboardLabel(record.Media.Title + " · " + record.Media.EpisodeLabel, 10));
        text.Children.Add(DashboardMuted(record.WatchedAt.LocalDateTime.ToString("M/d HH:mm"), 10));
        var end = Row(8); end.VerticalAlignment = VerticalAlignment.Center; end.Children.Add(DashboardMuted($"{(record.ActualSeconds.HasValue ? "实播" : "估算")} {record.Seconds / 3600:0.#} 小时", 10));
        end.Children.Add(new FontIcon { Glyph = "\uE76C", FontSize = 9, Opacity = .4 });
        var picture = DashboardArtwork(record.Media.Artwork, 36, 52);
        picture.Loaded += async (_, _) =>
        {
            try
            {
                var artwork = record.Source == "local" ? App.Core?.LocalMedia.FirstOrDefault(x => x.Id == record.Media.Id)?.Artwork ?? "" : record.Media.Artwork;
                if (record.Source != "local" && App.Core?.Server is { } server && record.Source == ViewingHistory.Source(server))
                {
                    var media = record.Media.Kind is "episode" or "season" ? record.Media : server.Project(await server.Request("browse.detail", new { itemId = record.Media.Id }, page.Token));
                    artwork = await server.Poster(media, page.Token);
                }
                if (!page.Token.IsCancellationRequested && artwork.Length > 0) picture.Child = Image(DemoMedia.AssetPath(artwork));
            }
            catch (Exception ex) when (ex is OperationCanceledException or InvalidOperationException) { }
        };
        var button = DashboardRow(DashboardRowContent(picture, text, end), () =>
        {
            if (record.Source == "local") { if (App.Core?.LocalMedia.FirstOrDefault(x => x.Id == record.Media.Id) is { } local) open(local); }
            else open(record.Media);
        }, "观看记录：" + (record.Media.SeriesTitle ?? record.Media.Title));
        button.IsEnabled = record.Source != "local" || App.Core?.LocalMedia.Any(x => x.Id == record.Media.Id) == true; return button;
    }
    private UIElement DashboardSubscription(JsonElement item)
    {
        var text = Stack(4); text.Children.Add(DashboardLabel(Json.Title(item), 12, true));
        text.Children.Add(DashboardLabel($"第 {Json.Number(item, "season", 1):0} 季 · {MoviePilotPolicies.State(item)}", 11));
        var total = Json.Number(item, "total_episode"); var missing = Json.Number(item, "lack_episode");
        text.Children.Add(DashboardMuted(total > 0 && Json.Get(item, "lack_episode").ValueKind == JsonValueKind.Number
            ? $"已下 {Math.Max(0, total - missing):0}/{total:0} 集（缺 {Math.Max(0, missing):0}）" : "下载集数待确认", 11));
        return DashboardRow(DashboardRowContent(DashboardArtwork(Cover(item), 42, 62), text), () => navigate(ResourceRoute(item)), "查找订阅资源：" + Json.Title(item));
    }
    private UIElement DashboardDownload(JsonElement item)
    {
        var text = Stack(8); var percent = Math.Clamp(Json.Number(item, "progress"), 0, 100);
        text.Children.Add(DashboardHeading(Json.DownloadTitle(item), DashboardMuted($"{percent:0.#}%", 11)));
        text.Children.Add(DashboardProgress(percent, DashboardOrange));
        text.Children.Add(DashboardMuted(string.Join(" · ", new[] { Json.First(item, "state", "status"), Json.Text(item, "dlspeed"), Json.Text(item, "left_time") }.Where(x => x.Length > 0)), 10));
        var button = DashboardRow(text, () => navigate("viewing:downloads"), "管理下载：" + Json.DownloadTitle(item)); button.Padding = new Thickness(2, 8, 2, 8); return button;
    }
}

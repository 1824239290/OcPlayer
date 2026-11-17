using System.Text.Json;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Services;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed partial class IntegrationPages
{
    private static readonly string[] MpFilterLabels = ["站点", "季", "促销", "编码", "质量", "分辨率", "制作组"];
    private static readonly string[] MpFilterGlyphs = ["\uE774", "\uE81E", "\uE719", "\uE714", "\uE8B7", "\uE7F4", "\uE716"];
    private static void MpName(DependencyObject control, string name)
    { AutomationProperties.SetName(control, name); if (control is FrameworkElement element) ToolTipService.SetToolTip(element, name); }
    private static StackPanel MpButtonContent(string glyph, string label)
    {
        var row = Row(6); row.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(new FontIcon { Glyph = glyph, FontSize = 13 });
        if (label.Length > 0) row.Children.Add(DashboardLabel(label, 12, true));
        return row;
    }
    private static Button MpCompact(Button button, string glyph, string label, string? name = null)
    {
        button.Content = MpButtonContent(glyph, label); button.Padding = new Thickness(12, 5, 12, 5);
        button.MinHeight = 0; button.Height = 30; button.FontSize = 12; button.CornerRadius = new CornerRadius(6);
        MpName(button, name ?? label); return button;
    }
    private static DropDownButton MpMenu(string glyph, string label, string name, MenuFlyout menu)
    {
        var button = new DropDownButton { Content = MpButtonContent(glyph, label), Flyout = menu,
            Height = 30, MinHeight = 0, FontSize = 12, Padding = new Thickness(10, 4, 10, 4), CornerRadius = new CornerRadius(6) };
        MpName(button, name); return button;
    }
    private static void MpMenuAction(MenuFlyout menu, Page page, string label, string glyph, Func<Task> action)
    {
        var item = new MenuFlyoutItem { Text = label, Icon = new FontIcon { Glyph = glyph } };
        item.Click += async (_, _) => await page.Run(action); menu.Items.Add(item);
    }
    private static Border MpBadge(string text, string tone = "neutral", bool onPoster = false)
    {
        var label = DashboardLabel(text, 10, true);
        var color = tone switch { "green" => ColorHelper.FromArgb(255, 32, 180, 92), "orange" => ColorHelper.FromArgb(255, 236, 157, 44), "blue" => ColorHelper.FromArgb(255, 62, 143, 224), _ => Colors.Gray };
        var background = tone == "neutral" ? DashboardNeutral(40) : new SolidColorBrush(ColorHelper.FromArgb(36, color.R, color.G, color.B));
        if (onPoster) { label.Foreground = new SolidColorBrush(Colors.White); background = new SolidColorBrush(tone == "neutral" ? ColorHelper.FromArgb(180, 0, 0, 0) : color); }
        else if (tone != "neutral") label.Foreground = new SolidColorBrush(color);
        return new Border { Child = label, Background = background, CornerRadius = new CornerRadius(onPoster ? 5 : 8), Padding = new Thickness(6, 2, 6, 2), VerticalAlignment = VerticalAlignment.Center };
    }
    // A wrapping grid uses the measured viewport, so native controls stay contained at narrow widths.
    private static Panel MpWrap(IEnumerable<FrameworkElement> items, double horizontal = 6, double vertical = 6)
    {
        var panel = new MpWrapPanel(horizontal, vertical); foreach (var item in items) panel.Children.Add(item); return panel;
    }
    private sealed class MpWrapPanel(double horizontal, double vertical) : Panel
    {
        protected override global::Windows.Foundation.Size MeasureOverride(global::Windows.Foundation.Size availableSize)
        {
            double x = 0, y = 0, rowHeight = 0, width = 0;
            foreach (var item in Children)
            {
                item.Measure(availableSize); var size = item.DesiredSize;
                if (x > 0 && x + size.Width > availableSize.Width) { x = 0; y += rowHeight + vertical; rowHeight = 0; }
                width = Math.Max(width, x + size.Width); x += size.Width + horizontal; rowHeight = Math.Max(rowHeight, size.Height);
            }
            return new(width, y + rowHeight);
        }
        protected override global::Windows.Foundation.Size ArrangeOverride(global::Windows.Foundation.Size finalSize)
        {
            double x = 0, y = 0, rowHeight = 0;
            foreach (var item in Children)
            {
                var size = item.DesiredSize;
                if (x > 0 && x + size.Width > finalSize.Width) { x = 0; y += rowHeight + vertical; rowHeight = 0; }
                item.Arrange(new global::Windows.Foundation.Rect(x, y, Math.Min(size.Width, finalSize.Width), size.Height)); x += size.Width + horizontal; rowHeight = Math.Max(rowHeight, size.Height);
            }
            return finalSize;
        }
    }
    private static Grid MpSectionHeading(string label, string count = "")
    {
        var row = Row(8); row.Children.Add(DashboardLabel(label, 16, true));
        if (count.Length > 0) row.Children.Add(MpBadge(count));
        return new Grid { Children = { row } };
    }
    private static Border MpEmpty(string text, string glyph = "\uE896")
    {
        var content = Stack(12); content.HorizontalAlignment = HorizontalAlignment.Center; content.VerticalAlignment = VerticalAlignment.Center;
        content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 36, Opacity = .6, HorizontalAlignment = HorizontalAlignment.Center });
        var label = DashboardMuted(text, 12); label.TextAlignment = TextAlignment.Center; label.MaxWidth = 600; content.Children.Add(label);
        var panel = DashboardCard(content, 24); panel.MinHeight = 146; return panel;
    }
    private StackPanel MpMediaDetails(JsonElement media, bool resource)
    {
        var details = Stack(resource ? 7 : 6); var title = DashboardLabel(Json.Title(media), resource ? 20 : 14, true); details.Children.Add(title);
        var badges = new List<FrameworkElement>(); var type = Json.First(media, "type", "media_type");
        if (type.Length > 0) badges.Add(MpBadge(MoviePilotPolicies.IsMovie(media) ? "电影" : "电视剧"));
        var year = resource ? Json.First(media, "year", "title_year") : Json.First(media, "title_year", "year"); if (year.Length > 0) badges.Add(MpBadge(year));
        var rating = Json.Number(media, "vote_average", Json.Number(media, "rating")); if (rating > 0) badges.Add(MpBadge($"★ {rating:0.0}", "orange"));
        var source = Json.First(media, "media_source", "source"); if (!resource && source.Length > 0) badges.Add(MpBadge(source.ToUpperInvariant()));
        details.Children.Add(MpWrap(badges));
        var summary = Json.First(media, "overview", "description", "summary");
        if (summary.Length > 0) { var overview = DashboardMuted(summary, 11); overview.MaxLines = resource ? 3 : 2; overview.TextTrimming = TextTrimming.CharacterEllipsis; details.Children.Add(overview); }
        if (resource && Json.First(media, "tmdbid", "tmdb_id").Length == 0)
        {
            var warning = DashboardMuted("⚠ 没有 TMDB 编号，下载完成后 MoviePilot 的自动刮削可能缺字段。\n" + (source.Length > 0 ? "来源 " + source.ToUpperInvariant() + " · " : "") + "下载将保留实际来源编号，建议选择一条 TMDB 来源的条目。", 11);
            warning.Foreground = DashboardOrange; details.Children.Add(warning);
        }
        return details;
    }
    private Border MpMediaCard(JsonElement media, bool resource, FrameworkElement? actions = null)
    {
        var grid = new Grid { ColumnSpacing = 16 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var poster = DashboardArtwork(Cover(media), resource ? 84 : 76, resource ? 126 : 114, 10); grid.Children.Add(poster);
        var details = MpMediaDetails(media, resource); Grid.SetColumn(details, 1); grid.Children.Add(details);
        if (actions is not null)
        {
            actions.VerticalAlignment = VerticalAlignment.Top; Grid.SetColumn(actions, 2); grid.Children.Add(actions);
            void Arrange()
            {
                var compact = grid.ActualWidth > 0 && grid.ActualWidth < 620;
                grid.RowSpacing = compact ? 10 : 0;
                Grid.SetColumnSpan(details, compact ? 2 : 1); Grid.SetRow(actions, compact ? 1 : 0); Grid.SetColumn(actions, compact ? 1 : 2); Grid.SetColumnSpan(actions, compact ? 2 : 1);
            }
            grid.SizeChanged += (_, _) => Arrange();
        }
        else Grid.SetColumnSpan(details, 2);
        var card = DashboardCard(grid, resource ? 16 : 14); card.CornerRadius = new CornerRadius(16); card.Tag = resource ? "MoviePilot.MediaHeader" : "MoviePilot.MediaResult"; return card;
    }
    private Button MpSubscriptionCard(Page page, JsonElement item, Func<Task> reload)
    {
        var poster = new Grid { Height = 300, Tag = "MoviePilot.PosterFrame" }; poster.Children.Add(DashboardArtwork(Cover(item), 1, 1, 8));
        var artwork = (Border)poster.Children[0]; artwork.ClearValue(FrameworkElement.WidthProperty); artwork.ClearValue(FrameworkElement.HeightProperty); artwork.VerticalAlignment = VerticalAlignment.Stretch;
        poster.Children.Add(new Border { Background = new LinearGradientBrush { StartPoint = new(0, 1), EndPoint = new(0, .35), GradientStops = { new GradientStop { Color = ColorHelper.FromArgb(160, 0, 0, 0), Offset = 0 }, new GradientStop { Color = Colors.Transparent, Offset = 1 } } } });
        var season = MpBadge(MoviePilotPolicies.IsMovie(item) ? "电影" : $"第 {Json.Number(item, "season", 1):0} 季", onPoster: true); season.Margin = new Thickness(8); season.HorizontalAlignment = HorizontalAlignment.Left; season.VerticalAlignment = VerticalAlignment.Bottom; poster.Children.Add(season);
        var state = MoviePilotPolicies.State(item); var badge = MpBadge(state, state == "追更中" ? "green" : state == "已完成" ? "blue" : "neutral", true); badge.Margin = new Thickness(8); badge.HorizontalAlignment = HorizontalAlignment.Right; badge.VerticalAlignment = VerticalAlignment.Top; poster.Children.Add(badge);
        var rating = Json.Number(item, "vote_average", Json.Number(item, "rating"));
        if (rating > 0) { var score = MpBadge($"★ {rating:0.0}", onPoster: true); score.Margin = new Thickness(8); score.HorizontalAlignment = HorizontalAlignment.Right; score.VerticalAlignment = VerticalAlignment.Bottom; poster.Children.Add(score); }
        var stack = Stack(0); stack.Children.Add(new Border { Child = poster, CornerRadius = new CornerRadius(8) });
        var total = Json.Number(item, "total_episode"); var lack = Json.Number(item, "lack_episode"); var downloaded = Math.Clamp(total - lack, 0, Math.Max(0, total));
        var hasProgress = !MoviePilotPolicies.IsMovie(item) && total > 0 && Json.Get(item, "lack_episode").ValueKind is JsonValueKind.Number or JsonValueKind.String;
        var track = new Grid { Height = 3, Margin = new Thickness(0, 7, 0, 4), Background = hasProgress ? DashboardNeutral(35) : new SolidColorBrush(Colors.Transparent) };
        var fill = new Border { Background = Resource("SystemControlForegroundAccentBrush"), HorizontalAlignment = HorizontalAlignment.Left };
        track.Children.Add(fill); track.SizeChanged += (_, _) => fill.Width = hasProgress ? track.ActualWidth * downloaded / total : 0; stack.Children.Add(track);
        var year = DashboardMuted(Json.Text(item, "year"), 10); var title = DashboardHeading(Json.Title(item), year); stack.Children.Add(title);
        stack.Children.Add(DashboardMuted(hasProgress ? $"已下 {downloaded:0}/{total:0} 集（缺 {lack:0}）" : MoviePilotPolicies.IsMovie(item) ? "电影" : "剧集", 11));
        var button = new Button { Content = stack, Tag = item, Padding = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Top, Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(8) };
        MpName(button, "MoviePilot 订阅 " + Json.Title(item)); button.Click += (_, _) => navigate(ResourceRoute(item));
        button.SizeChanged += (_, _) => poster.Height = Math.Max(1, button.ActualWidth) * 1.5;
        var menu = new MenuFlyout(); MpMenuAction(menu, page, "编辑订阅设置", "\uE70F", () => EditSubscription(page, item, true));
        MpMenuAction(menu, page, "搜索站点资源", "\uE721", () => { navigate(ResourceRoute(item)); return Task.CompletedTask; });
        MpMenuAction(menu, page, "在 MoviePilot 刷新", "\uE72C", async () => { await Service.Mp("subscription.refresh", null, page.Token); await reload(); });
        menu.Items.Add(new MenuFlyoutSeparator()); MpMenuAction(menu, page, "取消订阅", "\uE74D", async () => { if (await Confirm(page, "取消订阅", Json.Title(item))) { await Service.Mp("subscription.delete", new { id = (long)Json.Number(item, "id") }, page.Token); await reload(); } });
        button.ContextFlyout = menu; return button;
    }
    private static Grid MpSubscriptionGrid(IEnumerable<FrameworkElement> cards)
    {
        var grid = new Grid { ColumnSpacing = 20, RowSpacing = 28 }; foreach (var card in cards) grid.Children.Add(card);
        var previous = 0;
        void Arrange()
        {
            var columns = Math.Max(1, (int)((grid.ActualWidth + 20) / 200)); if (columns == previous) return; previous = columns;
            grid.ColumnDefinitions.Clear(); grid.RowDefinitions.Clear();
            for (var i = 0; i < columns; i++) grid.ColumnDefinitions.Add(new ColumnDefinition { MaxWidth = 240 });
            for (var i = 0; i < grid.Children.Count; i++) { if (i % columns == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); var card = (FrameworkElement)grid.Children[i]; Grid.SetColumn(card, i % columns); Grid.SetRow(card, i / columns); }
        }
        grid.SizeChanged += (_, _) => Arrange(); Arrange(); return grid;
    }
}

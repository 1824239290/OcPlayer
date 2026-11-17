using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.Services;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed partial class IntegrationPages
{
    private static string[] BgmLabels(int kind, bool pending = false) => kind switch
    {
        4 => ["想玩", "玩过", "在玩", "搁置", "抛弃"], 1 => ["想读", "读过", "在读", "搁置", "抛弃"],
        3 => ["想听", "听过", "在听", "搁置", "抛弃"], _ => [pending ? "待看" : "想看", "看过", "在看", "搁置", "抛弃"]
    };
    private static string BgmPlatform(JsonElement subject)
    {
        var platform = Json.Get(subject, "platform");
        return platform.ValueKind == JsonValueKind.Object ? Json.First(platform, "alias", "typeCN", "type_cn", "type", "name") : Json.First(subject, "platform", "platformText");
    }
    private static string BgmYear(JsonElement subject) => AirDate(subject).Split('-')[0];
    private static void BgmName(DependencyObject control, string name) { AutomationProperties.SetName(control, name); if (control is FrameworkElement element) ToolTipService.SetToolTip(element, name); }
    private static Button BgmIcon(Page page, string glyph, string name, Func<Task> action)
    {
        var button = page.Action("", action); button.Content = new FontIcon { Glyph = glyph, FontSize = 16 };
        button.Padding = new Thickness(0); button.Width = button.Height = 32; button.MinWidth = button.MinHeight = 0; button.CornerRadius = new CornerRadius(4);
        BgmName(button, name); return button;
    }
    private static DropDownButton BgmMenu(string glyph, string name, MenuFlyout menu)
    {
        menu.Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft;
        var button = new DropDownButton { Content = new FontIcon { Glyph = glyph, FontSize = 16 }, Height = 32, Padding = new Thickness(8, 4, 8, 4), CornerRadius = new CornerRadius(4), Flyout = menu };
        BgmName(button, name); return button;
    }
    private static Border BgmBadge(string value)
    { return new Border { Child = DashboardLabel(value, 10), Background = DashboardNeutral(45), CornerRadius = new CornerRadius(5), Padding = new Thickness(6, 3, 6, 3) }; }
    private DropDownButton BgmCollectionMenu(Page page, long id, int kind, int current, Func<int, Task>? changed = null)
    {
        var labels = BgmLabels(kind); var menu = new MenuFlyout();
        var button = new DropDownButton { Height = 30, Padding = new Thickness(6, 2, 6, 2), Background = DashboardNeutral(0), BorderThickness = new Thickness(0), Content = current is >= 1 and <= 5 ? labels[current - 1] : "加入收藏", Flyout = menu };
        BgmName(button, "Bangumi 收藏状态 " + id); button.Tag = current;
        for (var i = 0; i < 5; i++)
        {
            var state = i + 1; var item = new ToggleMenuFlyoutItem { Text = labels[i], IsChecked = current == state };
            item.Click += async (_, _) =>
            {
                button.IsEnabled = false;
                try { await page.Run(async () => { await Service.UpdateSubjectCollection(id, page.Token, type: state); button.Content = labels[state - 1]; button.Tag = state; foreach (var option in menu.Items.OfType<ToggleMenuFlyoutItem>()) option.IsChecked = option == item; if (changed is not null) await changed(state); }); }
                finally { button.IsEnabled = true; }
            };
            menu.Items.Add(item);
        }
        menu.Placement = FlyoutPlacementMode.BottomEdgeAlignedRight; return button;
    }
    private DropDownButton BgmRatingMenu(Page page, long id, int score, Action? changed = null)
    {
        var labels = new[] { "未评分", "1 不忍直视", "2 很差", "3 差", "4 较差", "5 不过不失", "6 还行", "7 推荐", "8 力荐", "9 神作", "10 超神作" };
        var menu = new MenuFlyout(); var button = new DropDownButton { Content = score > 0 ? "☆ " + score + " 分" : "☆ 评分", Height = 30, Padding = new Thickness(6, 2, 6, 2), Background = DashboardNeutral(0), BorderThickness = new Thickness(0), Flyout = menu, Tag = score };
        BgmName(button, "Bangumi 我的评分 " + id);
        for (var i = 0; i <= 10; i++)
        {
            var value = i; var item = new ToggleMenuFlyoutItem { Text = labels[i], IsChecked = score == value };
            item.Click += async (_, _) => await page.Run(async () => { await Service.UpdateSubjectCollection(id, page.Token, rate: value); button.Content = value > 0 ? "☆ " + value + " 分" : "☆ 评分"; button.Tag = value; foreach (var option in menu.Items.OfType<ToggleMenuFlyoutItem>()) option.IsChecked = option == item; changed?.Invoke(); });
            menu.Items.Add(item);
        }
        return button;
    }
    private Button BgmChapter(Page page, long id, JsonElement episode, Func<Task> refresh)
    {
        var aired = ViewingIntegrations.EpisodeAired(episode); var status = ViewingIntegrations.EpisodeStatus(episode); var number = Json.Number(episode, "sort").ToString("00.##");
        var state = aired ? new[] { "未看", "想看", "看过", "抛弃" }[Math.Clamp(status, 0, 3)] : "未播";
        var text = Stack(2); var label = DashboardLabel(number, 12, true); label.HorizontalAlignment = HorizontalAlignment.Center;
        var sub = DashboardLabel(state, 10); sub.HorizontalAlignment = HorizontalAlignment.Center; sub.Opacity = .65; text.Children.Add(label); text.Children.Add(sub);
        var button = new Button { Content = text, Tag = episode, Width = 48, Height = 48, CornerRadius = new CornerRadius(8), HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0), IsEnabled = aired, Opacity = aired ? 1 : .65,
            Style = DashboardStyle(status == 2 && aired ? "BangumiInlineWatchedChapterButtonStyle" : "BangumiInlineChapterButtonStyle") };
        var group = (int)Json.Number(episode, "type") switch { 0 => "本篇", 1 => "SP", 2 => "OP", 3 => "ED", _ => "其他" };
        BgmName(button, $"Bangumi {id} {group} {number} · {state}");
        ToolTipService.SetToolTip(button, $"{group} {number} · {Json.Title(episode)}\n{Json.First(episode, "airdate", "airDate")}\n单击切换看过/未看；右键修改状态");
        button.ContextFlyout = EpisodeCollectionMenu(page, id, episode, refresh);
        button.Click += async (_, _) =>
        {
            button.IsEnabled = false;
            try { await page.Run(async () => { await Service.UpdateEpisodeCollection(id, (long)Json.Number(episode, "id"), status == 2 ? 0 : 2, false, page.Token); await refresh(); }); }
            finally { if (button.IsLoaded) button.IsEnabled = aired; }
        };
        return button;
    }
    private void BgmChapters(Page page, StackPanel host, long id, JsonElement[] episodes, Func<Task> refresh)
    {
        host.Children.Clear();
        foreach (var group in new[] { (Title: "本篇", Rows: episodes.Where(x => Json.Number(x, "type") == 0)), (Title: "SP", Rows: episodes.Where(x => Json.Number(x, "type") == 1)), (Title: "其他章节", Rows: episodes.Where(x => Json.Number(x, "type") is not 0 and not 1)) })
        {
            var rows = group.Rows.OrderBy(x => Json.Number(x, "type")).ThenBy(x => Json.Number(x, "sort")).ToArray(); if (rows.Length == 0) continue;
            if (group.Title != "本篇") host.Children.Add(DashboardMuted(group.Title, 11));
            var buttons = rows.Select(episode => (FrameworkElement)BgmChapter(page, id, episode, refresh)).ToArray();
            var grid = BgmResponsiveGrid(buttons, 48, 6, Math.Max(1, rows.Length)); grid.MaxWidth = rows.Length * 54 - 6; grid.HorizontalAlignment = HorizontalAlignment.Left;
            void Resize() => grid.Width = Math.Min(grid.MaxWidth, Math.Max(48, host.ActualWidth));
            host.SizeChanged += (_, _) => Resize(); host.Loaded += (_, _) => Resize();
            host.Children.Add(grid);
        }
        if (episodes.Length == 0) host.Children.Add(DashboardMuted("暂无章节", 12));
    }
    private UIElement BgmPosterCard(JsonElement raw)
    {
        var subject = Json.Subject(raw); var content = Stack(10); var cover = DashboardArtwork(Cover(subject), 1, 1, 8);
        cover.ClearValue(FrameworkElement.WidthProperty); cover.Height = 280; cover.HorizontalAlignment = HorizontalAlignment.Stretch; content.Children.Add(cover);
        content.Children.Add(DashboardLabel(Json.Title(subject), 13, true));
        var original = DashboardMuted(Json.Text(subject, "name"), 11); original.MaxLines = 1; original.TextTrimming = TextTrimming.CharacterEllipsis; content.Children.Add(original);
        var rating = Json.Number(Json.Get(subject, "rating"), "score", Json.Number(subject, "score")); var ratingLabel = DashboardMuted(rating > 0 ? "★ " + rating.ToString("0.0") : "暂无评分", 11);
        var meta = string.Join(" · ", new[] { BgmYear(subject), TotalEpisodes(subject) > 0 ? $"{TotalEpisodes(subject):0} 话" : null }.Where(x => !string.IsNullOrWhiteSpace(x)));
        content.Children.Add(DashboardHeading(meta, ratingLabel));
        var button = new Button { Style = DashboardStyle("DashboardCountButtonStyle"), Padding = new Thickness(10), Content = content, VerticalAlignment = VerticalAlignment.Top, Tag = raw };
        BgmName(button, "Bangumi 条目 " + SubjectId(raw) + " " + Json.Title(subject)); button.Click += (_, _) => navigate("viewing:subject:" + SubjectId(raw));
        button.SizeChanged += (_, _) => cover.Height = Math.Max(1, button.ActualWidth - 22) * 1.5;
        return button;
    }
    private static Grid BgmResponsiveGrid(IEnumerable<FrameworkElement> items, double minimum, double spacing = 18, int maximum = 5, bool stretchRows = false)
    {
        var grid = new Grid { ColumnSpacing = spacing, RowSpacing = spacing }; foreach (var item in items) { if (stretchRows) item.VerticalAlignment = VerticalAlignment.Stretch; grid.Children.Add(item); }
        var previousColumns = 0;
        void Arrange()
        {
            var columns = Math.Clamp((int)((grid.ActualWidth + spacing) / (minimum + spacing)), 1, maximum); if (columns == previousColumns) return; previousColumns = columns;
            grid.ColumnDefinitions.Clear(); grid.RowDefinitions.Clear(); for (var i = 0; i < columns; i++) grid.ColumnDefinitions.Add(new ColumnDefinition());
            for (var i = 0; i < grid.Children.Count; i++) { if (i % columns == 0) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); var item = (FrameworkElement)grid.Children[i]; Grid.SetColumn(item, i % columns); Grid.SetRow(item, i / columns); }
        }
        grid.SizeChanged += (_, _) => Arrange(); Arrange(); return grid;
    }
    private static JsonElement[] BgmProgressWindow(JsonElement[] sorted, int size = 50)
    {
        if (sorted.Length == 0) return [];
        var next = sorted.FirstOrDefault(x => ViewingIntegrations.EpisodeStatus(x) == 0);
        if (next.ValueKind != JsonValueKind.Object) return sorted.TakeLast(size).ToArray();
        var number = Json.Number(next, "sort"); var before = sorted.Where(x => Json.Number(x, "sort") < number).TakeLast(size - 1).ToArray();
        var after = sorted.Where(x => Json.Number(x, "sort") > number).Take(size - 1).ToArray(); var halfBefore = (size - 1) / 2; var halfAfter = size - halfBefore - 1;
        var beforeCount = before.Length < halfBefore ? before.Length : after.Length < halfAfter ? Math.Min(before.Length, size - after.Length - 1) : halfBefore;
        var afterCount = before.Length < halfBefore ? Math.Min(after.Length, size - beforeCount - 1) : after.Length < halfAfter ? after.Length : halfAfter;
        return before.TakeLast(beforeCount).Append(next).Concat(after.Take(afterCount)).ToArray();
    }
}

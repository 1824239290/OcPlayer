using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed partial class IntegrationPages
{
    private static readonly string[] CollectionLabels = ["想看", "看过", "在看", "搁置", "抛弃"];
    private static readonly (string Label, int Id)[] SubjectTypes = [("全部", 0), ("动画", 2), ("书籍", 1), ("游戏", 4), ("音乐", 3), ("三次元", 6)];
    private static string SubjectType(JsonElement subject) => SubjectTypes.FirstOrDefault(x => x.Id == Json.Number(subject, "type")).Label ?? "条目";
    private static JsonElement Interest(JsonElement raw)
    {
        var subject = Json.Subject(raw); var interest = Json.Get(subject, "interest");
        return interest.ValueKind == JsonValueKind.Object ? interest : raw;
    }
    private static string AirDate(JsonElement subject) => Json.First(subject, "date", "air_date") is { Length: > 0 } date ? date : Json.Text(Json.Get(subject, "airtime"), "date");
    private static long SubjectId(JsonElement raw) => (long)Json.Number(Json.Subject(raw), "id", Json.Number(raw, "subject_id"));
    private static double TotalEpisodes(JsonElement subject) => Json.Number(subject, "eps", Json.Number(subject, "total_episodes", Json.Number(subject, "totalEpisodes")));
    private UIElement BangumiCard(JsonElement raw, params UIElement[] actions)
    {
        var subject = Json.Subject(raw); var interest = Interest(raw); var rating = Json.Get(subject, "rating"); var details = Stack(6);
        var hasInterest = Json.Get(subject, "interest").ValueKind == JsonValueKind.Object || Json.Get(raw, "subject").ValueKind == JsonValueKind.Object;
        if (!hasInterest && Service.Snapshot("collection:" + SubjectId(raw)) is { } saved) { interest = Interest(saved); hasInterest = true; }
        var original = Json.Text(subject, "name"); if (original.Length > 0 && original != Json.Title(subject)) details.Children.Add(Muted(original));
        var total = TotalEpisodes(subject); var seen = Json.Number(interest, "epStatus", Json.Number(interest, "ep_status"));
        var platform = Json.First(subject, "platform", "platformText"); if (platform.Length == 0) platform = Json.First(Json.Get(subject, "platform"), "typeCN", "type_cn", "type", "name", "alias");
        details.Children.Add(Muted($"{SubjectType(subject)} · {platform} · {AirDate(subject)} · {seen:0}/{total:0} 话\n全站 {Json.Number(rating, "score"):0.0} 分 · #{Json.Number(rating, "rank", Json.Number(subject, "rank")):0} · {Json.Number(rating, "total"):0} 人评分"));
        var type = (int)Json.Number(interest, "type");
        if (hasInterest)
            details.Children.Add(Muted((type is >= 1 and <= 5 ? CollectionLabels[type - 1] : "未收藏") + $" · 我的评分 {Json.Number(interest, "rate"):0}" + (Json.Text(interest, "comment") is { Length: > 0 } comment ? "\n" + comment : "")));
        var info = Json.Text(subject, "info"); if (info.Length > 0) details.Children.Add(Muted(info));
        details.Children.Add(Muted($"在看 {Json.Number(Json.Get(subject, "collection"), "doing", Json.Number(Json.Get(subject, "collection"), "3")):0} 人"));
        return Item(subject, new[] { details }.Concat(actions).ToArray());
    }
    private async Task<JsonElement[]> LoadEpisodes(long id, CancellationToken token)
    { var rows = await Service.Episodes(id, token); Service.SaveSnapshot("episodes:" + id, JsonSerializer.SerializeToElement(rows)); return rows; }
    private MenuFlyout EpisodeCollectionMenu(Page page, long subjectId, JsonElement episode, Func<Task> refresh)
    {
        var episodeId = (long)Json.Number(episode, "id"); var status = ViewingIntegrations.EpisodeStatus(episode);
        var menu = new MenuFlyout();
        foreach (var (label, state) in new[] { ("未看", 0), ("想看", 1), ("看过", 2), ("抛弃", 3) })
        {
            var action = new ToggleMenuFlyoutItem { Text = label, IsChecked = status == state };
            action.Click += async (_, _) => await page.Run(async () => { await Service.UpdateEpisodeCollection(subjectId, episodeId, state, false, page.Token); await refresh(); });
            menu.Items.Add(action);
        }
        if (Json.Number(episode, "type") == 0)
        {
            var action = new MenuFlyoutItem { Text = "看到此集" };
            action.Click += async (_, _) => await page.Run(async () => { await Service.UpdateEpisodeCollection(subjectId, episodeId, 2, true, page.Token); await refresh(); });
            menu.Items.Add(action);
        }
        return menu;
    }
    private void BuildInlineEpisodeGroups(Page page, StackPanel parent, long id, JsonElement[] rows)
    {
        async Task Refresh() { var fresh = await LoadEpisodes(id, page.Token); parent.Children.Clear(); BuildInlineEpisodeGroups(page, parent, id, fresh); }
        var main = rows.Where(x => Json.Number(x, "type") == 0).OrderBy(x => Json.Number(x, "sort")).ToArray();
        var other = rows.Where(x => Json.Number(x, "type") != 0).OrderBy(x => Json.Number(x, "type")).ThenBy(x => Json.Number(x, "sort")).ToArray();
        void AddRow(JsonElement[] episodes, string label)
        {
            var buttons = Row(8);
            foreach (var episode in episodes)
            {
                var aired = ViewingIntegrations.EpisodeAired(episode); var status = ViewingIntegrations.EpisodeStatus(episode);
                var number = Json.Number(episode, "sort").ToString("00.##");
                var state = aired ? new[] { "未看", "想看", "看过", "抛弃" }[Math.Clamp(status, 0, 3)] : "未播";
                var content = Stack(2);
                var numberText = Text(number, 13, true); numberText.TextWrapping = TextWrapping.NoWrap;
                numberText.HorizontalAlignment = HorizontalAlignment.Center; numberText.TextAlignment = TextAlignment.Center;
                var stateText = Text(state, 11); stateText.Opacity = .65; stateText.TextWrapping = TextWrapping.NoWrap;
                stateText.HorizontalAlignment = HorizontalAlignment.Center; stateText.TextAlignment = TextAlignment.Center;
                content.Children.Add(numberText); content.Children.Add(stateText);
                var button = new Button
                {
                    Content = content, Tag = episode, IsEnabled = aired, Opacity = aired ? 1 : .7,
                    Style = (Style)Application.Current.Resources[status == 2 && aired ? "BangumiInlineWatchedChapterButtonStyle" : "BangumiInlineChapterButtonStyle"]
                };
                var kind = (int)Json.Number(episode, "type") switch { 0 => "本篇", 1 => "SP", 2 => "OP", 3 => "ED", _ => "其他" };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, $"Bangumi {kind} {number} · {state}");
                ToolTipService.SetToolTip(button, $"{kind} {number} · {state}\n{Json.Title(episode)}\n{Json.First(episode, "airdate", "airDate")}");
                button.Flyout = EpisodeCollectionMenu(page, id, episode, Refresh);
                buttons.Children.Add(button);
            }
            parent.Children.Add(new OcPlayer.Windows.Controls.HorizontalMediaRail(buttons, label, 0));
        }
        if (main.Length > 0) AddRow(main, "Bangumi 本篇章节");
        if (other.Length > 0) { var label = Text("其他", 12); label.Opacity = .65; parent.Children.Add(label); AddRow(other, "Bangumi 其他章节"); }
        if (rows.Length == 0) parent.Children.Add(Muted("暂无章节"));
    }
    private UIElement Calendar()
    {
        var page = new Page(); if (Gate(page, true)) return Show(page); var now = DateTime.Today;
        var title = Text($"{now.Year} 年第 {(now.Month - 1) / 3 + 1} 季度 · 完整放送日历", 22, true); var search = new TextBox { Header = "搜索日历", PlaceholderText = "中文名、原名或简介" }; var days = new ComboBox { Header = "星期", SelectedIndex = 0 }; var list = Stack(12); JsonElement[] calendar = [];
        var today = ((int)now.DayOfWeek + 6) % 7 + 1;
        void Render()
        {
            list.Children.Clear(); var selected = days.SelectedIndex == 0 ? today : days.SelectedIndex == 8 ? 0 : days.SelectedIndex;
            foreach (var day in calendar.Where(x => selected == 0 || Json.Number(Json.Get(x, "weekday"), "id") == selected))
            {
                var items = Json.OptionalItems(Json.Get(day, "items")).Where(x => new[] { Json.Title(x), Json.Text(x, "name"), Json.Text(x, "summary") }.Any(text => text.Contains(search.Text, StringComparison.OrdinalIgnoreCase))).ToArray();
                if (items.Length == 0) continue; list.Children.Add(Text(Json.First(Json.Get(day, "weekday"), "cn", "ja", "en") + $" · {items.Length} 部", 18, true));
                foreach (var subject in items) list.Children.Add(BangumiCard(subject, Button("查看", () => navigate("viewing:subject:" + SubjectId(subject)))));
            }
            if (list.Children.Count == 0) list.Children.Add(Muted("暂无符合条件的放送作品"));
        }
        async Task Load()
        {
            calendar = Json.Items(await Service.Bgm("calendar", null, page.Token));
            int Count(int day) => calendar.Where(x => day == 0 || Json.Number(Json.Get(x, "weekday"), "id") == day).Sum(x => Json.OptionalItems(Json.Get(x, "items")).Length);
            var index = Math.Max(0, days.SelectedIndex); days.ItemsSource = new[] { $"今天 ({Count(today)})" }.Concat(Enumerable.Range(1, 7).Select(x => $"周{new[] { "一", "二", "三", "四", "五", "六", "日" }[x - 1]} ({Count(x)})")).Append($"全部 ({Count(0)})").ToArray(); days.SelectedIndex = index;
            title.Text = $"{now.Year} 年第 {(now.Month - 1) / 3 + 1} 季度 · 全周 {Count(0)} 部"; Render();
            try
            {
                var collections = await Task.WhenAll(Enumerable.Range(1, 5).Select(type => Service.Collections(type, page.Token))); var collected = collections.SelectMany(x => x).ToArray(); var ids = collected.Select(SubjectId).ToHashSet();
                foreach (var row in collected) Service.SaveSnapshot("collection:" + SubjectId(row), row);
                foreach (var subject in calendar.SelectMany(day => Json.OptionalItems(Json.Get(day, "items"))).Where(x => !ids.Contains(SubjectId(x)))) Service.ClearSnapshot("collection:" + SubjectId(subject)); Render();
            }
            catch (Exception ex) when (ex is not OperationCanceledException) { page.Status.Text = "日历已显示；个人收藏读取失败：" + ex.Message; }
        }
        days.SelectionChanged += (_, _) => Render(); search.TextChanged += (_, _) => Render(); page.Body.Children.Add(title); page.Body.Children.Add(days); page.Body.Children.Add(search);
        var toolbar = Row(8); toolbar.Children.Add(page.Action("刷新 / 重试", Load)); toolbar.Children.Add(Button("打开 Bangumi 放送日历", () => Browse(Service.Domains.Main + "calendar"))); page.Body.Children.Add(toolbar); page.Body.Children.Add(list); return Show(page, Load);
    }
    public UIElement MediaAssociation(DemoMedia media)
    {
        var page = new Page(); var host = Stack(12); page.Body.Spacing = 8; page.Body.Children.Add(host);
        if (Gate(page, true)) return Show(page);
        var source = ViewingHistory.Source(App.Core?.Server); var tried = false;
        async Task Pick()
        {
            var fields = Stack(10); var search = new TextBox { Header = "搜索关联条目", Text = media.SeriesTitle ?? media.Title }; var candidates = new ListView { SelectionMode = ListViewSelectionMode.Single, MaxHeight = 360 };
            fields.Children.Add(search); fields.Children.Add(candidates); var status = Muted(""); fields.Children.Add(status);
            async Task Search() { try { var items = Json.Items(await Service.Bgm("search", new { keyword = search.Text.Trim(), subjectType = 0, limit = 100, offset = 0 }, page.Token)); candidates.Items.Clear(); foreach (var item in items) candidates.Items.Add(new ListViewItem { Content = Json.Title(item) + " · " + AirDate(item) + " · " + SubjectType(item), Tag = item }); } catch (Exception ex) { status.Text = ex.Message; } }
            fields.Children.Add(Button("搜索", async () => await Search())); Submit(search, page, Search); await Search();
            var dialog = new ContentDialog { XamlRoot = page.Body.XamlRoot, Title = "手动关联 Bangumi", Content = fields, PrimaryButtonText = "确认关联", CloseButtonText = "取消" };
            using var registration = page.Token.Register(() => page.Body.DispatcherQueue.TryEnqueue(dialog.Hide));
            if (await dialog.ShowAsync() == ContentDialogResult.Primary && candidates.SelectedItem is ListViewItem { Tag: JsonElement chosen }) { Service.LinkBangumi(source, media, SubjectId(chosen), Json.Title(chosen)); await Load(); }
        }
        async Task Load()
        {
            host.Children.Clear(); var link = Service.ResolveBangumiLink(source, media);
            if (link is null && !tried) { tried = true; link = await Service.AutoLinkBangumi(source, media, page.Token); }
            var header = new Grid { ColumnSpacing = 8 };
            header.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
            header.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var title = Text("Bangumi", 18, true); title.VerticalAlignment = VerticalAlignment.Center; header.Children.Add(title);
            var actionStyle = (Style)Application.Current.Resources["BangumiInlineActionButtonStyle"];
            var linkedTitle = Button("", link is null ? async () => await page.Run(Pick) : () => navigate("viewing:subject:" + link.SubjectId));
            linkedTitle.Style = actionStyle; linkedTitle.Padding = new Thickness(6, 4, 6, 4); linkedTitle.CornerRadius = new(6); linkedTitle.HorizontalAlignment = HorizontalAlignment.Left;
            var linkedContent = new Grid { ColumnSpacing = 6 };
            linkedContent.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); linkedContent.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
            var linkText = Text(link?.Title ?? "关联条目", 13); linkText.TextWrapping = TextWrapping.NoWrap; linkText.TextTrimming = TextTrimming.CharacterEllipsis; linkText.VerticalAlignment = VerticalAlignment.Center;
            linkedContent.Children.Add(linkText); var chevron = new FontIcon { Glyph = "\uE76C", FontSize = 10, VerticalAlignment = VerticalAlignment.Center }; Grid.SetColumn(chevron, 1); linkedContent.Children.Add(chevron);
            linkedTitle.Content = linkedContent;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(linkedTitle, link is null ? "关联 Bangumi 条目" : "打开 Bangumi 条目：" + link.Title);
            ToolTipService.SetToolTip(linkedTitle, link?.Title ?? "手动关联 Bangumi 条目"); Grid.SetColumn(linkedTitle, 1); header.Children.Add(linkedTitle);
            var refresh = page.Action("", Load); refresh.Content = new FontIcon { Glyph = "\uE72C", FontSize = 16 }; refresh.Style = actionStyle;
            refresh.Width = refresh.Height = refresh.MinHeight = 32; refresh.Padding = new Thickness(0); refresh.CornerRadius = new(6); refresh.VerticalAlignment = VerticalAlignment.Center;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(refresh, "刷新 Bangumi 章节"); ToolTipService.SetToolTip(refresh, "刷新 Bangumi 章节"); Grid.SetColumn(refresh, 2); header.Children.Add(refresh);
            var more = new Button { Content = new FontIcon { Glyph = "\uE712", FontSize = 16 }, Style = actionStyle, Width = 32 };
            var options = new MenuFlyout();
            var auto = new MenuFlyoutItem { Text = "自动匹配", Icon = new FontIcon { Glyph = "\uE721" } };
            auto.Click += async (_, _) => await page.Run(async () => { if (await Service.AutoLinkBangumi(source, media, page.Token) is null) throw new InvalidOperationException("未找到唯一匹配，请手动关联。"); await Load(); }); options.Items.Add(auto);
            var relink = new MenuFlyoutItem { Text = link is null ? "手动关联" : "重新关联", Icon = new FontIcon { Glyph = "\uE71B" } };
            relink.Click += async (_, _) => await page.Run(Pick); options.Items.Add(relink); more.Flyout = options;
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(more, "Bangumi 关联选项"); ToolTipService.SetToolTip(more, "Bangumi 关联选项"); Grid.SetColumn(more, 3); header.Children.Add(more);
            host.Children.Add(header);
            if (link is null) { host.Children.Add(Muted("关联 Bangumi 条目后，可在这里同步章节观看状态。")); return; }
            var chapters = Stack(10); host.Children.Add(chapters);
            if (Service.Snapshot("episodes:" + link.SubjectId) is { } cached) BuildInlineEpisodeGroups(page, chapters, link.SubjectId, Json.Items(cached));
            var rows = await LoadEpisodes(link.SubjectId, page.Token); chapters.Children.Clear(); BuildInlineEpisodeGroups(page, chapters, link.SubjectId, rows);
        }
        page.Body.Loaded += async (_, _) => await page.Run(Load); page.Body.Unloaded += (_, _) => page.Lifetime.Cancel(); page.Body.Children.Add(page.Status); return page.Body;
    }
}

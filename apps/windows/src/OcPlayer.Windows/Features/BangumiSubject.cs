using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Services;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed partial class IntegrationPages
{
    private UIElement Subject(long id)
    {
        var page = new Page(); page.Body.MaxWidth = 1400; page.Body.Spacing = 22; HeaderTitle = "Bangumi 条目";
        if (Gate(page, true)) return Show(page);
        JsonElement subject = default; JsonElement? collection = Service.Snapshot("collection:" + id) is { } saved ? Interest(saved) : null;
        JsonElement[]? episodes = Service.Snapshot("episodes:" + id) is { } cachedEpisodes ? Json.Items(cachedEpisodes) : null;
        var hero = Stack(0); var chapters = Stack(8); var information = Stack(10); var synopsis = Stack(10); var footer = Stack(10);
        page.Body.Children.Add(hero); page.Body.Children.Add(DashboardSection("章节列表", DashboardMuted("单击标记看过；右键修改状态", 10), chapters));
        page.Body.Children.Add(information); page.Body.Children.Add(synopsis); page.Body.Children.Add(footer);
        void RenderHero()
        {
            if (subject.ValueKind != JsonValueKind.Object) return; hero.Children.Clear();
            HeaderTitle = Json.Title(subject); HeaderSubtitle = Json.Text(subject, "name"); HeaderChanged?.Invoke();
            var grid = new Grid { ColumnSpacing = 18 }; grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new ColumnDefinition());
            var artwork = DashboardArtwork(Cover(subject), 128, 194, 9); grid.Children.Add(artwork);
            var info = new Grid { MinHeight = 194 }; info.RowDefinitions.Add(new RowDefinition()); info.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var titles = Stack(6); titles.Children.Add(Text(Json.Title(subject), 19, true));
            if (Json.Text(subject, "name") is { Length: > 0 } original && original != Json.Title(subject)) titles.Children.Add(DashboardMuted(original, 12));
            var badges = Row(6); badges.Children.Add(BgmBadge(SubjectType(subject))); if (BgmPlatform(subject) is { Length: > 0 } platform) badges.Children.Add(BgmBadge(platform)); if (AirDate(subject) is { Length: > 0 } date) badges.Children.Add(BgmBadge(date)); titles.Children.Add(badges);
            var rating = Json.Get(subject, "rating"); var score = Json.Number(rating, "score"); var rank = Json.Number(rating, "rank", Json.Number(subject, "rank")); var votes = Json.Number(rating, "total");
            var stars = Row(8); var scoreText = Text(score > 0 ? "★ " + score.ToString("0.0") : "暂无评分", 16, true); scoreText.Foreground = DashboardOrange; stars.Children.Add(scoreText);
            if (rank > 0) stars.Children.Add(BgmBadge("#" + rank.ToString("0"))); var voteText = DashboardMuted($"（{votes:0} 人评分）", 11); voteText.VerticalAlignment = VerticalAlignment.Center; stars.Children.Add(voteText); titles.Children.Add(stars); info.Children.Add(titles);
            var actions = new Grid { ColumnSpacing = 12 }; actions.ColumnDefinitions.Add(new ColumnDefinition()); actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var collectionActions = Row(8); collectionActions.Children.Add(BgmCollectionMenu(page, id, (int)Json.Number(subject, "type", 2), collection.HasValue ? (int)Json.Number(collection.Value, "type") : 0, _ => { collection = Service.Snapshot("collection:" + id); return Task.CompletedTask; }));
            collectionActions.Children.Add(BgmRatingMenu(page, id, collection.HasValue ? Math.Clamp((int)Json.Number(collection.Value, "rate"), 0, 10) : 0, () => collection = Service.Snapshot("collection:" + id))); actions.Children.Add(collectionActions);
            if (Service.MoviePilot is { Enabled: true, AccessToken.Length: > 0 })
            {
                var download = DashboardAction("↓  MoviePilot 下载", () => navigate("viewing:resources:" + Uri.EscapeDataString(Json.Title(subject)))); download.FontSize = 12;
                BgmName(download, "MoviePilot 下载 Bangumi 条目 " + id); Grid.SetColumn(download, 1); actions.Children.Add(download);
            }
            bool? actionsNarrow = null;
            void ArrangeActions()
            {
                var narrow = info.ActualWidth is > 0 and < 380;
                if (actionsNarrow == narrow) return; actionsNarrow = narrow;
                actions.RowDefinitions.Clear(); actions.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); if (narrow) actions.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                Grid.SetColumnSpan(collectionActions, narrow ? 2 : 1);
                if (actions.Children.Count > 1) { var action = (FrameworkElement)actions.Children[1]; Grid.SetColumn(action, narrow ? 0 : 1); Grid.SetRow(action, narrow ? 1 : 0); Grid.SetColumnSpan(action, narrow ? 2 : 1); action.HorizontalAlignment = narrow ? HorizontalAlignment.Left : HorizontalAlignment.Right; }
            }
            grid.SizeChanged += (_, _) => { var width = grid.ActualWidth < 600 ? 98 : 128; if (artwork.Width != width) { artwork.Width = width; artwork.Height = width * 1.5; } };
            info.SizeChanged += (_, _) => ArrangeActions();
            Grid.SetRow(actions, 1); info.Children.Add(actions); Grid.SetColumn(info, 1); grid.Children.Add(info); hero.Children.Add(DashboardCard(grid, 16));
        }
        async Task ChaptersRefresh(bool force) { episodes = await LoadEpisodes(id, page.Token, force); page.Token.ThrowIfCancellationRequested(); RenderChapters(); }
        void RenderChapters()
        {
            chapters.Children.Clear();
            if (episodes is null) { chapters.Children.Add(DashboardEmpty("章节尚未同步")); return; }
            var content = Stack(8); BgmChapters(page, content, id, episodes, () => ChaptersRefresh(true)); chapters.Children.Add(DashboardCard(content, 10));
        }
        void RenderInformation()
        {
            information.Children.Clear(); information.Children.Add(Text("作品信息", 14, true));
            var fields = Json.OptionalItems(Json.Get(subject, "infobox")); var cells = new List<FrameworkElement>();
            foreach (var field in fields)
            {
                var value = Json.Get(field, "values"); if (value.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null) value = Json.Get(field, "value");
                var text = BgmInfoValue(value); if (text.Length == 0) continue;
                var grid = new Grid { ColumnSpacing = 10 }; grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(72) }); grid.ColumnDefinitions.Add(new ColumnDefinition());
                var name = DashboardMuted(Json.First(field, "key", "name"), 11); grid.Children.Add(name); var description = Text(text, 11); description.IsTextSelectionEnabled = true; Grid.SetColumn(description, 1); grid.Children.Add(description);
                var border = DashboardCard(grid, 9); border.CornerRadius = new CornerRadius(7); border.MinHeight = 44; border.Tag = field; cells.Add(border);
            }
            if (cells.Count == 0) information.Children.Add(DashboardMuted("暂无作品信息", 12)); else information.Children.Add(BgmResponsiveGrid(cells, 250, 8, 5, true));
            synopsis.Children.Clear();
            if (Json.Text(subject, "summary") is { Length: > 0 } summary)
            {
                var content = Stack(10); var expand = DashboardLink("展开全文", () => { });
                expand.Click += async (_, _) =>
                {
                    var full = Text(summary, 14); full.IsTextSelectionEnabled = true;
                    var dialog = new ContentDialog { XamlRoot = page.Body.XamlRoot, Title = "剧情简介", RequestedTheme = page.Body.ActualTheme, Content = new ScrollViewer { Content = full, MaxHeight = 520, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, CloseButtonText = "关闭" };
                    using var registration = page.Token.Register(() => page.Body.DispatcherQueue.TryEnqueue(dialog.Hide)); await dialog.ShowAsync();
                };
                content.Children.Add(DashboardHeading("剧情简介", expand)); var preview = DashboardMuted(summary, 12); preview.MaxLines = 4; preview.TextTrimming = TextTrimming.CharacterEllipsis; content.Children.Add(preview); synopsis.Children.Add(DashboardCard(content));
            }
            footer.Children.Clear(); var tags = Json.OptionalItems(Json.Get(subject, "tags"));
            if (tags.Length > 0)
            {
                var chips = Row(6); foreach (var tag in tags.Take(20)) chips.Children.Add(BgmBadge(tag.ValueKind == JsonValueKind.String ? tag.GetString() ?? "" : $"{Json.Text(tag, "name")}  {Json.Number(tag, "count"):0}"));
                footer.Children.Add(DashboardSection("相关标签", null, new OcPlayer.Windows.Controls.HorizontalMediaRail(chips, "Bangumi 标签", 0)));
            }
            var stats = Json.Get(subject, "collection");
            if (stats.ValueKind == JsonValueKind.Object)
            {
                var labels = BgmLabels((int)Json.Number(subject, "type", 2));
                var counts = new[] { "wish", "collect", "doing", "on_hold", "dropped" }.Select((key, index) =>
                {
                    var content = Stack(5); content.Children.Add(Text(Json.Number(stats, key, Json.Number(stats, (index + 1).ToString())).ToString("0"), 18, true)); content.Children.Add(DashboardMuted(labels[index], 11)); return (FrameworkElement)DashboardCard(content, 12);
                });
                footer.Children.Add(DashboardSection("全站收藏", null, BgmResponsiveGrid(counts, 100, 8, 5)));
            }
        }
        async Task Refresh(bool force = false)
        {
            if (subject.ValueKind != JsonValueKind.Object && Service.Snapshot("subject:" + id) is { } cached) { subject = cached; if (collection is null && Json.Get(subject, "interest").ValueKind == JsonValueKind.Object) collection = Json.Get(subject, "interest"); RenderHero(); RenderInformation(); }
            RenderChapters();
            subject = await Service.CachedBgm("subject", new { subjectId = id }, "subject:" + id, page.Token); page.Token.ThrowIfCancellationRequested();
            if (collection is null && Json.Get(subject, "interest").ValueKind == JsonValueKind.Object) collection = Json.Get(subject, "interest"); RenderHero(); RenderInformation();
            var collectionTask = LoadCollection(); var chaptersTask = LoadChapters(force); await Task.WhenAll(collectionTask, chaptersTask);
        }
        async Task LoadCollection()
        {
            try { collection = await Service.SubjectCollection(id, page.Token); page.Token.ThrowIfCancellationRequested(); RenderHero(); }
            catch (OperationCanceledException) { }
            catch (Exception ex) { if (!page.Token.IsCancellationRequested) hero.Children.Add(DashboardMuted("收藏读取失败，保留已有状态：" + ex.Message, 11)); }
        }
        async Task LoadChapters(bool force)
        {
            try { await ChaptersRefresh(force); }
            catch (OperationCanceledException) { }
            catch (Exception ex) { if (!page.Token.IsCancellationRequested) chapters.Children.Add(DashboardMuted("章节刷新失败：" + ex.Message, 11)); }
        }
        HeaderLeading = BgmIcon(page, "\uE72C", "刷新 Bangumi 详情与章节", () => Refresh(true));
        HeaderTrailing = BgmIcon(page, "\uE774", "在浏览器打开 Bangumi 条目 " + id, () => { Browse(Service.Domains.Main + "subject/" + id); return Task.CompletedTask; });
        return Show(page, () => Refresh(false));
    }
    private static string BgmInfoValue(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.Array => string.Join("、", Json.OptionalItems(value).Select(BgmInfoValue).Where(x => x.Length > 0)),
        JsonValueKind.Object => Json.First(value, "v", "text", "value", "name") is { Length: > 0 } text ? (Json.Text(value, "k") is { Length: > 0 } key ? key + "：" + text : text) : "",
        JsonValueKind.String or JsonValueKind.Number => value.ToString(), _ => ""
    };
}

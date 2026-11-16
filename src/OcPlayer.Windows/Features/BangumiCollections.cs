using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.Services;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed partial class IntegrationPages
{
    private UIElement Bangumi(string selection) => selection is "" or "3" ? BgmWatching() : BgmCollectionGrid(selection);
    private UIElement BgmWatching()
    {
        var page = new Page(); page.Body.MaxWidth = 1400; page.Body.Spacing = 22;
        HeaderTitle = "Bangumi 章节管理"; if (Gate(page, true)) return Show(page);
        var list = Stack(22); page.Body.Children.Add(list); var more = DashboardAction("加载更多", () => { }); page.Body.Children.Add(more);
        var rows = new List<JsonElement>(); var offsets = new Dictionary<int, int> { [2] = 0, [6] = 0 }; var done = new HashSet<int>(); var exhausted = false;
        var cards = new Dictionary<long, StackPanel>();
        async Task UpdateCard(JsonElement raw, StackPanel host, bool fetch)
        {
            var id = SubjectId(raw); var subject = Json.Subject(raw); JsonElement[]? episodes = Service.Snapshot("episodes:" + id) is { } cached ? Json.Items(cached) : null;
            void Render(string? error = null)
            {
                host.Children.Clear(); var main = (episodes ?? []).Where(x => Json.Number(x, "type") == 0).OrderBy(x => Json.Number(x, "sort")).ToArray();
                var total = Math.Max(main.Length, TotalEpisodes(subject)); var seen = episodes is not null ? main.Count(x => ViewingIntegrations.EpisodeStatus(x) == 2) : Json.Number(Interest(raw), "epStatus", Json.Number(Interest(raw), "ep_status"));
                var summary = new Grid { ColumnSpacing = 12 }; summary.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); summary.ColumnDefinitions.Add(new ColumnDefinition());
                summary.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var artwork = DashboardRow(DashboardArtwork(Cover(subject), 56, 84, 6), () => navigate("viewing:subject:" + id), "Bangumi 在看条目 " + id); artwork.Padding = new Thickness(0); summary.Children.Add(artwork);
                var info = new Grid(); info.RowDefinitions.Add(new RowDefinition()); info.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var names = Stack(3); names.Children.Add(DashboardLabel(Json.Title(subject), 14, true)); var original = DashboardMuted(Json.Text(subject, "name"), 11); original.MaxLines = 1; original.TextTrimming = TextTrimming.CharacterEllipsis; names.Children.Add(original);
                var nameLink = DashboardRow(names, () => navigate("viewing:subject:" + id), "Bangumi 在看标题 " + id); nameLink.Padding = new Thickness(0); nameLink.VerticalAlignment = VerticalAlignment.Top; info.Children.Add(nameLink);
                var progress = Stack(5); progress.Children.Add(DashboardMuted(total > 0 ? $"{seen:0} / {total:0}" : $"已看 {seen:0} · 总集数待确认", 11));
                progress.Children.Add(DashboardProgress(total > 0 ? seen / total * 100 : 0)); progress.MaxWidth = 650; progress.HorizontalAlignment = HorizontalAlignment.Left;
                info.SizeChanged += (_, _) => progress.Width = Math.Min(650, info.ActualWidth);
                Grid.SetRow(progress, 1); info.Children.Add(progress); Grid.SetColumn(info, 1); summary.Children.Add(info);
                var actions = new Grid(); actions.RowDefinitions.Add(new RowDefinition()); actions.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var state = BgmCollectionMenu(page, id, (int)Json.Number(subject, "type", 2), 3, _ => Load()); state.HorizontalAlignment = HorizontalAlignment.Right; state.VerticalAlignment = VerticalAlignment.Top; actions.Children.Add(state);
                var next = main.FirstOrDefault(x => ViewingIntegrations.EpisodeStatus(x) == 0);
                var quick = next.ValueKind == JsonValueKind.Object ? DashboardAction($"✓  看完 {Json.Number(next, "sort"):00.##}", () => { }) : DashboardAction(episodes is null ? "章节未同步" : main.Length > 0 && main.All(x => ViewingIntegrations.EpisodeStatus(x) == 2) ? "已看完" : "等待更新", () => { });
                quick.IsEnabled = next.ValueKind == JsonValueKind.Object && ViewingIntegrations.EpisodeAired(next); quick.FontSize = 11; quick.HorizontalAlignment = HorizontalAlignment.Right; Grid.SetRow(quick, 1); actions.Children.Add(quick);
                BgmName(quick, "Bangumi 看完下一集 " + id);
                quick.Click += async (_, _) => await page.Run(async () => { await Service.UpdateEpisodeCollection(id, (long)Json.Number(next, "id"), 2, false, page.Token); await UpdateCard(raw, host, true); });
                Grid.SetColumn(actions, 2); summary.Children.Add(actions); host.Children.Add(summary);
                if (episodes is not null)
                {
                    var chapters = Stack(7); BgmChapters(page, chapters, id, BgmProgressWindow(main), () => UpdateCard(raw, host, true)); host.Children.Add(chapters);
                }
                else host.Children.Add(DashboardMuted("正在同步章节…", 11));
                if (error is not null) host.Children.Add(DashboardMuted("章节刷新失败：" + error, 11));
            }
            Render();
            if (!fetch) return;
            try { episodes = await LoadEpisodes(id, page.Token); page.Token.ThrowIfCancellationRequested(); Render(); }
            catch (OperationCanceledException) { }
            catch (Exception ex) { if (!page.Token.IsCancellationRequested) Render(ex.Message); }
        }
        void RenderList()
        {
            list.Children.Clear(); cards.Clear();
            IEnumerable<JsonElement> display = rows;
            display = Service.Preference("bangumi.watching.sort") == "airdate" ? display.OrderByDescending(x => AirDate(Json.Subject(x))) : display.OrderByDescending(x => Json.Number(Interest(x), "updatedAt", Json.Number(x, "updated_at")));
            foreach (var row in display)
            {
                var host = Stack(10); cards[SubjectId(row)] = host; list.Children.Add(DashboardCard(host, 12)); _ = UpdateCard(row, host, false);
            }
            if (cards.Count == 0) list.Children.Add(DashboardEmpty("暂无符合条件的在看条目")); more.Visibility = exhausted ? Visibility.Collapsed : Visibility.Visible;
        }
        async Task Next()
        {
            var responses = await Task.WhenAll(new[] { 2, 6 }.Where(kind => !done.Contains(kind)).Select(async kind => (Kind: kind, Response: await Service.CollectionPage(3, kind, offsets[kind], page.Token, 30))));
            page.Token.ThrowIfCancellationRequested(); var fetched = new List<JsonElement>();
            foreach (var response in responses)
            {
                var items = Json.Items(response.Response); fetched.AddRange(items); offsets[response.Kind] += items.Length;
                if (items.Length == 0 || offsets[response.Kind] >= Json.Number(response.Response, "total", double.MaxValue) || items.Length < 30) done.Add(response.Kind);
            }
            var batch = fetched.ToArray(); rows.AddRange(batch); exhausted = done.Count == 2;
            foreach (var kind in new[] { 2, 6 }) Service.SaveSnapshot($"collections:{kind}:3", JsonSerializer.SerializeToElement(rows.Where(x => Json.Number(Json.Subject(x), "type", 2) == kind)));
            foreach (var raw in batch) { Service.SaveSnapshot("subject:" + SubjectId(raw), Json.Subject(raw)); Service.SaveSnapshot("collection:" + SubjectId(raw), raw); }
            RenderList(); using var concurrency = new SemaphoreSlim(4);
            await Task.WhenAll(batch.Select(async raw => { await concurrency.WaitAsync(page.Token); try { if (cards.TryGetValue(SubjectId(raw), out var host)) await UpdateCard(raw, host, true); } finally { concurrency.Release(); } }));
        }
        async Task Load()
        {
            rows.Clear(); offsets[2] = offsets[6] = 0; done.Clear(); exhausted = false;
            foreach (var kind in new[] { 2, 6 }) if (Service.Snapshot($"collections:{kind}:3") is { } cached) rows.AddRange(Json.Items(cached));
            if (rows.Count > 0) { RenderList(); rows.Clear(); }
            await Next();
        }
        var toolbar = Row(6); HeaderLeading = toolbar;
        toolbar.Children.Add(BgmIcon(page, "\uE787", "Bangumi 完整日历", () => { navigate("viewing:calendar"); return Task.CompletedTask; }));
        var sort = new MenuFlyout();
        foreach (var (label, value) in new[] { ("按收藏时间", "collection"), ("按放送时间", "airdate") })
        {
            var item = new ToggleMenuFlyoutItem { Text = label, IsChecked = Service.Preference("bangumi.watching.sort", "collection") == value };
            item.Click += (_, _) => { Service.SetPreference("bangumi.watching.sort", value); foreach (var option in sort.Items.OfType<ToggleMenuFlyoutItem>()) option.IsChecked = option == item; RenderList(); }; sort.Items.Add(item);
        }
        var sync = new MenuFlyoutItem { Text = "同步全部收藏和章节" }; sync.Click += async (_, _) => await page.Run(async () => { await Service.SynchronizeCollections(count => page.Status.Text = $"已同步 {count} 条", page.Token); await Load(); }); sort.Items.Add(new MenuFlyoutSeparator()); sort.Items.Add(sync);
        toolbar.Children.Add(BgmMenu("\uE8CB", "Bangumi 排序与同步", sort));
        toolbar.Children.Add(BgmIcon(page, "\uE77B", "Bangumi 个人主页", () => { navigate("viewing:profile"); return Task.CompletedTask; })); toolbar.Children.Add(BgmIcon(page, "\uE72C", "刷新 Bangumi 在看", Load));
        var search = new AutoSuggestBox { Width = 280, Height = 32, PlaceholderText = "搜索 Bangumi 条目", QueryIcon = new SymbolIcon(Symbol.Find) }; HeaderTrailing = search; BgmName(search, "搜索 Bangumi 条目");
        search.QuerySubmitted += (_, args) => { if (!string.IsNullOrWhiteSpace(args.QueryText)) navigate("viewing:bangumi:q=" + Uri.EscapeDataString(args.QueryText.Trim())); };
        more.Click += async (_, _) => await page.Run(Next);
        var scroll = (ScrollViewer)Show(page, Load); var loadingMore = false;
        scroll.ViewChanged += async (_, _) => { if (loadingMore || exhausted || rows.Count == 0 || scroll.ScrollableHeight <= 0 || scroll.VerticalOffset < scroll.ScrollableHeight - 150) return; loadingMore = true; try { await page.Run(Next); } finally { loadingMore = false; } };
        return scroll;
    }

    private UIElement BgmCollectionGrid(string selection)
    {
        var parts = selection.Split(','); var status = int.TryParse(parts[0], out var number) ? Math.Clamp(number, 1, 5) : 1;
        var kind = parts.Length > 1 && int.TryParse(parts[1], out var category) && SubjectTypes.Any(x => x.Id == category && x.Id != 0) ? category : 2;
        var searching = selection.StartsWith("q="); var query = searching ? Uri.UnescapeDataString(selection[2..]) : ""; var searchKind = 0;
        var page = new Page(); page.Body.MaxWidth = 1040; page.Body.Spacing = 22; HeaderTitle = searching ? "Bangumi 搜索" : SubjectTypes.First(x => x.Id == kind).Label + "片单";
        if (Gate(page, true)) return Show(page); var totals = new double?[5]; var rows = new List<JsonElement>(); var offset = 0; var exhausted = false; var generation = 0;
        var segmented = new Grid { ColumnSpacing = 2 }; for (var i = 0; i < 5; i++) segmented.ColumnDefinitions.Add(new ColumnDefinition());
        var tabs = new List<ToggleButton>(); var title = Text("", 25, true); var subtitle = DashboardMuted("", 12); var posters = Stack(0);
        var more = DashboardAction("加载更多", () => { }); var selector = DashboardCard(segmented, 4); selector.Width = 440; selector.HorizontalAlignment = HorizontalAlignment.Left;
        page.Body.SizeChanged += (_, _) => selector.Width = Math.Min(440, page.Body.ActualWidth);
        page.Body.Children.Add(selector); var heading = Stack(6); heading.Children.Add(title); heading.Children.Add(subtitle); page.Body.Children.Add(heading); page.Body.Children.Add(posters); page.Body.Children.Add(more);
        void Labels()
        {
            var labels = BgmLabels(kind, true); for (var i = 0; i < tabs.Count; i++) { tabs[i].Content = labels[i] + (totals[i] is { } total ? "  " + total.ToString("0") : ""); tabs[i].IsChecked = !searching && status == i + 1; }
            title.Text = searching ? "搜索结果" : labels[status - 1] + "片单";
            subtitle.Text = searching ? $"“{query}” · {rows.Count} 个条目" : $"Bangumi · {totals[status - 1]?.ToString("0") ?? rows.Count.ToString()} 部{SubjectTypes.First(x => x.Id == kind).Label}";
        }
        void Render()
        {
            posters.Children.Clear(); posters.Children.Add(BgmResponsiveGrid(rows.Select(x => (FrameworkElement)BgmPosterCard(x)), 220, 20, 4));
            if (rows.Count == 0) posters.Children.Add(DashboardEmpty("暂无条目")); Labels(); more.Visibility = exhausted ? Visibility.Collapsed : Visibility.Visible;
        }
        async Task Next(int expected)
        {
            if (expected != generation) return;
            var requestedStatus = status; var requestedKind = kind; var requestedSearch = searching;
            var response = requestedSearch ? await Service.Bgm("search", new { keyword = query, subjectType = searchKind, limit = 20, offset }, page.Token) : await Service.CollectionPage(requestedStatus, requestedKind, offset, page.Token, 20);
            var batch = Json.Items(response); page.Token.ThrowIfCancellationRequested(); if (expected != generation) return; rows.AddRange(batch); offset += batch.Length;
            exhausted = batch.Length == 0 || offset >= Json.Number(response, "total", double.MaxValue) || batch.Length < 20;
            if (!requestedSearch) { totals[requestedStatus - 1] = Json.Number(response, "total", rows.Count); Service.SaveSnapshot($"collections:{requestedKind}:{requestedStatus}", JsonSerializer.SerializeToElement(rows)); }
            foreach (var raw in batch) { Service.SaveSnapshot("subject:" + SubjectId(raw), Json.Subject(raw)); if (!requestedSearch) Service.SaveSnapshot("collection:" + SubjectId(raw), raw); }
            Render();
        }
        async Task Load(int expected)
        {
            if (expected != generation) return;
            rows.Clear(); offset = 0; exhausted = false;
            if (!searching && Service.Snapshot($"collections:{kind}:{status}") is { } cached) { rows.AddRange(Json.Items(cached)); Render(); rows.Clear(); }
            await Next(expected); if (expected != generation) return;
            if (!searching) { var requestedKind = kind; var counts = await Task.WhenAll(Enumerable.Range(1, 5).Select(async state => Json.Number(await Service.CollectionPage(state, requestedKind, 0, page.Token, 1), "total"))); page.Token.ThrowIfCancellationRequested(); if (expected != generation) return; for (var i = 0; i < 5; i++) totals[i] = counts[i]; Labels(); }
        }
        Task Reload() => Load(++generation);
        for (var i = 0; i < 5; i++)
        {
            var state = i + 1; var tab = new ToggleButton { Style = DashboardStyle("BangumiSegmentButtonStyle"), HorizontalAlignment = HorizontalAlignment.Stretch };
            tab.Click += async (_, _) => { status = state; searching = false; var expected = ++generation; Labels(); await page.Run(() => Load(expected)); }; Grid.SetColumn(tab, i); segmented.Children.Add(tab); tabs.Add(tab); BgmName(tab, "Bangumi 片单筛选 " + state);
        }
        Labels(); var toolbar = Row(6); HeaderLeading = toolbar; toolbar.Children.Add(BgmIcon(page, "\uE72C", "刷新 Bangumi 片单", Reload));
        var types = new MenuFlyout();
        foreach (var type in SubjectTypes)
        {
            var item = new ToggleMenuFlyoutItem { Text = type.Label, IsChecked = searching ? searchKind == type.Id : kind == type.Id };
            if (!searching && type.Id == 0) continue;
            item.Click += async (_, _) => { if (searching) searchKind = type.Id; else { kind = type.Id; totals = new double?[5]; HeaderTitle = type.Label + "片单"; HeaderChanged?.Invoke(); } var expected = ++generation; foreach (var option in types.Items.OfType<ToggleMenuFlyoutItem>()) option.IsChecked = option == item; Labels(); await page.Run(() => Load(expected)); }; types.Items.Add(item);
        }
        toolbar.Children.Add(BgmMenu("\uE8A5", "Bangumi 收藏与搜索类型", types));
        if (searching)
        {
            var search = new AutoSuggestBox { Width = 280, Height = 32, Text = query, PlaceholderText = "搜索 Bangumi 条目", QueryIcon = new SymbolIcon(Symbol.Find) }; HeaderTrailing = search; BgmName(search, "搜索 Bangumi 条目");
            search.QuerySubmitted += async (_, args) => { query = args.QueryText.Trim(); if (query.Length == 0) return; searching = true; var expected = ++generation; await page.Run(() => Load(expected)); };
        }
        more.Click += async (_, _) => { var expected = generation; await page.Run(() => Next(expected)); };
        var scroll = (ScrollViewer)Show(page, Reload); var loadingMore = false;
        scroll.ViewChanged += async (_, _) => { if (loadingMore || exhausted || rows.Count == 0 || scroll.ScrollableHeight <= 0 || scroll.VerticalOffset < scroll.ScrollableHeight - 150) return; loadingMore = true; var expected = generation; try { await page.Run(() => Next(expected)); } finally { loadingMore = false; } }; return scroll;
    }

    private UIElement Profile()
    {
        var page = new Page(); page.Body.MaxWidth = 1400; page.Body.Spacing = 28; HeaderTitle = "我的"; if (Gate(page, true)) return Show(page); var account = Service.Bangumi!;
        var identity = Row(14); identity.Children.Add(DashboardArtwork(Service.RewriteBangumiUrl(account.Avatar ?? ""), 70, 70, 12, "\uE77B"));
        var name = Stack(5); name.VerticalAlignment = VerticalAlignment.Center; name.Children.Add(Text(account.DisplayName, 18, true)); name.Children.Add(DashboardMuted("@" + account.UserName, 12)); var signature = DashboardMuted("", 11); signature.MaxLines = 2; name.Children.Add(signature); identity.Children.Add(name); page.Body.Children.Add(identity);
        var sections = new List<Func<Task>>();
        foreach (var (label, kind, initial) in new[] { ("我的动画", 2, 3), ("我的游戏", 4, 2), ("我的书籍", 1, 2), ("我的音乐", 3, 2), ("我的三次元", 6, 3) })
        {
            var selected = initial; var initialized = false; var rows = new Dictionary<int, JsonElement[]>(); var totals = new double?[5]; var section = Stack(10); var tabs = Row(6); var rail = Stack(0); var buttons = new List<ToggleButton>();
            section.Children.Add(DashboardLink(label, () => navigate($"viewing:bangumi:{selected},{kind}"))); section.Children.Add(new HorizontalMediaRail(tabs, label + "状态", 0)); section.Children.Add(rail); page.Body.Children.Add(section);
            void Render()
            {
                var labels = BgmLabels(kind); for (var i = 0; i < buttons.Count; i++) { buttons[i].Content = labels[i] + " (" + (totals[i]?.ToString("0") ?? "—") + ")"; buttons[i].IsChecked = selected == i + 1; }
                rail.Children.Clear(); var posters = Row(12);
                foreach (var raw in rows.GetValueOrDefault(selected, []).Take(12))
                {
                    var subject = Json.Subject(raw); var content = Stack(6); var art = DashboardArtwork(Cover(subject), 84, 126, 7); if (kind is 4 or 3 && art.Child is Image image) image.Stretch = Stretch.Uniform; content.Children.Add(art);
                    var title = DashboardLabel(Json.Title(subject), 11); content.Children.Add(title); var button = DashboardRow(content, () => navigate("viewing:subject:" + SubjectId(raw)), $"Bangumi 主页条目 {SubjectId(raw)}"); button.Width = 84; button.Padding = new Thickness(0); posters.Children.Add(button);
                }
                if (posters.Children.Count == 0) rail.Children.Add(DashboardEmpty("此分类暂无收藏")); else rail.Children.Add(new HorizontalMediaRail(posters, label, 24));
            }
            async Task LoadSelected()
            {
                var requested = selected; var response = await Service.CollectionPage(requested, kind, 0, page.Token, 12); page.Token.ThrowIfCancellationRequested();
                rows[requested] = Json.Items(response); totals[requested - 1] = Json.Number(response, "total", rows[requested].Length);
                Service.SaveSnapshot($"profile:{kind}:{requested}", JsonSerializer.SerializeToElement(rows[requested]));
                foreach (var raw in rows[requested]) { Service.SaveSnapshot("subject:" + SubjectId(raw), Json.Subject(raw)); Service.SaveSnapshot("collection:" + SubjectId(raw), raw); }
                if (requested == selected) Render();
            }
            for (var i = 0; i < 5; i++) { var state = i + 1; var button = new ToggleButton { Style = DashboardStyle("BangumiProfileTabStyle") }; button.Click += async (_, _) => { selected = state; initialized = true; Render(); await page.Run(LoadSelected); }; BgmName(button, $"Bangumi 主页 {kind} 筛选 {state}"); buttons.Add(button); tabs.Children.Add(button); }
            Render();
            async Task LoadSection()
            {
                try
                {
                    var results = await Task.WhenAll(Enumerable.Range(1, 5).Select(state => Service.CollectionPage(state, kind, 0, page.Token, 1))); page.Token.ThrowIfCancellationRequested();
                    for (var i = 0; i < 5; i++)
                    {
                        totals[i] = Json.Number(results[i], "total", Json.Items(results[i]).Length);
                    }
                    if (!initialized) { initialized = true; selected = new[] { 3, 2, 1, 4, 5 }.FirstOrDefault(state => totals[state - 1] > 0, initial); }
                    await LoadSelected();
                }
                catch (OperationCanceledException) { }
                catch (Exception ex) { if (!page.Token.IsCancellationRequested) rail.Children.Add(DashboardMuted("收藏加载失败：" + ex.Message, 12)); }
            }
            for (var state = 1; state <= 5; state++) if (Service.Snapshot($"profile:{kind}:{state}") is { } cached) rows[state] = Json.Items(cached);
            Render(); sections.Add(LoadSection);
        }
        async Task Load()
        {
            foreach (var section in sections) { page.Token.ThrowIfCancellationRequested(); await section(); }
            try { var profile = ViewingIntegrations.DecodeBangumi(await Service.Bgm("request", new { url = account.BaseUrl + "v0/users/" + Uri.EscapeDataString(account.UserName), httpMethod = "GET" }, page.Token)); page.Token.ThrowIfCancellationRequested(); signature.Text = Json.Text(profile, "sign"); }
            catch (OperationCanceledException) { }
            catch (Exception ex) { if (!page.Token.IsCancellationRequested) signature.Text = "个人签名读取失败：" + ex.Message; }
        }
        var toolbar = Row(6); HeaderLeading = toolbar;
        toolbar.Children.Add(BgmIcon(page, "\uE8AC", "退出 Bangumi", async () => { if (await Confirm(page, "退出 Bangumi", "清除本机登录令牌，远端收藏仍保留。")) { await Service.Logout("bangumi"); navigate("settings:Bangumi"); } }));
        toolbar.Children.Add(BgmIcon(page, "\uE72C", "刷新 Bangumi 主页", Load));
        HeaderTrailing = BgmIcon(page, "\uE774", "在浏览器打开 Bangumi 主页", () => { Browse(Service.Domains.Main + "user/" + Uri.EscapeDataString(account.UserName)); return Task.CompletedTask; });
        return Show(page, Load);
    }
}

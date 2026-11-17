using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Services;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed partial class IntegrationPages
{
    public static string ResourceRoute(JsonElement media) => "viewing:resources:media=" + Uri.EscapeDataString(media.GetRawText());
    private UIElement MoviePilot(string query)
    {
        var page = new Page(); page.Body.MaxWidth = 10000; page.Body.Spacing = 22; HeaderTitle = "MoviePilot 资源管理";
        if (Gate(page, false)) return Show(page); var list = Stack(14);
        var search = new AutoSuggestBox { Text = query, Width = 280, Height = 32, PlaceholderText = "搜索电影、电视剧、番剧…", QueryIcon = new SymbolIcon(Symbol.Find) };
        HeaderTrailing = search; MpName(search, "搜索 MoviePilot 媒体");
        var category = new SelectorBar { Height = 28, MinHeight = 0 };
        foreach (var label in new[] { "全部", "电影", "剧集" }) category.Items.Add(new SelectorBarItem
        {
            Text = label, Height = 28, MinHeight = 0, FontSize = 12,
            Padding = new Thickness(12, 3, 12, 3), VerticalContentAlignment = VerticalAlignment.Center
        });
        category.SelectedItem = category.Items[0]; MpName(category, "MoviePilot 订阅分类");
        var count = DashboardMuted(""); var controls = new Grid { ColumnSpacing = 16 }; controls.ColumnDefinitions.Add(new ColumnDefinition()); controls.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var categories = Row(8); var categoryLabel = DashboardLabel("分类", 12, true); categoryLabel.VerticalAlignment = VerticalAlignment.Center; categories.Children.Add(categoryLabel); categories.Children.Add(category); controls.Children.Add(categories); Grid.SetColumn(count, 1); count.VerticalAlignment = VerticalAlignment.Center; controls.Children.Add(count);
        JsonElement[] subscriptions = []; var searchingMode = query.Length > 0; var searchGeneration = 0;
        void RenderSubscriptions()
        {
            if (searchingMode) return; list.Children.Clear(); controls.Visibility = Visibility.Visible; var movies = subscriptions.Count(MoviePilotPolicies.IsMovie);
            category.Items[0].Text = $"全部 ({subscriptions.Length})"; category.Items[1].Text = $"电影 ({movies})"; category.Items[2].Text = $"剧集 ({subscriptions.Length - movies})";
            count.Text = $"● {subscriptions.Count(x => MoviePilotPolicies.State(x) == "追更中")} 部追更中";
            var selected = category.Items.IndexOf(category.SelectedItem); var cards = subscriptions.Where(x => selected <= 0 || MoviePilotPolicies.IsMovie(x) == (selected == 1)).Select(item => MpSubscriptionCard(page, item, Load)).ToArray();
            list.Children.Add(cards.Length == 0 ? MpEmpty("此分类暂无订阅，可在上方搜索媒体或添加订阅。", "\uE8B2") : MpSubscriptionGrid(cards));
        }
        async Task Load() { subscriptions = Json.Items(await Service.Mp("subscription.list", null, page.Token)); RenderSubscriptions(); }
        async Task Search()
        {
            searchingMode = !string.IsNullOrWhiteSpace(search.Text); if (!searchingMode) { await Load(); return; }
            var generation = ++searchGeneration;
            var items = Json.Items(await Service.Mp("mediaSearch", new { title = search.Text.Trim() }, page.Token));
            if (generation != searchGeneration || page.Token.IsCancellationRequested) return;
            subscriptions = Json.Items(await Service.Mp("subscription.list", null, page.Token));
            if (generation != searchGeneration || page.Token.IsCancellationRequested) return;
            list.Children.Clear(); controls.Visibility = Visibility.Collapsed;
            list.Children.Add(MpSectionHeading("媒体结果", items.Length.ToString()));
            foreach (var item in items)
            {
                var subscribed = MoviePilotPolicies.Subscribed(item, subscriptions);
                var menu = new MenuFlyout(); MpMenuAction(menu, page, "快捷加入订阅", "\uE710", async () => { await Service.Mp("subscription.add", new { subscription = MoviePilotPolicies.NewSubscription(item) }, page.Token); await Search(); });
                MpMenuAction(menu, page, "配置规则并订阅…", "\uE713", () => EditSubscription(page, item, false));
                var subscribe = MpMenu(subscribed ? "\uE73E" : "\uE710", subscribed ? "已订阅" : "订阅", "MoviePilot 订阅操作 " + Json.Title(item), menu); subscribe.IsEnabled = !subscribed;
                var actions = Row(8); actions.Children.Add(subscribe); actions.Children.Add(MpCompact(Button("", () => navigate(ResourceRoute(item))), "\uE721", "查资源", "MoviePilot 查资源 " + Json.Title(item)));
                list.Children.Add(MpMediaCard(item, false, actions));
            }
            if (items.Length == 0) list.Children.Add(MpEmpty("没有找到媒体，试试其他关键词。", "\uE721"));
        }
        category.SelectionChanged += (_, _) => RenderSubscriptions(); search.QuerySubmitted += async (_, _) => await page.Run(Search);
        search.TextChanged += (_, _) => { if (search.Text.Length == 0 && searchingMode) { ++searchGeneration; searchingMode = false; RenderSubscriptions(); } };
        var toolbar = Row(6); HeaderLeading = toolbar;
        toolbar.Children.Add(MpCompact(page.Action("", () => EditSubscription(page, default, false)), "\uE710", "", "添加 MoviePilot 订阅"));
        toolbar.Children.Add(MpCompact(Button("", () => navigate("viewing:downloads")), "\uE896", "", "MoviePilot 下载管理"));
        var more = new MenuFlyout(); MpMenuAction(more, page, "刷新订阅列表", "\uE72C", Load);
        MpMenuAction(more, page, "向服务器请求刷新", "\uE895", async () => { await Service.Mp("subscription.refresh", null, page.Token); await Load(); });
        MpMenuAction(more, page, "执行全站追更检索", "\uE721", async () => { await Service.Mp("subscription.search", null, page.Token); await Load(); });
        more.Items.Add(new MenuFlyoutSeparator()); MpMenuAction(more, page, "重新登录 MoviePilot", "\uE77B", () => ReconnectMoviePilot(page));
        toolbar.Children.Add(MpMenu("\uE712", "", "MoviePilot 更多操作", more));
        page.Body.Children.Add(controls); page.Body.Children.Add(list);
        return Show(page, query.Length == 0 ? Load : Search, new Thickness(52, 16, 52, 48));
    }
    private async Task EditSubscription(Page page, JsonElement item, bool editing)
    {
        var fields = Stack(12); var raw = editing ? JsonNode.Parse(item.GetRawText())!.AsObject() : MoviePilotPolicies.NewSubscription(item);
        TextBox TextField(string label, params string[] keys) { var text = new TextBox { Header = label, Text = keys.Select(key => raw[key]?.ToString()).FirstOrDefault(x => !string.IsNullOrEmpty(x)) ?? "" }; fields.Children.Add(text); return text; }
        NumberBox Number(string label, string key, int defaultValue, int min = 0) { var number = new NumberBox { Header = label, Value = double.TryParse(raw[key]?.ToString(), out var value) ? value : defaultValue, Minimum = min, Maximum = 999 }; fields.Children.Add(number); return number; }
        var name = TextField("名称", "name", "title"); var type = new ComboBox { Header = "类型", ItemsSource = new[] { "电影", "电视剧" }, SelectedIndex = MoviePilotPolicies.IsMovie(item) ? 0 : 1 }; fields.Children.Add(type);
        var year = TextField("年份", "year"); var tmdb = TextField("TMDB ID", "tmdbid", "tmdb_id"); var douban = TextField("豆瓣 ID", "doubanid", "douban_id"); var bangumi = TextField("Bangumi ID", "bangumiid", "bangumi_id");
        var season = Number("季", "season", 1, 1); var start = Number("起始集数（0–999）", "start_episode", 1); var total = Number("总集数（0 = 自动识别）", "total_episode", 0); var lack = Number("缺失集数", "lack_episode", 0);
        season.Maximum = 99;
        void TypeFields() { foreach (var field in new[] { season, start, total, lack }) field.Visibility = type.SelectedIndex == 1 ? Visibility.Visible : Visibility.Collapsed; }
        type.SelectionChanged += (_, _) => TypeFields(); TypeFields();
        var state = new ComboBox { Header = "状态", ItemsSource = new[] { "追更中", "暂停", "已完成" }, SelectedIndex = Json.Text(item, "state") switch { "P" => 1, "O" => 2, _ => 0 } }; fields.Children.Add(state);
        var keyword = TextField("匹配关键词", "keyword"); var include = TextField("包含关键词（逗号分隔）", "include"); var exclude = TextField("排除关键词（逗号分隔）", "exclude");
        var qualityOptions = new[] { "全部 / 默认", "2160p", "1080p", "4K", "WEB-DL", "BluRay", "Dolby Vision", "HDR" }; var quality = new ComboBox { Header = "分辨率 / 质量偏好", ItemsSource = qualityOptions, SelectedIndex = Math.Max(0, Array.IndexOf(qualityOptions, Json.Text(item, "quality"))) }; fields.Children.Add(quality);
        var sites = new ListView { SelectionMode = ListViewSelectionMode.Multiple, MaxHeight = 220 }; var siteStatus = Muted("不选择表示使用全部站点"); fields.Children.Add(Text("限定搜索站点")); fields.Children.Add(sites); fields.Children.Add(siteStatus);
        var selected = Json.OptionalItems(Json.Get(item, "sites")).Select(x => x.ToString()).ToHashSet(); var sitesLoaded = false;
        async Task LoadSites() { try { var choices = Json.Items(await Service.Mp("sites", null, page.Token)); sites.Items.Clear(); foreach (var choice in choices) { var row = new ListViewItem { Content = Json.Title(choice), Tag = (long)Json.Number(choice, "id") }; sites.Items.Add(row); if (selected.Contains(row.Tag.ToString()!)) sites.SelectedItems.Add(row); } sitesLoaded = true; siteStatus.Text = "不选择表示使用全部站点"; } catch (Exception ex) { siteStatus.Text = "站点加载失败，已有设置将保留：" + ex.Message; } }
        var siteActions = Row(8); siteActions.Children.Add(Button("使用全部站点", () => sites.SelectedItems.Clear())); siteActions.Children.Add(Button("加载 / 重试", async () => await LoadSites())); siteActions.Children.Add(Button("完成选择", () => siteStatus.Text = $"已限定 {sites.SelectedItems.Count} 个站点（0 表示全部）")); fields.Children.Add(siteActions);
        var best = new ToggleSwitch { Header = "最佳版本洗版", IsOn = Json.Get(item, "best_version").ValueKind == JsonValueKind.True }; fields.Children.Add(best);
        var path = TextField("自定义存储路径", "save_path"); var poster = TextField("海报链接", "poster", "poster_path"); var overview = TextField("简介", "overview", "description"); overview.AcceptsReturn = true; overview.TextWrapping = TextWrapping.Wrap;
        var error = Muted(""); fields.Children.Add(error);
        var dialog = new ContentDialog { XamlRoot = page.Body.XamlRoot, Title = editing ? "编辑订阅" : "新建订阅", Content = new ScrollViewer { Content = fields, MaxHeight = 620 }, PrimaryButtonText = "保存", CloseButtonText = "取消" };
        dialog.PrimaryButtonClick += async (_, e) =>
        {
            var deferral = e.GetDeferral(); e.Cancel = true; dialog.IsPrimaryButtonEnabled = false;
            try
            {
                if (string.IsNullOrWhiteSpace(name.Text)) throw new ArgumentException("订阅名称不能为空。");
                raw["name"] = name.Text.Trim(); raw["title"] = name.Text.Trim(); raw["type"] = type.SelectedIndex == 0 ? "电影" : "电视剧"; raw["year"] = year.Text.Trim(); raw["state"] = new[] { "R", "P", "O" }[state.SelectedIndex];
                MoviePilotPolicies.SetText(raw, tmdb.Text, true, "tmdbid", "tmdb_id"); MoviePilotPolicies.SetText(raw, douban.Text, false, "doubanid", "douban_id"); MoviePilotPolicies.SetText(raw, bangumi.Text, true, "bangumiid", "bangumi_id");
                foreach (var (box, key) in new[] { (keyword, "keyword"), (include, "include"), (exclude, "exclude"), (path, "save_path") }) MoviePilotPolicies.SetText(raw, box.Text, false, key);
                MoviePilotPolicies.SetText(raw, poster.Text, false, "poster", "poster_path"); MoviePilotPolicies.SetText(raw, overview.Text, false, "overview", "description");
                MoviePilotPolicies.SetText(raw, quality.SelectedIndex > 0 ? qualityOptions[quality.SelectedIndex] : "", false, "quality"); raw["best_version"] = best.IsOn;
                foreach (var (box, key) in new[] { (season, "season"), (start, "start_episode"), (total, "total_episode"), (lack, "lack_episode") }) { if (type.SelectedIndex == 1) { if (!double.IsFinite(box.Value) || box.Value != Math.Truncate(box.Value) || box.Value < box.Minimum || box.Value > box.Maximum) throw new ArgumentException(box.Header + "必须是有效范围内的整数。"); raw[key] = (int)box.Value; } else raw.Remove(key); }
                if (sitesLoaded) { var siteIds = sites.SelectedItems.OfType<ListViewItem>().Select(x => (long)x.Tag).ToArray(); if (siteIds.Length > 0) raw["sites"] = JsonSerializer.SerializeToNode(siteIds); else raw.Remove("sites"); }
                await Service.Mp(editing ? "subscription.update" : "subscription.add", new { subscription = raw }, page.Token); e.Cancel = false;
            }
            catch (Exception ex) { error.Text = ex.Message; }
            finally { dialog.IsPrimaryButtonEnabled = true; deferral.Complete(); }
        };
        using var registration = page.Token.Register(() => page.Body.DispatcherQueue.TryEnqueue(dialog.Hide)); await LoadSites();
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) navigate("viewing:moviepilot");
    }
    private UIElement Downloads()
    {
        var page = new Page(); if (Gate(page, false)) return Show(page); var list = Stack(12); var count = Text("下载任务", 20, true);
        async Task Load()
        {
            var items = Json.Items(await Service.Mp("download.list", null, page.Token)); list.Children.Clear(); count.Text = $"下载任务 · {items.Length} 个";
            foreach (var item in items)
            {
                var hash = Json.First(item, "hash", "id"); var content = Stack(10); var progress = Json.Number(item, "progress"); var state = Json.First(item, "state", "status"); var paused = state.Contains("pause", StringComparison.OrdinalIgnoreCase) || state.Contains("stop", StringComparison.OrdinalIgnoreCase) || state.Contains("暂停");
                content.Children.Add(Text(Json.DownloadTitle(item), 16, true)); content.Children.Add(Muted(Json.First(item, "name", "title")));
                content.Children.Add(Muted($"{state} · 站点 {Json.First(item, "site_name", "site")} · {Json.Number(item, "size") / 1073741824:0.##} GB")); content.Children.Add(new ProgressBar { Value = Math.Clamp(progress, 0, 100) });
                content.Children.Add(Muted($"{progress:0.#}%" + (!paused && progress < 99.9 ? $" · {Json.Text(item, "dlspeed")} · {Json.Text(item, "left_time")}" : "")));
                var controls = Row(8); var busy = new ProgressRing { IsActive = false, Width = 24, Height = 24, Visibility = Visibility.Collapsed }; content.Children.Add(controls); content.Children.Add(busy);
                foreach (var (label, command) in new[] { (paused ? "开始" : "暂停", paused ? "start" : "stop"), ("删除", "remove") })
                {
                    var button = page.Action(label, async () =>
                    {
                        if (command == "remove" && !await Confirm(page, "删除下载任务", Json.DownloadTitle(item) + "\n只删除下载器任务，已经下载的文件不会被删除。")) return;
                        controls.Visibility = Visibility.Collapsed; busy.Visibility = Visibility.Visible; busy.IsActive = true;
                        try { await Service.Mp("download." + command, new { hash }, page.Token); await Load(); }
                        finally { controls.Visibility = Visibility.Visible; busy.Visibility = Visibility.Collapsed; busy.IsActive = false; }
                    }); button.IsEnabled = hash.Length > 0; controls.Children.Add(button);
                }
                list.Children.Add(Panel(content));
            }
            if (items.Length == 0) list.Children.Add(Muted("当前没有下载任务"));
        }
        page.Body.Children.Add(count); page.Body.Children.Add(page.Action("刷新下载任务", Load)); page.Body.Children.Add(list); Reconnect(page); page.Poll(TimeSpan.FromSeconds(5), Load); return Show(page, Load);
    }
}

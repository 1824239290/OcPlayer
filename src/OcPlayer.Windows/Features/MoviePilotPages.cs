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
    private UIElement MoviePilotCard(JsonElement item, bool subscription, params UIElement[] actions)
    {
        var details = Stack(5); details.Children.Add(Muted($"{Json.Text(item, "year")} · {Json.First(item, "type", "media_type")} · 评分 {Json.Number(item, "vote_average", Json.Number(item, "rating")):0.0} · {Json.First(item, "media_source", "source").ToUpperInvariant()} · {MoviePilotPolicies.Identity(item)}"));
        if (subscription)
        {
            var total = Json.Number(item, "total_episode"); var missing = Json.Number(item, "lack_episode"); var downloaded = Math.Max(0, total - missing);
            details.Children.Add(Muted($"{MoviePilotPolicies.State(item)} · 第 {Json.Number(item, "season", 1):0} 季 · 已下载 {downloaded:0} / 总 {total:0} · 缺 {missing:0} 集"));
            details.Children.Add(new ProgressBar { Maximum = Math.Max(1, total), Value = downloaded });
        }
        return Item(item, new UIElement[] { details }.Concat(actions).ToArray());
    }
    private UIElement MoviePilot(string query)
    {
        var page = new Page(); if (Gate(page, false)) return Show(page); var list = Stack(12);
        var search = new TextBox { Header = "MoviePilot", Text = query, PlaceholderText = "搜索媒体并订阅" };
        var category = new ComboBox { Header = "订阅分类", ItemsSource = new[] { "全部", "电影", "剧集" }, SelectedIndex = 0 }; var count = Muted(""); JsonElement[] subscriptions = [];
        void RenderSubscriptions()
        {
            list.Children.Clear(); var movies = subscriptions.Count(MoviePilotPolicies.IsMovie);
            count.Text = $"全部 {subscriptions.Length} · 电影 {movies} · 剧集 {subscriptions.Length - movies} · 追更中 {subscriptions.Count(x => Json.Text(x, "state") == "R")}";
            foreach (var item in subscriptions.Where(x => category.SelectedIndex == 0 || MoviePilotPolicies.IsMovie(x) == (category.SelectedIndex == 1)))
            {
                var id = (long)Json.Number(item, "id");
                list.Children.Add(MoviePilotCard(item, true,
                    Button("找资源", () => navigate(ResourceRoute(item))), page.Action("编辑订阅", () => EditSubscription(page, item, true)),
                    page.Action("在 MoviePilot 刷新", async () => { await Service.Mp("subscription.refresh", null, page.Token); await Load(); }),
                    page.Action("删除订阅", async () => { if (await Confirm(page, "删除订阅", Json.Title(item))) { await Service.Mp("subscription.delete", new { id }, page.Token); await Load(); } })));
            }
            if (list.Children.Count == 0) list.Children.Add(Muted("此分类暂无订阅"));
        }
        async Task Load() { subscriptions = Json.Items(await Service.Mp("subscription.list", null, page.Token)); RenderSubscriptions(); }
        async Task Search()
        {
            if (string.IsNullOrWhiteSpace(search.Text)) { await Load(); return; }
            var items = Json.Items(await Service.Mp("mediaSearch", new { title = search.Text.Trim() }, page.Token));
            subscriptions = Json.Items(await Service.Mp("subscription.list", null, page.Token)); list.Children.Clear();
            foreach (var item in items)
            {
                var subscribed = MoviePilotPolicies.Subscribed(item, subscriptions);
                var edit = page.Action(subscribed ? "已订阅" : "订阅…", () => EditSubscription(page, item, false)); edit.IsEnabled = !subscribed;
                var quick = page.Action("快捷加入订阅", async () => { await Service.Mp("subscription.add", new { subscription = MoviePilotPolicies.NewSubscription(item) }, page.Token); await Search(); }); quick.IsEnabled = !subscribed;
                list.Children.Add(MoviePilotCard(item, false, edit, quick, Button("找资源", () => navigate(ResourceRoute(item)))));
            }
            if (items.Length == 0) list.Children.Add(Muted("没有找到媒体")); count.Text = $"找到 {items.Length} 条媒体";
        }
        category.SelectionChanged += (_, _) => RenderSubscriptions(); Submit(search, page, Search);
        var toolbar = Row(8); toolbar.Children.Add(page.Action("订阅列表", Load)); toolbar.Children.Add(page.Action("新建订阅", () => EditSubscription(page, default, false)));
        toolbar.Children.Add(Button("下载管理", () => navigate("viewing:downloads"))); toolbar.Children.Add(page.Action("刷新追更", async () => { await Service.Mp("subscription.refresh", null, page.Token); await Load(); }));
        toolbar.Children.Add(page.Action("全站追更检索", async () => { await Service.Mp("subscription.search", null, page.Token); await Load(); }));
        page.Body.Children.Add(toolbar); page.Body.Children.Add(category); page.Body.Children.Add(count); page.Body.Children.Add(search); page.Body.Children.Add(page.Action("搜索媒体", Search)); page.Body.Children.Add(list); Reconnect(page);
        return Show(page, query.Length == 0 ? Load : Search);
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

using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed partial class IntegrationPages
{
    private Func<Task>? _dashboardRefresh;
    public Task RefreshDashboard() => _dashboardRefresh?.Invoke() ?? Task.CompletedTask;
    public MenuFlyout ViewingMenu()
    {
        var menu = new MenuFlyout();
        foreach (var (label, glyph, route) in new[] {
            ("Bangumi 章节管理", "\uE8A5", "viewing:bangumi:3"), ("Bangumi 个人主页", "\uE77B", "viewing:profile"),
            ("MoviePilot 资源管理", "\uE7B8", "viewing:moviepilot"), ("数据来源设置", "\uE713", "settings") })
        {
            var item = new MenuFlyoutItem { Text = label, Icon = new FontIcon { Glyph = glyph } };
            item.Click += (_, _) => navigate(route); menu.Items.Add(item);
        }
        return menu;
    }

    public UIElement Dashboard()
    {
        ClearHeader();
        var page = new Page(); page.Body.MaxWidth = 920; page.Body.Spacing = 26;
        if (App.Core is not { } core) { page.Body.Children.Add(DashboardMuted("播放核心不可用，无法加载观影数据。")); return Show(page); }
        var server = core.Server; var source = ViewingHistory.Source(server);
        var hasBangumi = Service.Bangumi is { Enabled: true, AccessToken.Length: > 0 };
        var hasMoviePilot = Service.MoviePilot is { Enabled: true, AccessToken.Length: > 0 };
        var selection = new DashboardSelection(); var lastRefresh = DateTimeOffset.MinValue;
        JsonElement[]? wishes = null, watching = null; double? wishesCount = null; int? watchedCount = null, subscriptionCount = null;

        var identity = Row(12);
        var avatar = DashboardArtwork("", 38, 38, 19, "\uE77B"); identity.Children.Add(avatar);
        void Avatar()
        {
            var url = server?.UserAvatarUrl ?? (hasBangumi ? Service.Bangumi?.Avatar : null);
            if (url is { Length: > 0 } && Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https")
                avatar.Child = Image(Service.RewriteBangumiUrl(url));
        }
        Avatar(); var name = Stack(3); name.VerticalAlignment = VerticalAlignment.Center;
        name.Children.Add(Text(hasBangumi ? Service.Bangumi!.DisplayName : server?.Profile.UserName ?? "观影空间", 17, true));
        name.Children.Add(DashboardMuted(server is null ? "本地播放 · 片单与追更" : $"{server.Profile.UserName} · {server.Profile.DisplayKind} · 片单与追更", 11));
        identity.Children.Add(name); page.Body.Children.Add(identity);

        var calendar = Stack(10); var statistics = Stack(14); var recent = Stack(10); var counters = Stack(10); var resume = Stack(10);
        var subscriptions = Stack(10); var downloads = Stack(10);
        if (hasBangumi) page.Body.Children.Add(DashboardSection("番剧放送", DashboardLink("完整日历", () => navigate("viewing:calendar")), calendar));
        page.Body.Children.Add(DashboardSection("观看记录", DashboardMuted(server?.Profile.DisplayKind ?? "本地播放", 11), statistics));
        page.Body.Children.Add(recent);
        if (hasBangumi || hasMoviePilot) page.Body.Children.Add(counters);
        page.Body.Children.Add(DashboardSection("继续观看", DashboardLink("媒体库", () => navigate("library")), resume));
        if (hasMoviePilot) page.Body.Children.Add(DashboardPair(
            DashboardSection("订阅追更", DashboardLink("MoviePilot", () => navigate("viewing:moviepilot")), subscriptions),
            DashboardSection("下载任务", DashboardLink("MoviePilot", () => navigate("viewing:downloads")), downloads)));
        if (Service.IsEnabled("bangumi") && !hasBangumi) page.Body.Children.Add(DashboardPrompt("连接 Bangumi", "同步片单与章节进度", "settings:Bangumi"));
        if (Service.IsEnabled("moviepilot") && !hasMoviePilot) page.Body.Children.Add(DashboardPrompt("连接 MoviePilot", "管理订阅与下载任务", "settings:MoviePilot"));
        if (server is null) page.Body.Children.Add(DashboardPrompt("连接私人媒体库", "浏览 Jellyfin 或 Emby，接着上次继续看", "settings:连接服务器"));

        void RenderCounters()
        {
            counters.Children.Clear();
            var bgm = DashboardCounter("看过动画", "Bangumi", watchedCount, "\uE73E", "viewing:bangumi:2");
            var mp = DashboardCounter("追更订阅", "MoviePilot", subscriptionCount, "\uE95A", "viewing:moviepilot");
            counters.Children.Add(hasBangumi && hasMoviePilot ? DashboardPair(bgm, mp) : hasBangumi ? bgm : mp);
        }
        void RenderHistory()
        {
            var records = core.ViewingHistory.Entries(source); var archive = core.ViewingHistory.Read(source);
            statistics.Children.Clear(); BuildDashboardStatistics(statistics, records, archive, hasBangumi, wishes, wishesCount, watching, selection);
            recent.Children.Clear();
            var list = Stack(2); list.Children.Add(DashboardHeading("最近观看", DashboardLink($"全部 {records.Length} 条", () => navigate("viewing:history"))));
            foreach (var record in records.Take(3)) list.Children.Add(DashboardHistoryRow(page, record));
            if (records.Length == 0) list.Children.Add(DashboardEmpty("暂无观看记录，播放后会在这里留下足迹。"));
            recent.Children.Add(DashboardCard(list, 10));
            var note = "App 实播记录实际播放时间，暂停、缓冲和跳转不计时；同一条目同一天优先采用实播记录。电影与剧集数量按已看状态统计。";
            if (archive.Undated > 0) note += $" 另有 {archive.Undated} 个已看条目缺少观看日期。";
            recent.Children.Add(DashboardMuted(note, 10));
            var provenance = DashboardMuted($"统计更新：{archive.SyncedAt?.LocalDateTime.ToString("g") ?? "本机实播记录"} · 同步起点：{archive.RecordedFrom.LocalDateTime:yyyy-MM-dd}", 10);
            ToolTipService.SetToolTip(provenance, $"缺失片长 {records.Count(x => x.ActualSeconds is null && x.Media.DurationSeconds <= 0)} 条，不计入估算时长；没有覆盖记录的日期会在热力图中淡化。");
            recent.Children.Add(provenance);
        }
        // Refreshes retain the previous content, including on failure.
        async Task Module(StackPanel target, Func<StackPanel, Task> load)
        {
            if (target.Children.Count == 0) target.Children.Add(DashboardEmpty("正在加载…"));
            var content = Stack(10);
            try { await load(content); page.Token.ThrowIfCancellationRequested(); target.Children.Clear(); target.Children.Add(content); }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                if (page.Token.IsCancellationRequested) return;
                foreach (var old in target.Children.OfType<TextBlock>().Where(x => x.Tag as string == "dashboard-error").ToArray()) target.Children.Remove(old);
                if (target.Children.Count == 1 && target.Children[0] is TextBlock { Text: "正在加载…" }) target.Children.Clear();
                var error = DashboardMuted(ex.Message, 12); error.Tag = "dashboard-error"; target.Children.Add(error);
            }
        }
        async Task History()
        {
            RenderHistory();
            if (server is not null)
            {
                try { await core.ViewingHistory.Synchronize(server, page.Token); page.Token.ThrowIfCancellationRequested(); RenderHistory(); }
                catch (OperationCanceledException) { }
                catch (Exception ex) { if (!page.Token.IsCancellationRequested) statistics.Children.Add(DashboardMuted("本次同步失败，保留已有记录：" + ex.Message, 11)); }
            }
        }
        Task Resume() => Module(resume, async content =>
        {
            var items = server is null ? core.LocalMedia.Where(x => x.Progress is > 0 and < 100).Take(4).ToArray()
                : Json.Items(await server.Request("browse.resume", new { limit = 4 }, page.Token)).Select(server.Project).ToArray();
            var list = Stack(2); foreach (var media in items) list.Children.Add(DashboardMediaRow(page, media));
            if (items.Length == 0) list.Children.Add(DashboardEmpty("暂无续播内容")); content.Children.Add(DashboardCard(list, 8));
        });
        async Task Bangumi(Task<JsonElement[]> watchingTask)
        {
            try
            {
                // 待看只取首屏一页用于封面，计数用 total；看过只需总数，不再拉全部分页。
                var wishTask = Service.CollectionPage(1, 2, 0, page.Token, 30);
                var watchedTask = Service.CollectionTotal(2, 2, page.Token);
                await Task.WhenAll(wishTask, watchingTask, watchedTask); page.Token.ThrowIfCancellationRequested();
                var wishPage = await wishTask; wishes = Json.Items(wishPage); wishesCount = Json.Number(wishPage, "total", wishes.Length);
                watching = await watchingTask; watchedCount = (int)Math.Round(await watchedTask);
                RenderHistory(); RenderCounters();
            }
            catch (OperationCanceledException) { }
            catch (Exception ex) { if (!page.Token.IsCancellationRequested) statistics.Children.Add(DashboardMuted("片单加载失败：" + ex.Message, 11)); }
        }
        Task CalendarLoad(Task<JsonElement[]> watchingTask, bool force) => Module(calendar, async content =>
        {
            BroadcastEntry[] entries = [];
            if (server is not null)
            {
                // 复用观影页已经发起的 Watching 请求，避免同一页拉两次。
                var calendarTask = Service.Calendar(page.Token, force ? TimeSpan.Zero : null);
                var libraryTask = BroadcastTimeline.Library(server, page.Token); var scheduleTask = BroadcastTimeline.Schedule(core.DataDirectory, page.Token);
                await Task.WhenAll(watchingTask, calendarTask, libraryTask, scheduleTask); page.Token.ThrowIfCancellationRequested();
                entries = BroadcastTimeline.Match(await watchingTask, Json.Items(await calendarTask), await libraryTask, await scheduleTask, Service.Links(), source);
            }
            content.Children.Add(DashboardMuted("在看 · 媒体库已有 · 按更新时间排序", 11));
            var week = new Grid { ColumnSpacing = 8 }; var posters = Stack(8); var buttons = new List<Button>();
            var today = ((int)DateTime.Today.DayOfWeek + 6) % 7;
            void Render(int day)
            {
                selection.Weekday = day;
                for (var i = 0; i < buttons.Count; i++) buttons[i].Background = DashboardNeutral(i == day ? 45 : 0);
                posters.Children.Clear(); var row = Row(14);
                foreach (var (entry, time) in BroadcastTimeline.OnDay(entries, DateTime.Today.AddDays(day - today))) row.Children.Add(DashboardBroadcast(entry.Subject, time));
                if (row.Children.Count == 0) posters.Children.Add(DashboardEmpty(server is null ? "连接媒体库，查看在看番剧的更新安排" : "这一天没有在看且媒体库已有的更新番剧"));
                else posters.Children.Add(new HorizontalMediaRail(row, "番剧放送", 34));
            }
            for (var i = 0; i < 7; i++)
            {
                week.ColumnDefinitions.Add(new ColumnDefinition()); var day = i;
                var button = DashboardAction(new[] { "一", "二", "三", "四", "五", "六", "日" }[i], () => Render(day));
                button.Height = 30; button.HorizontalAlignment = HorizontalAlignment.Stretch;
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, "番剧放送 星期" + button.Content);
                Grid.SetColumn(button, i); week.Children.Add(button); buttons.Add(button);
            }
            content.Children.Add(week); content.Children.Add(posters); Render(selection.Weekday);
            var credit = DashboardLink("预计放送时间 · 本地时区 · bangumi-data", () => Browse("https://github.com/bangumi-data/bangumi-data"), false);
            credit.FontSize = 10; ToolTipService.SetToolTip(credit, "没有准确时间时按 Bangumi 星期显示"); content.Children.Add(credit);
        });
        Task Subscriptions() => Module(subscriptions, async content =>
        {
            var items = Json.Items(await Service.Mp("subscription.list", null, page.Token)); page.Token.ThrowIfCancellationRequested();
            subscriptionCount = items.Length; RenderCounters(); var list = Stack(3);
            var known = items.Where(x => Json.Get(x, "lack_episode").ValueKind == JsonValueKind.Number).ToArray();
            list.Children.Add(DashboardMuted($"{items.Length} 部订阅 · " + (known.Length == 0 ? "集数待确认" : $"已知缺 {known.Sum(x => Math.Max(0, Json.Number(x, "lack_episode")))} 集"), 11));
            foreach (var item in items.Take(4)) list.Children.Add(DashboardSubscription(item));
            if (items.Length == 0) list.Children.Add(DashboardEmpty("暂无追更订阅")); content.Children.Add(DashboardCard(list, 10));
        });
        Task DownloadsLoad() => Module(downloads, async content =>
        {
            var items = Json.Items(await Service.Mp("download.list", null, page.Token)); page.Token.ThrowIfCancellationRequested(); var list = Stack(4);
            foreach (var item in items.Take(3)) list.Children.Add(DashboardDownload(item));
            if (items.Length == 0) list.Children.Add(DashboardEmpty("当前没有下载任务")); content.Children.Add(DashboardCard(list, 14));
        });
        async Task Refresh(bool force = false)
        {
            var watch = System.Diagnostics.Stopwatch.StartNew(); lastRefresh = DateTimeOffset.UtcNow;
            if (server is not null) { try { await server.RefreshAvatar(page.Token); Avatar(); } catch (Exception ex) when (ex is not OperationCanceledException) { } }
            var tasks = new List<Task> { History(), Resume() };
            var watchingTask = hasBangumi ? Service.Watching(page.Token, force ? TimeSpan.Zero : null) : null;
            if (hasBangumi && watchingTask is not null) { tasks.Add(Bangumi(watchingTask)); tasks.Add(CalendarLoad(watchingTask, force)); }
            if (hasMoviePilot) { tasks.Add(Subscriptions()); tasks.Add(DownloadsLoad()); }
            await Task.WhenAll(tasks);
            AppDiagnostics.Write("debug", $"观影页刷新完成：{watch.ElapsedMilliseconds} ms（Bangumi={hasBangumi}，媒体库={server is not null}）");
        }
        RenderHistory(); RenderCounters();
        Func<Task> refresh = () => page.Run(() => Refresh(true)); _dashboardRefresh = refresh;
        page.Body.Unloaded += (_, _) => { if (_dashboardRefresh == refresh) _dashboardRefresh = null; };
        page.Poll(TimeSpan.FromSeconds(15), async () => { if (hasMoviePilot) await DownloadsLoad(); });
        page.Poll(TimeSpan.FromMinutes(15), History);
        var historyQueued = false;
        void Changed()
        {
            if (historyQueued || page.Token.IsCancellationRequested) return; historyQueued = true;
            page.Body.DispatcherQueue.TryEnqueue(() => { try { if (IsVisible(page.Body) && IsForeground()) RenderHistory(); } finally { historyQueued = false; } });
        }
        core.ViewingHistory.Changed += Changed; page.Body.Unloaded += (_, _) => core.ViewingHistory.Changed -= Changed;
        var active = IsForeground(); var activation = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        activation.Tick += async (_, _) => { var current = IsForeground() && IsVisible(page.Body); if (current && !active && DateTimeOffset.UtcNow - lastRefresh >= TimeSpan.FromMinutes(10)) await page.Run(() => Refresh(false)); active = current; };
        page.Body.Loaded += (_, _) => activation.Start(); page.Body.Unloaded += (_, _) => activation.Stop();
        return Show(page, () => Refresh(false));
    }
    private sealed class DashboardSelection
    {
        public DateTime Day = DateTime.Today;
        public DateTime Month = new(DateTime.Today.Year, DateTime.Today.Month, 1);
        public int Weekday = ((int)DateTime.Today.DayOfWeek + 6) % 7;
    }
}

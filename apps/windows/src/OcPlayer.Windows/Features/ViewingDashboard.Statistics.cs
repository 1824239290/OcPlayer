using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using OcPlayer.Windows.Services;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed partial class IntegrationPages
{
    private void BuildDashboardStatistics(StackPanel host, ViewingRecord[] records, ViewingArchive archive, bool bangumi,
        JsonElement[]? wishes, JsonElement[]? watching, DashboardSelection selection)
    {
        var left = Stack(14); var right = Stack(14);
        var day = Stack(12);
        void SelectDay(DateTime date)
        {
            selection.Day = date; day.Children.Clear(); var rows = records.Where(x => x.WatchedAt.LocalDateTime.Date == date).ToArray();
            day.Children.Add(DashboardHeading(date == DateTime.Today ? "今天" : "当天观看", DashboardMuted(date.ToString("M月d日"), 10)));
            day.Children.Add(DashboardHours(rows.Sum(x => x.Seconds)));
            day.Children.Add(DashboardCompletion(rows));
            day.Children.Add(DashboardMuted(rows.Length == 0 ? "当天还没有留下观看记录" : $"实播 {rows.Sum(x => x.ActualSeconds ?? 0) / 60:0.#} 分钟 · 估算 {rows.Where(x => x.ActualSeconds is null).Sum(x => x.Seconds) / 60:0.#} 分钟", 10));
        }
        SelectDay(selection.Day); left.Children.Add(DashboardCard(day));
        if (bangumi) left.Children.Add(DashboardPair(DashboardCollection("待看", 1, wishes), DashboardCollection("在看", 3, watching), 0));
        left.Children.Add(DashboardGenres(records)); left.Children.Add(DashboardTrends(records, archive));
        right.Children.Add(DashboardActivity(records, archive, selection.Day, SelectDay));
        right.Children.Add(DashboardMonth(records, archive, selection));
        host.Children.Add(DashboardPair(left, right));
    }
    private static UIElement DashboardHours(double seconds, double size = 32)
    {
        var row = Row(5); row.Children.Add(Text((seconds / 3600).ToString("0.0"), size, true));
        var unit = DashboardMuted("小时", 11); unit.VerticalAlignment = VerticalAlignment.Bottom; unit.Margin = new Thickness(0, 0, 0, 7); row.Children.Add(unit); return row;
    }
    private static UIElement DashboardCompletion(ViewingRecord[] rows)
    {
        var text = $"已看 {rows.Count(x => x.Completed && x.Media.Kind == "movie")} 部电影 · {rows.Count(x => x.Completed && x.Media.Kind == "episode")} 集剧";
        if (rows.Any(x => !x.Completed)) text += $" · {rows.Count(x => !x.Completed)} 段播放";
        return DashboardMuted(text, 10);
    }
    private static UIElement DashboardActivity(ViewingRecord[] records, ViewingArchive archive, DateTime selected, Action<DateTime> select)
    {
        var activity = Stack(12); activity.Children.Add(DashboardHeading("观看活跃度", DashboardMuted("近 15 周", 10)));
        var grid = new Grid { ColumnSpacing = 3, RowSpacing = 3, MaxWidth = 348, HorizontalAlignment = HorizontalAlignment.Stretch };
        for (var i = 0; i < 15; i++) grid.ColumnDefinitions.Add(new ColumnDefinition());
        for (var i = 0; i < 7; i++) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var start = DateTime.Today.AddDays(-((int)DateTime.Today.DayOfWeek + 6) % 7 - 98);
        var daily = records.GroupBy(x => x.WatchedAt.LocalDateTime.Date).ToDictionary(x => x.Key, x => x.Sum(y => y.Seconds));
        var cells = new List<(Button Button, DateTime Date)>();
        for (var week = 0; week < 15; week++) for (var weekday = 0; weekday < 7; weekday++)
        {
            var date = start.AddDays(week * 7 + weekday); var seconds = daily.GetValueOrDefault(date);
            var covered = date <= DateTime.Today && (archive.SyncedAt is not null && date >= archive.RecordedFrom.LocalDateTime.Date || daily.ContainsKey(date));
            var fill = new Border { CornerRadius = new CornerRadius(2), Background = seconds > 0 ? DashboardOrange : DashboardNeutral(covered ? (byte)55 : (byte)22), Opacity = seconds > 0 ? Math.Clamp(seconds / 3600, .35, 1) : 1 };
            var button = DashboardAction("", () =>
            {
                select(date); foreach (var cell in cells) cell.Button.BorderThickness = new Thickness(cell.Date == date ? 1 : 0);
            });
            button.Style = DashboardStyle("DashboardHeatmapButtonStyle");
            button.Content = fill; button.Padding = new Thickness(0); button.Height = 20;
            button.BorderThickness = new Thickness(date == selected ? 1 : 0); button.CornerRadius = new CornerRadius(3);
            button.HorizontalAlignment = HorizontalAlignment.Stretch; button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.VerticalContentAlignment = VerticalAlignment.Stretch; button.IsEnabled = covered;
            var description = date.ToString("yyyy-MM-dd") + (covered ? $" · {seconds / 60:0.#} 分钟" : " · 暂无覆盖记录");
            AutomationProperties.SetName(button, description); ToolTipService.SetToolTip(button, description); cells.Add((button, date));
            Grid.SetColumn(button, week); Grid.SetRow(button, weekday); grid.Children.Add(button);
        }
        grid.SizeChanged += (_, _) => { foreach (var cell in cells) cell.Button.Height = Math.Max(0, (grid.ActualWidth - 42) / 15); };
        activity.Children.Add(grid);
        var footer = new Grid(); footer.ColumnDefinitions.Add(new ColumnDefinition()); footer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        footer.Children.Add(DashboardMuted("点击日期查看当天统计", 10)); var legend = Row(3); legend.Children.Add(DashboardMuted("少", 9));
        foreach (var opacity in new[] { .25, .5, .75, 1 }) legend.Children.Add(new Border { Width = 7, Height = 7, CornerRadius = new CornerRadius(1), Background = DashboardOrange, Opacity = opacity, VerticalAlignment = VerticalAlignment.Center });
        legend.Children.Add(DashboardMuted("多", 9)); Grid.SetColumn(legend, 1); footer.Children.Add(legend); activity.Children.Add(footer); return DashboardCard(activity);
    }
    private UIElement DashboardMonth(ViewingRecord[] records, ViewingArchive archive, DashboardSelection selection)
    {
        var stack = Stack(12); var content = Stack(12); var title = DashboardLabel("", 11);
        var previous = DashboardAction("", () => { });
        var next = DashboardAction("", () => { });
        previous.Content = new FontIcon { Glyph = "\uE76B", FontSize = 10 }; next.Content = new FontIcon { Glyph = "\uE76C", FontSize = 10 };
        previous.Padding = next.Padding = new Thickness(5, 4, 5, 4); title.VerticalAlignment = VerticalAlignment.Center;
        AutomationProperties.SetName(previous, "观看统计 上个月"); AutomationProperties.SetName(next, "观看统计 下个月");
        var toolbar = Row(2); toolbar.Children.Add(previous); toolbar.Children.Add(title); toolbar.Children.Add(next);
        stack.Children.Add(DashboardHeading("本月观看", toolbar)); stack.Children.Add(content);
        var coveredFrom = records.Select(x => x.WatchedAt.LocalDateTime.Date).Append(archive.RecordedFrom.LocalDateTime.Date).Min();
        void Render()
        {
            var month = selection.Month; title.Text = month.ToString("yyyy年M月"); content.Children.Clear();
            previous.IsEnabled = month.AddDays(-1) >= coveredFrom; next.IsEnabled = month.AddMonths(1) <= DateTime.Today;
            var rows = records.Where(x => x.WatchedAt.LocalDateTime >= month && x.WatchedAt.LocalDateTime < month.AddMonths(1)).ToArray();
            content.Children.Add(DashboardHours(rows.Sum(x => x.Seconds), 30)); content.Children.Add(DashboardCompletion(rows));
            var colors = new[] { (Name: "剧集", Color: DashboardOrange), (Name: "电影", Color: (Brush)new SolidColorBrush(Microsoft.UI.Colors.MediumSlateBlue)), (Name: "本地 / 直连", Color: (Brush)new SolidColorBrush(Microsoft.UI.Colors.MediumAquamarine)) };
            var legend = Row(10);
            foreach (var item in colors) { var key = Row(4); key.Children.Add(new Border { Width = 5, Height = 5, CornerRadius = new CornerRadius(2.5), Background = item.Color, VerticalAlignment = VerticalAlignment.Center }); key.Children.Add(DashboardMuted(item.Name, 9)); legend.Children.Add(key); }
            content.Children.Add(legend); content.Children.Add(DashboardMonthChart(rows, month, colors));
            content.Children.Add(DashboardMuted("观看 TOP 3", 10)); var top = ViewingAnalytics.Top(rows);
            foreach (var item in top)
            {
                var grid = new Grid { ColumnSpacing = 8 }; grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition()); grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                var label = DashboardLabel(item.Title, 10); label.VerticalAlignment = VerticalAlignment.Center; grid.Children.Add(label);
                var progress = DashboardProgress(item.Seconds / Math.Max(1, top[0].Seconds) * 100, DashboardOrange, 5); progress.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(progress, 1); grid.Children.Add(progress);
                var value = DashboardMuted($"{item.Seconds / 3600:0.#}h", 10); Grid.SetColumn(value, 2); grid.Children.Add(value); ToolTipService.SetToolTip(grid, item.Title + $" · {item.Seconds / 60:0.#} 分钟"); content.Children.Add(grid);
            }
            if (top.Length == 0) content.Children.Add(DashboardMuted("本月暂无观看记录", 11));
            content.Children.Add(DashboardMuted($"App 实播 {rows.Sum(x => x.ActualSeconds ?? 0) / 60:0.#} 分钟 · 片长估算 {rows.Where(x => x.ActualSeconds is null).Sum(x => x.Seconds) / 60:0.#} 分钟", 9));
            if (archive.RecordedFrom.LocalDateTime > month && archive.RecordedFrom.LocalDateTime < month.AddMonths(1)) content.Children.Add(DashboardMuted($"本月从 {archive.RecordedFrom.LocalDateTime:M月d日} 起同步服务器记录", 9));
        }
        previous.Click += (_, _) => { selection.Month = selection.Month.AddMonths(-1); Render(); };
        next.Click += (_, _) => { selection.Month = selection.Month.AddMonths(1); Render(); };
        Render(); return DashboardCard(stack);
    }
    private static UIElement DashboardMonthChart(ViewingRecord[] rows, DateTime month, (string Name, Brush Color)[] colors)
    {
        var stack = Stack(4); var chart = new Grid { Height = 102, ColumnSpacing = 5 };
        chart.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) }); chart.ColumnDefinitions.Add(new ColumnDefinition());
        var days = DateTime.DaysInMonth(month.Year, month.Month);
        var daily = Enumerable.Range(0, days).Select(i => rows.Where(x => x.WatchedAt.LocalDateTime.Date == month.AddDays(i)).Sum(x => x.Seconds)).ToArray();
        var maxHours = Math.Max(1, Math.Ceiling(daily.Max() / 3600)); var axis = new Grid();
        axis.Children.Add(new TextBlock { Text = maxHours.ToString("0.#"), FontSize = 9, Opacity = .55, VerticalAlignment = VerticalAlignment.Top });
        axis.Children.Add(new TextBlock { Text = "0", FontSize = 9, Opacity = .55, VerticalAlignment = VerticalAlignment.Bottom }); chart.Children.Add(axis);
        var plot = new Grid(); Grid.SetColumn(plot, 1); chart.Children.Add(plot);
        plot.Children.Add(new Border { Height = 1, Background = DashboardNeutral(40), VerticalAlignment = VerticalAlignment.Top });
        plot.Children.Add(new Border { Height = 1, Background = DashboardNeutral(40), VerticalAlignment = VerticalAlignment.Bottom });
        var bars = new Grid { ColumnSpacing = 3 }; plot.Children.Add(bars);
        for (var i = 0; i < days; i++)
        {
            bars.ColumnDefinitions.Add(new ColumnDefinition()); var date = month.AddDays(i); var bar = Stack(0); bar.VerticalAlignment = VerticalAlignment.Bottom;
            foreach (var item in colors)
            {
                var seconds = rows.Where(x => x.WatchedAt.LocalDateTime.Date == date && ViewingAnalytics.Category(x) == item.Name).Sum(x => x.Seconds);
                if (seconds <= 0) continue; bar.Children.Add(new Border { Height = Math.Max(1, seconds / (maxHours * 3600) * 98), Background = item.Color, CornerRadius = new CornerRadius(1.5) });
            }
            ToolTipService.SetToolTip(bar, date.ToString("M月d日") + $" · {daily[i] / 60:0.#} 分钟"); Grid.SetColumn(bar, i); bars.Children.Add(bar);
        }
        stack.Children.Add(chart); var labels = new Grid { Margin = new Thickness(25, 0, 0, 0) };
        labels.Children.Add(new TextBlock { Text = month.ToString("M/1"), FontSize = 9, Opacity = .5, HorizontalAlignment = HorizontalAlignment.Left });
        labels.Children.Add(new TextBlock { Text = month.ToString("M/15"), FontSize = 9, Opacity = .5, HorizontalAlignment = HorizontalAlignment.Center });
        labels.Children.Add(new TextBlock { Text = month.ToString("M/") + days, FontSize = 9, Opacity = .5, HorizontalAlignment = HorizontalAlignment.Right }); stack.Children.Add(labels); return stack;
    }
    private static UIElement DashboardGenres(ViewingRecord[] records)
    {
        var stack = Stack(12); stack.Children.Add(DashboardHeading("类型分布", DashboardMuted("已同步记录", 10)));
        var total = records.Sum(x => x.Seconds); var portions = ViewingAnalytics.Genres(records); var chart = new Grid { ColumnSpacing = 18 };
        chart.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); chart.ColumnDefinitions.Add(new ColumnDefinition());
        var summary = Stack(4); summary.Children.Add(DashboardHours(total, 28)); summary.Children.Add(DashboardMuted($"{records.Length} 条记录", 10)); chart.Children.Add(summary);
        var groups = Stack(8);
        foreach (var genre in portions.Take(2).Concat(portions.Length > 2 ? new[] { (Name: "其余类型", Seconds: portions.Skip(2).Sum(x => x.Seconds)) } : []))
        {
            var group = Stack(4); group.Children.Add(DashboardHeading(genre.Name, DashboardMuted((genre.Seconds / Math.Max(1, total)).ToString("P0"), 10)));
            group.Children.Add(DashboardProgress(genre.Seconds / Math.Max(1, total) * 100, DashboardOrange, 5)); groups.Children.Add(group);
        }
        if (portions.Length == 0) groups.Children.Add(DashboardMuted("暂无类型数据", 11)); Grid.SetColumn(groups, 1); chart.Children.Add(groups); stack.Children.Add(chart);
        if (portions.Length > 2)
        {
            var all = Stack(8); foreach (var item in portions) all.Children.Add(DashboardMuted($"{item.Name} · {item.Seconds / Math.Max(1, total):P1} · {item.Seconds / 3600:0.#} 小时", 12));
            var button = DashboardAction("全部类型", () => { }); button.FontSize = 10; button.Padding = new Thickness(0); button.Flyout = new Flyout { Content = all }; stack.Children.Add(button);
        }
        return DashboardCard(stack);
    }
    private static UIElement DashboardTrends(ViewingRecord[] records, ViewingArchive archive)
    {
        var start = DateTime.Today.AddDays(-6); var recent = records.Where(x => x.WatchedAt.LocalDateTime.Date >= start).ToArray();
        var previous = records.Where(x => x.WatchedAt.LocalDateTime.Date >= start.AddDays(-7) && x.WatchedAt.LocalDateTime.Date < start).ToArray();
        var top = ViewingAnalytics.Genres(recent).Take(2).ToArray(); var stack = Stack(6); stack.Children.Add(DashboardHeading("近期类型趋势", DashboardMuted("近 7 天", 10)));
        if (top.Length == 0) { stack.Children.Add(DashboardEmpty("近 7 天暂无观看记录")); return DashboardCard(stack); }
        var before = ViewingAnalytics.Genres(previous).FirstOrDefault(x => x.Name == top[0].Name).Seconds;
        var delta = top[0].Seconds - before; var coveredFrom = records.Select(x => x.WatchedAt.LocalDateTime.Date).Append(archive.RecordedFrom.LocalDateTime.Date).Min();
        stack.Children.Add(DashboardHeading(top[0].Name, DashboardMuted(coveredFrom > start.AddDays(-7) ? "对比记录不足" : $"{(delta >= 0 ? "+" : "−")}{Math.Abs(delta) / 3600:0.#}h", 10)));
        stack.Children.Add(DashboardMuted($"{top[0].Seconds / 3600:0.#} 小时" + (top.Length > 1 ? $" · {top[1].Name} {top[1].Seconds / 3600:0.#} 小时" : ""), 10));
        var values = top.Select(genre => Enumerable.Range(0, 7).Select(i => ViewingAnalytics.Genres(recent.Where(x => x.WatchedAt.LocalDateTime.Date == start.AddDays(i))).FirstOrDefault(x => x.Name == genre.Name).Seconds).ToArray()).ToArray();
        var max = Math.Max(1, values.SelectMany(x => x).Max()); var graph = new Canvas { Height = 65 };
        var lines = values.Select((_, i) => { var line = new Polyline { Style = DashboardStyle("DashboardTrendLineStyle"), StrokeThickness = 1.5 }; if (i > 0) line.Stroke = DashboardOrange; return line; }).ToArray();
        foreach (var line in lines) graph.Children.Add(line);
        var endpoint = new Ellipse { Style = DashboardStyle("DashboardTrendEndpointStyle"), Width = 5, Height = 5, StrokeThickness = 1.5, Fill = DashboardNeutral(60) }; graph.Children.Add(endpoint);
        graph.SizeChanged += (_, _) =>
        {
            for (var series = 0; series < lines.Length; series++)
            {
                var points = new PointCollection(); for (var i = 0; i < 7; i++) points.Add(new(3 + i * Math.Max(0, graph.ActualWidth - 6) / 6, 3 + (1 - values[series][i] / max) * 58)); lines[series].Points = points;
            }
            Canvas.SetLeft(endpoint, Math.Max(0, graph.ActualWidth - 5.5)); Canvas.SetTop(endpoint, .5 + (1 - values[0][6] / max) * 58);
        };
        ToolTipService.SetToolTip(graph, string.Join("\n", Enumerable.Range(0, 7).Select(i => start.AddDays(i).ToString("M/d") + $" · {values[0][i] / 60:0.#} 分钟")));
        stack.Children.Add(graph); var dates = DashboardHeading(start.ToString("M/d"), DashboardMuted(DateTime.Today.ToString("M/d"), 9)); stack.Children.Add(dates); return DashboardCard(stack);
    }
}

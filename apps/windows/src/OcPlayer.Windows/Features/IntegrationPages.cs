using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed partial class IntegrationPages(PageLayout layout, Action<string> navigate, Action<DemoMedia> open, ViewingIntegrations? integrations = null, Action? activate = null)
{
    private ViewingIntegrations Service => integrations ?? App.Core!.Integrations;
    public FrameworkElement? HeaderLeading { get; private set; }
    public FrameworkElement? HeaderTrailing { get; private set; }
    public string? HeaderTitle { get; private set; }
    public string? HeaderSubtitle { get; private set; }
    public string? HeaderBackdrop { get; private set; }
    public event Action? HeaderChanged;
    private void ClearHeader() { HeaderLeading = HeaderTrailing = null; HeaderTitle = HeaderSubtitle = HeaderBackdrop = null; }
    // Every page owns cancellation. Leaving a page prevents stale results and cancels Core requests.
    private sealed class Page
    {
        public StackPanel Body { get; } = Stack(22);
        public TextBlock Status { get; } = Muted("");
        public CancellationTokenSource Lifetime { get; private set; } = new();
        private readonly SemaphoreSlim _operations = new(1);
        public Page()
        {
            // Detail pages can be retained by the shell while the information face is open.
            // Retire old requests on unload, but let the retained controls work when shown again.
            Body.Loaded += (_, _) => { if (Lifetime.IsCancellationRequested) { Lifetime.Dispose(); Lifetime = new(); } };
        }
        public CancellationToken Token => Lifetime.Token;
        public async Task Run(Func<Task> action, TextBlock? status = null)
        {
            var token = Token; if (token.IsCancellationRequested) return;
            var message = status ?? Status;
            var entered = false;
            try { await _operations.WaitAsync(token); entered = true; message.Text = "正在加载…"; await action(); token.ThrowIfCancellationRequested(); message.Text = ""; }
            catch (OperationCanceledException) { message.Text = ""; }
            catch (Exception ex) { if (!token.IsCancellationRequested) message.Text = ex.Message; }
            finally { if (entered) _operations.Release(); }
        }
        public Button Action(string text, Func<Task> action, TextBlock? status = null)
        {
            var button = Button(text, () => { });
            button.Click += async (_, _) => { button.IsEnabled = false; try { await Run(action, status); } finally { button.IsEnabled = true; } };
            return button;
        }
        public void Poll(TimeSpan interval, Func<Task> action)
        {
            var timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) }; var running = false; var active = false; var last = DateTimeOffset.UtcNow;
            timer.Tick += async (_, _) =>
            {
                var visible = IsVisible(Body) && IsForeground(); var resumed = visible && !active; active = visible;
                if (running || Token.IsCancellationRequested || !visible || !resumed && DateTimeOffset.UtcNow - last < interval) return;
                running = true; last = DateTimeOffset.UtcNow; try { await Run(action); } finally { running = false; }
            };
            Body.Loaded += (_, _) => timer.Start(); Body.Unloaded += (_, _) => timer.Stop();
        }
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
    private static bool IsForeground() { GetWindowThreadProcessId(GetForegroundWindow(), out var process); return process == Environment.ProcessId; }
    private static bool IsVisible(FrameworkElement element)
    {
        if (!element.IsLoaded) return false;
        for (DependencyObject? node = element; node is not null; node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node)) if (node is UIElement { Visibility: Visibility.Collapsed }) return false;
        return true;
    }
    private UIElement Show(Page page, Func<Task>? load = null, Thickness? padding = null)
    {
        if (double.IsPositiveInfinity(page.Body.MaxWidth)) page.Body.MaxWidth = 1000;
        page.Body.HorizontalAlignment = HorizontalAlignment.Stretch;
        page.Body.Children.Add(page.Status);
        var scroll = layout.Scroll(page.Body, padding ?? new Thickness(40, 16, 40, 36));
        var loaded = false;
        scroll.Loaded += async (_, _) => { if (loaded) return; loaded = true; if (load is not null) await page.Run(load); };
        scroll.Unloaded += (_, _) => page.Lifetime.Cancel();
        return scroll;
    }
    private bool Gate(Page page, bool bangumi)
    {
        var account = bangumi ? Service.Bangumi : Service.MoviePilot; var name = bangumi ? "Bangumi" : "MoviePilot";
        if (account is { Enabled: true, AccessToken.Length: > 0 }) return false;
        page.Body.Children.Add(Text(account is null ? "连接 " + name : account.AccessToken.Length == 0 ? name + " 登录已失效" : name + " 已停用", 22, true));
        if (bangumi) page.Body.Children.Add(Muted("请在「设置 → Bangumi → 账号」中管理连接。"));
        else page.Body.Children.Add(Button("前往设置", () => navigate("settings:" + name)));
        return true;
    }
    public UIElement Route(string route)
    {
        ClearHeader();
        var parts = route.Split(':', 3);
        return parts[1] switch
        {
            "bangumi" => Bangumi(parts.Length > 2 ? parts[2] : ""),
            "subject" => Subject(long.Parse(parts[2])),
            "profile" => Profile(),
            "calendar" => Calendar(),
            "downloads" => Downloads(),
            "resources" => Resources(parts.Length > 2 ? Uri.UnescapeDataString(parts[2]) : ""),
            "history" => History(),
            _ => MoviePilot(parts.Length > 2 ? Uri.UnescapeDataString(parts[2]) : "")
        };
    }
    private UIElement Item(JsonElement value, params UIElement[] actions)
    {
        var content = Stack(8); content.Children.Add(Text(Json.Title(value), 16, true));
        var summary = Json.First(value, "summary", "overview", "description");
        if (summary.Length > 0) { var label = Muted(summary); label.MaxLines = 3; content.Children.Add(label); }
        if (actions.Length > 0) {
            var buttons = new ItemsControl { ItemsSource = actions, ItemsPanel = (ItemsPanelTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load("<ItemsPanelTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'><ItemsWrapGrid Orientation='Horizontal'/></ItemsPanelTemplate>") }; content.Children.Add(buttons); }
        var poster = Cover(value);
        if (poster.Length == 0) return Panel(content, new Thickness(18));
        var grid = new Grid { ColumnSpacing = 16 }; grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new ColumnDefinition());
        var image = Image(poster); image.Width = 68; image.Height = 100; image.VerticalAlignment = VerticalAlignment.Top;
        grid.Children.Add(image); Grid.SetColumn(content, 1); grid.Children.Add(content);
        return Panel(grid, new Thickness(18));
    }
    private string Cover(JsonElement item)
    {
        var images = Json.Get(item, "images");
        var source = Json.First(item, "poster_path", "poster", "poster_url");
        if (source.Length == 0 && images.ValueKind == JsonValueKind.Object) source = Json.First(images, "common", "large", "medium", "small");
        if (source.StartsWith('/')) source = "https://image.tmdb.org/t/p/w500" + source;
        if (!Uri.TryCreate(source, UriKind.Absolute, out var uri) || uri.Scheme is not ("https" or "http")) return "";
        return Service.RewriteBangumiUrl(source);
    }
    private async Task<bool> Confirm(Page page, string title, string message)
    {
        var dialog = new ContentDialog { XamlRoot = page.Body.XamlRoot, Title = title, Content = message, PrimaryButtonText = "确定", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close };
        using var registration = page.Token.Register(() => page.Body.DispatcherQueue.TryEnqueue(dialog.Hide));
        var result = await dialog.ShowAsync(); page.Token.ThrowIfCancellationRequested(); return result == ContentDialogResult.Primary;
    }
    private UIElement History()
    {
        var page = new Page(); page.Body.Children.Add(Text("观看记录", 22, true));
        return Show(page, () =>
        {
            var records = App.Core!.ViewingHistory.Entries(ViewingHistory.Source(App.Core.Server));
            foreach (var record in records) page.Body.Children.Add(HistoryRow(record));
            if (records.Length == 0) page.Body.Children.Add(Muted("暂无观看记录"));
            return Task.CompletedTask;
        });
    }
    private UIElement HistoryRow(ViewingRecord record)
    {
        var row = Stack(5); row.Children.Add(Text(record.Media.SeriesTitle ?? record.Media.Title, 15, true));
        if (record.Media.SeriesTitle is { Length: > 0 }) row.Children.Add(Muted(record.Media.Title + " · " + record.Media.EpisodeLabel));
        row.Children.Add(Muted($"{record.WatchedAt.LocalDateTime:g} · {(record.ActualSeconds.HasValue ? "App 实播" : "片长估算")} {record.Seconds / 60:0.#} 分钟 · {(record.Completed ? "已看" : "播放片段")}"));
        var button = Button("", () =>
        {
            if (record.Source == "local")
            {
                var local = App.Core?.LocalMedia.FirstOrDefault(x => x.Id == record.Media.Id);
                if (local is not null) open(local);
            }
            else open(record.Media);
        });
        var grid = new Grid { ColumnSpacing = 12 }; grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); grid.ColumnDefinitions.Add(new ColumnDefinition()); Grid.SetColumn(row, 1); grid.Children.Add(row);
        var picture = new Border { Width = 52, Height = 76 }; grid.Children.Add(picture);
        void Artwork(string url) { if (url.Length == 0) return; var image = Image(url); image.Width = 52; image.Height = 76; picture.Child = image; }
        Artwork(record.Media.Artwork);
        var lifetime = new CancellationTokenSource();
        picture.Loaded += async (_, _) =>
        {
            try
            {
                if (record.Source == "local") Artwork(App.Core?.LocalMedia.FirstOrDefault(x => x.Id == record.Media.Id)?.Artwork ?? "");
                else if (App.Core?.Server is { } server && record.Source == ViewingHistory.Source(server))
                { var item = server.Project(await server.Request("browse.detail", new { itemId = record.Media.Id }, lifetime.Token)); if (!lifetime.IsCancellationRequested) Artwork(item.Artwork); }
            }
            catch (Exception ex) when (ex is OperationCanceledException or InvalidOperationException) { }
        };
        picture.Unloaded += (_, _) => lifetime.Cancel();
        button.Content = grid; button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.HorizontalAlignment = HorizontalAlignment.Stretch;
        button.IsEnabled = record.Source != "local" || App.Core?.LocalMedia.Any(x => x.Id == record.Media.Id) == true; return button;
    }
}

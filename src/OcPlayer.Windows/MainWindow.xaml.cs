using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Input;
using OcPlayer.Windows.Features;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.ViewModels;
using OcPlayer.Windows.Services;
using OcPlayer.CoreAdapter;
using Windows.Graphics;

namespace OcPlayer.Windows;

public sealed partial class MainWindow : Window
{
    private readonly DemoViewModel _model = new();
    private readonly DemoPages _pages;
    private PlayerWindow? _player;
    private string _detailOrigin = "home";
    private bool _navigating;
    private readonly Dictionary<string, UIElement> _cachedPages = [];
    private CancellationTokenSource? _load;
    private long _loadGeneration;
    private bool _closing, _exitReady;
    private ContentDialog? _serverDialog;
    private CancellationTokenSource? _connection;
    private readonly AmbientBackdropController _ambient;
    private readonly global::Windows.UI.ViewManagement.UISettings _uiSettings = new();
    private bool _active = true;

    public MainWindow()
    {
        InitializeComponent();
        Title = App.DemoMode ? "OcPlayer · WinUI Demo" : "OcPlayer";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        if (MicaController.IsSupported()) SystemBackdrop = new MicaBackdrop();
        AppWindow.ResizeClient(new SizeInt32(1130, 670));
        _ambient = new AmbientBackdropController(Ambience, _model);
        Activated += (_, args) => { _active = args.WindowActivationState != WindowActivationState.Deactivated; UpdateAmbientActivity(); };
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) _uiSettings.AnimationsEnabledChanged += AnimationsEnabledChanged;
        Avatar.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", "avatar.jpg")));
        _pages = new DemoPages(_model, Navigate, OpenDetail, Play, SetTheme, ToggleWatched);
        Closed += (_, _) =>
        {
            _load?.Cancel(); _connection?.Cancel(); _player?.Close();
            if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) _uiSettings.AnimationsEnabledChanged -= AnimationsEnabledChanged;
            _ambient.Dispose();
        };
        AppWindow.Closing += async (_, args) =>
        {
            if (_exitReady) return;
            args.Cancel = true; if (_closing) return;
            _closing = true; _load?.Cancel(); _connection?.Cancel(); _serverDialog?.Hide(); ++_loadGeneration; _player?.Close();
            if (App.Core is not null) await App.Core.FinishReports();
            _exitReady = true; Close();
        };
        var route = Environment.GetCommandLineArgs().FirstOrDefault(x => x.StartsWith("--demo-route="))?.Split('=', 2)[1] ?? "home";
        Navigate(route);
        Root.ActualThemeChanged += (_, _) => SetCaptionTheme();
        TitleBar.SizeChanged += (_, _) => UpdateTitleBarRegions();
        MainNavigation.SizeChanged += (_, _) => UpdateTitleBarRegions();
        Root.SizeChanged += (_, _) => UpdateTitleBarRegions();
        SetCaptionTheme();
        if (!App.DemoMode)
        {
            UpdateServerLabel();
            if (App.CoreError is { } error) Notify("无法加载播放核心：" + error);
            var open = Environment.GetCommandLineArgs().FirstOrDefault(x => x.StartsWith("--open="))?[7..];
            Root.Loaded += (_, _) =>
            {
                if (App.Core is null) Notify("无法加载播放核心：" + App.CoreError);
                else if (!string.IsNullOrWhiteSpace(open)) OpenSource(open);
                else if (App.Core.Server is not null) LoadHome();
                else Notify("点击标题栏的「连接服务器」，或进入设置 → 媒体服务器，连接 Jellyfin / Emby。");
            };
        }
    }

    private void Navigate(string route)
    {
        if (_closing) return;
        if (route.StartsWith("season:")) { LoadSeason(route[7..]); return; }
        if (route != _model.Route) { _load?.Cancel(); ++_loadGeneration; }
        if (route is "settings:服务器管理" or "settings:连接服务器") { ConnectServer(); return; }
        if (!App.DemoMode && route == "settings:退出确认") { DisconnectServer(); return; }
        var previous = _model.Route;
        if (PageHost.Children.Count > 0 && previous == "library") _cachedPages["library"] = PageHost.Children[0];
        _navigating = true;
        _model.Route = route;
        var section = route.StartsWith("settings") ? "settings" : route is "library" or "detail" or "detail-info" ? "home" : route;
        MainNavigation.SelectedItem = section switch
        {
            "viewing" => ViewingNavigationItem,
            "settings" => SettingsNavigationItem,
            _ => HomeNavigationItem
        };
        BackButton.Visibility = route is "library" or "detail" or "detail-info" || route.StartsWith("settings:") ? Visibility.Visible : Visibility.Collapsed;
        SortButton.Visibility = route == "library" ? Visibility.Visible : Visibility.Collapsed;
        HeaderActions.Visibility = route is "home" or "library" ? Visibility.Visible : Visibility.Collapsed;
        NavGroup.Visibility = route is "home" or "settings" or "viewing" ? Visibility.Visible : Visibility.Collapsed;
        ServerButton.Visibility = route == "home" ? Visibility.Visible : Visibility.Collapsed;
        _ambient.Update();
        UpdateAmbientActivity();
        GlobalSearch.PlaceholderText = route == "library" ? "搜索本库" : "搜索全部媒体库";
        PageTitle.Text = route.StartsWith("settings:") ? route[9..] : route switch { "home" => "首页", "library" => _model.LibraryName, "detail" or "detail-info" => _model.SelectedMedia.Title, "viewing" => "观影空间", _ => "设置" };
        PageHost.Children.Clear();
        PageHost.Children.Add(route == "library" && previous is "detail" or "detail-info" && _cachedPages.TryGetValue("library",out var library) ? library : route.StartsWith("settings:") ? _pages.SettingsSubpage(route[9..]) : route switch { "library" => _pages.Library(), "detail" => _pages.Detail(), "detail-info" => _pages.DetailInformation(),
            "viewing" => _pages.Viewing(), "settings" => _pages.Settings(), _ => _pages.Home() });
        _navigating = false;
        DispatcherQueue.TryEnqueue(UpdateTitleBarRegions);
        if (!App.DemoMode && route == "library" && previous != "detail" && previous != "detail-info") LoadLibrary();
    }
    private async void OpenDetail(DemoMedia media)
    {
        _detailOrigin = _model.Route;
        if (!App.DemoMode && media.SourceUri is null && App.Core?.Server is { } server)
        {
            var (token, generation) = BeginLoad();
            try { media = await server.Detail(media, token); if (generation != _loadGeneration) return; }
            catch (OperationCanceledException) { return; }
            catch (Exception ex) { Notify("无法加载详情：" + ex.Message); return; }
        }
        if (media.Progress >= 100) _model.Watched.Add(media.Id);
        _model.SelectedMedia = media; _model.SelectedEpisode = media.Episodes?.FirstOrDefault()?.Number ?? 1; Navigate("detail");
    }
    private async void ToggleWatched(DemoMedia media)
    {
        var watched = !_model.Watched.Contains(media.Id);
        var (token, generation) = BeginLoad();
        try
        {
            if (media.SourceUri is null && App.Core?.Server is { } server)
                await server.Request(watched ? "server.markPlayed" : "server.markUnplayed", new { itemId = media.Id }, token);
            else if (App.Core is { } core)
                PlaybackSession.Require(core.Client.Call("progress.save", new { tenantId = "local", itemId = media.Id,
                    positionSeconds = watched ? media.DurationSeconds : 0, durationSeconds = media.DurationSeconds > 0 ? (double?)media.DurationSeconds : null,
                    played = watched, completed = watched }));
            if (_closing || generation != _loadGeneration) return;
            if (watched) _model.Watched.Add(media.Id); else _model.Watched.Remove(media.Id);
            if (_model.SelectedMedia.Id == media.Id) { _model.SelectedMedia = media with { Progress = watched ? 100 : 0 }; Navigate(_model.Route); }
            App.Core?.RefreshProgress();
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { Notify("无法更新观看状态：" + ex.Message); }
    }
    private async void Play(DemoMedia media)
    {
        if (!App.DemoMode && App.Core is null) { Notify(App.CoreError ?? "播放核心不可用。"); return; }
        PlaybackSource? source = null;
        if (!App.DemoMode && media.SourceUri is null && App.Core?.Server is { } server)
        {
            var (token, generation) = BeginLoad();
            try
            {
                if (media.Kind == "series" && media.Episodes is null) media = await server.Detail(media, token);
                source = await server.Resolve(media, _model.SelectedEpisode, token);
                if (generation != _loadGeneration) return;
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex) { Notify("无法获取播放地址：" + ex.Message); return; }
        }
        else if (!App.DemoMode && media.SourceUri is null) { Notify("此条目没有可播放的片源。"); return; }
        if (_player is null)
        {
            _player = new PlayerWindow(media, source);
            _player.Closed += (_, _) => { _player = null; App.Core?.RefreshProgress(); Navigate(_model.Route); };
        }
        else _player.SetMedia(media, source);
        _player.Activate();
    }
    private void SetTheme(bool dark)
    {
        Root.RequestedTheme = dark ? ElementTheme.Dark : ElementTheme.Light;
        SetCaptionTheme();
        DispatcherQueue.TryEnqueue(() => Navigate(_model.Route));
    }
    private void SetCaptionTheme()
    {
        Root.Background = new SolidColorBrush(Controls.AmbientBackdropView.PageColor(_model.DarkTheme));
        Ambience.SetStyle(_model.DarkTheme, _model.Route == "detail-info");
        AppWindow.TitleBar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
        AppWindow.TitleBar.ButtonForegroundColor = Root.ActualTheme == ElementTheme.Dark ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black;
    }
    private void UpdateAmbientActivity() => _ambient.SetActivity(_active && !_closing, _uiSettings.AnimationsEnabled);
    private void AnimationsEnabledChanged(global::Windows.UI.ViewManagement.UISettings sender, object args) => DispatcherQueue.TryEnqueue(UpdateAmbientActivity);
    private void Notify(string message) { if (_closing) return; Notice.Visibility = Visibility.Visible; Notice.Message = message; Notice.IsOpen = true; }
    private void MainNavigation_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (!_navigating && args.SelectedItem is NavigationViewItem { Tag: string route }) Navigate(route);
    }
    private void GlobalSearch_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs args)
    {
        if (args.Key != global::Windows.System.VirtualKey.Enter) return;
        _model.Query = GlobalSearch.Text;
        _model.LibraryName = "全部媒体库";
        _model.LibraryId = null;
        Navigate("library");
        args.Handled = true;
    }
    private void Refresh_Click(object sender, RoutedEventArgs e) { if (App.Core?.Server is not null) LoadHome(); else { App.Core?.RefreshProgress(); Navigate(_model.Route); } if (App.DemoMode) Notify("示例片库已刷新。当前是离线前端演示。"); }
    private void UpdateTitleBarRegions()
    {
        var scale = Root.XamlRoot?.RasterizationScale ?? 1;
        RectInt32 Bounds(FrameworkElement element)
        {
            var point = element.TransformToVisual(Root).TransformPoint(new global::Windows.Foundation.Point());
            return new RectInt32((int)(point.X * scale), (int)(point.Y * scale), (int)(element.ActualWidth * scale), (int)(element.ActualHeight * scale));
        }
        var regions = new FrameworkElement[] { NavGroup, BackButton, SortButton, ServerButton, HeaderActions }.Where(x => x.Visibility == Visibility.Visible && x.ActualWidth > 0).Select(Bounds).ToArray();
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough, regions);
    }
    private void Back_Click(object sender, RoutedEventArgs e) => Navigate(_model.Route is "detail" or "detail-info" ? _detailOrigin : _model.Route.StartsWith("settings:") ? "settings" : "home");
    private void GlobalSearch_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_navigating || _model.Route != "library") return;
        _model.Query = GlobalSearch.Text;
        if (App.Core?.Server is not null) { LoadLibrary(); return; }
        PageHost.Children.Clear(); PageHost.Children.Add(_pages.Library());
    }
    private void Sort_Click(object sender, RoutedEventArgs e)
    {
        var menu = new MenuFlyout();
        foreach (var value in new[] { "推荐顺序", "名称", "年份" })
        {
            var item = new ToggleMenuFlyoutItem { Text = value == "推荐顺序" ? "最近添加" : value, IsChecked = _model.Sort == value };
            item.Click += (_, _) => { _model.Sort = value; Navigate("library"); }; menu.Items.Add(item);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        foreach (var value in new[] { "全部状态", "继续观看", "未观看" })
        {
            var item = new ToggleMenuFlyoutItem { Text = value, IsChecked = _model.WatchState == value };
            item.Click += (_, _) => { _model.WatchState = value; Navigate("library"); }; menu.Items.Add(item);
        }
        menu.ShowAt(SortButton);
    }
    private async void OpenFile_Click(object sender, RoutedEventArgs e)
    {
        var picker = new global::Windows.Storage.Pickers.FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        foreach (var extension in new[] { ".mkv", ".mp4", ".mov", ".avi", ".webm" }) picker.FileTypeFilter.Add(extension);
        try
        {
            var file = await picker.PickSingleFileAsync();
            if (file is not null)
                OpenSource(file.Path);
        }
        catch (Exception ex) { Notify("无法打开文件选择器：" + ex.Message); }
    }
    private async void OpenLink_Click(object sender, RoutedEventArgs e)
    {
        var input = new TextBox { PlaceholderText = "https://…", MinWidth = 340 };
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "打开直连链接", Content = input,
            PrimaryButtonText = "打开", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Primary, RequestedTheme = Root.RequestedTheme };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        if (Uri.TryCreate(input.Text, UriKind.Absolute, out var uri) && uri.Scheme is "https" or "http")
            OpenSource(uri.AbsoluteUri);
        else Notify("请输入有效的 HTTP 或 HTTPS 链接。");
    }
    private void Server_Click(object sender, RoutedEventArgs e) => ConnectServer();
    private void UpdateServerLabel()
    {
        AccountLabel.Text = App.Core?.Server is { } server
            ? $"{server.Profile.UserName ?? server.Profile.DisplayName} · {server.Profile.DisplayKind} {server.Profile.ServerVersion}"
            : "连接服务器 · Jellyfin / Emby";
        ToolTipService.SetToolTip(ServerButton, App.Core?.Server?.Profile.BaseUrl ?? "连接或管理媒体服务器");
    }
    private (CancellationToken Token, long Generation) BeginLoad()
    {
        _load?.Cancel(); _load?.Dispose(); _load = new CancellationTokenSource(); return (_load.Token, ++_loadGeneration);
    }
    private async void LoadHome()
    {
        if (App.Core?.Server is not { } server) return;
        var (token, generation) = BeginLoad();
        try { await server.Refresh(token); if (generation != _loadGeneration) return; _model.ServerItems = server.Latest; _cachedPages.Clear(); UpdateServerLabel(); Navigate(_model.Route); _ambient.Update(true); if (server.HomeWarning is { } warning) Notify(warning); }
        catch (OperationCanceledException) { }
        catch (Exception ex) { Notify("刷新失败：" + ex.Message); }
    }
    private async void LoadLibrary()
    {
        if (App.Core?.Server is not { } server) return;
        var (token, generation) = BeginLoad();
        try
        {
            await Task.Delay(300, token);
            var items = await server.Browse(_model.LibraryId, _model.Query, _model.Sort, _model.WatchState, token);
            if (generation != _loadGeneration || _model.Route != "library") return;
            _model.ServerItems = items; PageHost.Children.Clear(); PageHost.Children.Add(_pages.Library());
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { Notify("加载媒体库失败：" + ex.Message); }
    }
    private async void LoadSeason(string seasonId)
    {
        if (App.Core?.Server is not { } server) return;
        var (token, generation) = BeginLoad();
        try
        {
            var media = await server.Detail(_model.SelectedMedia, token, seasonId);
            if (generation != _loadGeneration) return;
            _model.SelectedMedia = media; _model.SelectedEpisode = media.Episodes?.FirstOrDefault()?.Number ?? 1; Navigate(_model.Route);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { Notify("加载分季失败：" + ex.Message); }
    }
    private async void ConnectServer()
    {
        if (_serverDialog is not null || _closing) return;
        CoreRuntime core;
        try { core = App.EnsureCore(); }
        catch (Exception ex) { Notify("无法加载播放核心：" + ex.Message); return; }
        var fields = new StackPanel { Spacing = 12, MinWidth = 360 };
        var address = new TextBox { Header = "服务器地址", PlaceholderText = "http://192.168.1.100:8096", Text = core.Server?.Profile.BaseUrl ?? "" };
        var hint = new TextBlock { Text = "支持 IP、域名和反向代理路径；省略协议时使用 http://。", FontSize = 11, Opacity = .65, TextWrapping = TextWrapping.Wrap };
        var kind = new ComboBox { Header = "类型", ItemsSource = new[] { "Jellyfin", "Emby" }, SelectedIndex = core.Server?.Profile.Kind == "emby" ? 1 : 0, HorizontalAlignment = HorizontalAlignment.Stretch };
        var username = new TextBox { Header = "用户名", Text = core.Server?.Profile.UserName ?? "" }; var password = new PasswordBox { Header = "密码" };
        foreach (var field in new UIElement[] { address, kind, username, password }) fields.Children.Add(field);
        fields.Children.Insert(1, hint);
        var progress = new ProgressBar { IsIndeterminate = true, Visibility = Visibility.Collapsed };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12 };
        var error = new InfoBar { IsClosable = false, Severity = InfoBarSeverity.Error, Visibility = Visibility.Collapsed };
        fields.Children.Add(progress); fields.Children.Add(status); fields.Children.Add(error);
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "连接媒体服务器", Content = new ScrollViewer { Content = fields, VerticalScrollBarVisibility = ScrollBarVisibility.Auto }, PrimaryButtonText = "连接", CloseButtonText = "取消", SecondaryButtonText = core.Server is null || App.DemoMode ? "" : "断开连接", DefaultButton = ContentDialogButton.Primary, RequestedTheme = Root.RequestedTheme };
        _serverDialog = dialog;
        var open = true;
        void Busy(bool value)
        {
            foreach (var input in new Control[] { address, kind, username, password }) input.IsEnabled = !value;
            dialog.IsPrimaryButtonEnabled = dialog.IsSecondaryButtonEnabled = !value;
            progress.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
        }
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true;
            if (_connection is not null) return;
            error.IsOpen = false; error.Visibility = Visibility.Collapsed;
            using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(45));
            _connection = cancellation; Busy(true);
            try
            {
                var server = await MediaServer.Connect(core.Client, address.Text, kind.SelectedIndex == 0 ? "jellyfin" : "emby", username.Text, password.Password,
                    cancellation.Token, message => status.Text = message);
                cancellation.Token.ThrowIfCancellationRequested();
                if (!open || _closing) return;
                status.Text = "正在保存连接…";
                core.SetServer(server);
                _load?.Cancel(); ++_loadGeneration; _player?.Close();
                App.LeaveDemo(); Title = "OcPlayer";
                _model.LibraryId = null; _model.LibraryName = "全部媒体库"; _model.ServerItems = server.Latest;
                _model.Query = ""; GlobalSearch.Text = ""; _model.Watched.Clear(); _cachedPages.Clear();
                _model.BangumiEnabled = _model.MoviePilotEnabled = false;
                UpdateServerLabel(); Navigate("home");
                Notify($"已连接 {server.Profile.DisplayName}，读取到 {server.Libraries.Count} 个媒体库。" + (server.HomeWarning is { } warning ? " " + warning : ""));
                password.Password = ""; dialog.Hide();
            }
            catch (OperationCanceledException)
            {
                if (open && !_closing) { error.Message = "连接超时，请检查地址和网络后重试。"; error.Visibility = Visibility.Visible; error.IsOpen = true; }
            }
            catch (Exception ex)
            {
                if (open && !_closing) { error.Message = ex.Message; error.Visibility = Visibility.Visible; error.IsOpen = true; }
            }
            finally
            {
                _connection = null;
                if (open) { Busy(false); status.Text = ""; }
            }
        };
        dialog.Closing += (_, _) => { open = false; _connection?.Cancel(); password.Password = ""; };
        try
        {
            if (await dialog.ShowAsync() == ContentDialogResult.Secondary) DisconnectServer();
        }
        catch (Exception ex) { Notify("无法打开连接窗口：" + ex.Message); }
        finally { _serverDialog = null; }
    }
    private void DisconnectServer()
    {
        try
        {
            App.Core?.DisconnectServer(); BeginLoad(); _player?.Close(); _model.LibraryId = null; _model.ServerItems = null; _model.Watched.Clear(); _cachedPages.Clear(); UpdateServerLabel(); Navigate("home"); Notify("已断开服务器连接。可以连接其它服务器，或打开本地文件。");
        }
        catch (Exception ex) { Notify("断开连接失败：" + ex.Message); }
    }
    private void OpenSource(string source)
    {
        try
        {
            if (App.DemoMode) { Play(DemoCatalog.Movies[0] with { Title = Path.GetFileNameWithoutExtension(source), Progress = 0 }); return; }
            var remote = Uri.TryCreate(source, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https";
            if (!remote && !File.Exists(source)) throw new FileNotFoundException("文件不存在", source);
            source = remote ? uri!.AbsoluteUri : Path.GetFullPath(source);
            var id = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(source)));
            var title = remote ? Path.GetFileName(Uri.UnescapeDataString(uri!.AbsolutePath)) : Path.GetFileNameWithoutExtension(source);
            var media = new DemoMedia(id, string.IsNullOrWhiteSpace(title) ? "直连媒体" : title, "", "", remote ? "网络媒体" : "本地文件", "", "", DurationSeconds: 0, SourceUri: source);
            App.Core?.Remember(media);
            Play(media);
        }
        catch (Exception ex) { Notify("无法打开媒体：" + ex.Message); }
    }
}

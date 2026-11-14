using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Input;
using OcPlayer.Windows.Features;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.ViewModels;
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

    public MainWindow()
    {
        InitializeComponent();
        Title = "OcPlayer · WinUI Demo";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        if (MicaController.IsSupported()) SystemBackdrop = new MicaBackdrop();
        AppWindow.ResizeClient(new SizeInt32(1130, 670));
        Ambience.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", "mac-ambience.jpg")));
        Avatar.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", "avatar.jpg")));
        _pages = new DemoPages(_model, Navigate, OpenDetail, Play, SetTheme);
        Closed += (_, _) => _player?.Close();
        var route = Environment.GetCommandLineArgs().FirstOrDefault(x => x.StartsWith("--demo-route="))?.Split('=', 2)[1] ?? "home";
        Navigate(route);
        Root.ActualThemeChanged += (_, _) => SetCaptionTheme();
        TitleBar.SizeChanged += (_, _) => UpdateTitleBarRegions();
        Root.SizeChanged += (_, _) => UpdateTitleBarRegions();
        SetCaptionTheme();
    }

    private void Navigate(string route)
    {
        var previous = _model.Route;
        if (PageHost.Children.Count > 0 && previous == "library") _cachedPages["library"] = PageHost.Children[0];
        _navigating = true;
        _model.Route = route;
        var section = route.StartsWith("settings") ? "settings" : route is "library" or "detail" or "detail-info" ? "home" : route;
        foreach (var button in new[] { HomeButton, ViewingButton, SettingsButton })
        {
            var selected = (string)button.Tag == section;
            button.Opacity = selected ? 1 : .55;
            button.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        }
        BackButton.Visibility = route is "library" or "detail" or "detail-info" || route.StartsWith("settings:") ? Visibility.Visible : Visibility.Collapsed;
        SortButton.Visibility = route == "library" ? Visibility.Visible : Visibility.Collapsed;
        HeaderActions.Visibility = route is "home" or "library" ? Visibility.Visible : Visibility.Collapsed;
        NavGroup.Visibility = route is "home" or "settings" or "viewing" ? Visibility.Visible : Visibility.Collapsed;
        AccountLabel.Visibility = route == "home" ? Visibility.Visible : Visibility.Collapsed;
        Ambience.Visibility = Visibility.Visible;
        Ambience.Source = new BitmapImage(new Uri(route is "detail" or "detail-info" ? _model.SelectedMedia.DetailBackdrop : Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", "mac-ambience.jpg")));
        AmbienceTint.Visibility = route is "detail" or "detail-info" ? Visibility.Collapsed : Visibility.Visible;
        DetailTitleTint.Visibility = route is "detail" or "detail-info" ? Visibility.Visible : Visibility.Collapsed;
        GlobalSearch.PlaceholderText = route == "library" ? "搜索本库" : "搜索全部媒体库";
        PageTitle.Text = route.StartsWith("settings:") ? route[9..] : route switch { "home" => "首页", "library" => _model.LibraryName, "detail" or "detail-info" => _model.SelectedMedia.Title, "viewing" => "观影空间", _ => "设置" };
        PageHost.Children.Clear();
        PageHost.Children.Add(route == "library" && previous is "detail" or "detail-info" && _cachedPages.TryGetValue("library",out var library) ? library : route.StartsWith("settings:") ? _pages.SettingsSubpage(route[9..]) : route switch { "library" => _pages.Library(), "detail" => _pages.Detail(), "detail-info" => _pages.DetailInformation(),
            "viewing" => _pages.Viewing(), "settings" => _pages.Settings(), _ => _pages.Home() });
        _navigating = false;
        DispatcherQueue.TryEnqueue(UpdateTitleBarRegions);
    }
    private void OpenDetail(DemoMedia media) { _detailOrigin = _model.Route; _model.SelectedMedia = media; _model.SelectedEpisode = 1; Navigate("detail"); }
    private void Play(DemoMedia media)
    {
        if (_player is null)
        {
            _player = new PlayerWindow(media);
            _player.Closed += (_, _) => _player = null;
        }
        else _player.SetMedia(media);
        _player.Activate();
    }
    private void SetTheme(bool dark)
    {
        Root.RequestedTheme = dark ? ElementTheme.Dark : ElementTheme.Light;
        DispatcherQueue.TryEnqueue(() => Navigate(_model.Route));
    }
    private void SetCaptionTheme()
    {
        Root.Background = new SolidColorBrush(_model.DarkTheme ? global::Windows.UI.Color.FromArgb(255, 32, 34, 33) : global::Windows.UI.Color.FromArgb(255, 228, 225, 221));
        AmbienceTint.Background = new SolidColorBrush(_model.DarkTheme ? global::Windows.UI.Color.FromArgb(10, 0, 0, 0) : global::Windows.UI.Color.FromArgb(185, 245, 242, 236));
        AppWindow.TitleBar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
        AppWindow.TitleBar.ButtonForegroundColor = Root.ActualTheme == ElementTheme.Dark ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black;
    }
    private void Notify(string message) { Notice.Visibility = Visibility.Visible; Notice.Message = message; Notice.IsOpen = true; }
    private void Section_Click(object sender, RoutedEventArgs e) => Navigate((string)((Button)sender).Tag);
    private void GlobalSearch_KeyDown(object sender, Microsoft.UI.Xaml.Input.KeyRoutedEventArgs args)
    {
        if (args.Key != global::Windows.System.VirtualKey.Enter) return;
        _model.Query = GlobalSearch.Text;
        _model.LibraryName = "全部媒体库";
        Navigate("library");
        args.Handled = true;
    }
    private void Refresh_Click(object sender, RoutedEventArgs e) { Navigate(_model.Route); Notify("示例片库已刷新。当前是离线前端演示。"); }
    private void UpdateTitleBarRegions()
    {
        var scale = Root.XamlRoot?.RasterizationScale ?? 1;
        RectInt32 Bounds(FrameworkElement element)
        {
            var point = element.TransformToVisual(Root).TransformPoint(new global::Windows.Foundation.Point());
            return new RectInt32((int)(point.X * scale), (int)(point.Y * scale), (int)(element.ActualWidth * scale), (int)(element.ActualHeight * scale));
        }
        var regions = new FrameworkElement[] { HomeButton, ViewingButton, SettingsButton, BackButton, SortButton, HeaderActions }.Where(x => x.Visibility == Visibility.Visible && x.ActualWidth > 0).Select(Bounds).ToArray();
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough, regions);
    }
    private void Back_Click(object sender, RoutedEventArgs e) => Navigate(_model.Route is "detail" or "detail-info" ? _detailOrigin : _model.Route.StartsWith("settings:") ? "settings" : "home");
    private void GlobalSearch_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_navigating || _model.Route != "library") return;
        _model.Query = GlobalSearch.Text;
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
                Play(DemoCatalog.Movies[0] with { Title = file.DisplayName + " · 界面演示", Progress = 0 });
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
            Play(DemoCatalog.Movies[0] with { Title = "直连链接 · 界面演示", Progress = 0 });
        else Notify("请输入有效的 HTTP 或 HTTPS 链接。");
    }
    private void Server_Click(object sender, RoutedEventArgs e) => Notify("当前是离线演示片库。服务器切换将在 Core 接入阶段启用。");
}

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

    public MainWindow()
    {
        InitializeComponent();
        Title = "OcPlayer · WinUI Demo";
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBar);
        if (MicaController.IsSupported()) SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new SizeInt32(1130, 700));
        Ambience.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", "ambience.jpg")));
        Avatar.Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", "avatar.jpg")));
        _pages = new DemoPages(_model, Navigate, OpenDetail, Play, SetTheme, Notify);
        Closed += (_, _) => _player?.Close();
        Navigate("home");
        Root.ActualThemeChanged += (_, _) => SetCaptionTheme();
        TitleBar.SizeChanged += (_, _) => UpdateTitleBarRegions();
        Root.SizeChanged += (_, _) => HeaderActions.Visibility = Root.ActualWidth < 820 ? Visibility.Collapsed : Visibility.Visible;
        SetCaptionTheme();
    }

    private void Navigate(string route)
    {
        _model.Route = route;
        var section = route is "library" or "detail" ? "home" : route;
        foreach (var button in new[] { HomeButton, ViewingButton, SettingsButton })
        {
            var selected = (string)button.Tag == section;
            button.Opacity = selected ? 1 : .55;
            button.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
        }
        PageTitle.Text = route switch { "home" => "首页", "library" => _model.LibraryName, "detail" => _model.SelectedMedia.Title, "viewing" => "观影空间", _ => "设置" };
        PageHost.Children.Clear();
        PageHost.Children.Add(route switch { "library" => _pages.Library(), "detail" => _pages.Detail(),
            "viewing" => _pages.Viewing(), "settings" => _pages.Settings(), _ => _pages.Home() });
    }
    private void OpenDetail(DemoMedia media) { _model.SelectedMedia = media; Navigate("detail"); }
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
        Root.Background = new SolidColorBrush(_model.DarkTheme ? global::Windows.UI.Color.FromArgb(255, 117, 117, 117) : global::Windows.UI.Color.FromArgb(255, 228, 225, 221));
        AmbienceTint.Background = new SolidColorBrush(_model.DarkTheme ? global::Windows.UI.Color.FromArgb(25, 80, 81, 85) : global::Windows.UI.Color.FromArgb(185, 245, 242, 236));
        AppWindow.TitleBar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
        AppWindow.TitleBar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
        AppWindow.TitleBar.ButtonForegroundColor = Root.ActualTheme == ElementTheme.Dark ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black;
    }
    private void Notify(string message) { Notice.Message = message; Notice.IsOpen = true; }
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
        var regions = new[] { Bounds(HomeButton), Bounds(ViewingButton), Bounds(SettingsButton), Bounds(HeaderActions) };
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough, regions);
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

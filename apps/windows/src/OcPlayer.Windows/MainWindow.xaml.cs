using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using OcPlayer.Windows.Features;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.ViewModels;
using OcPlayer.Windows.Services;
using OcPlayer.CoreAdapter;
using Windows.Graphics;
using Windows.Graphics.Imaging;
using System.Runtime.InteropServices.WindowsRuntime;

namespace OcPlayer.Windows;

public sealed partial class MainWindow : Window
{
    private readonly DemoViewModel _model = new();
    private readonly DemoPages _pages;
    private readonly IntegrationPages _integrationPages;
    private readonly PageLayout _pageLayout = new();
    private PlayerView? _player;
    private Control? _focusBeforePlayback;
    private AppWindowPresenter? _presenterBeforePlayback;
    private string _detailOrigin = "home";
    private readonly Dictionary<string, string> _moviePilotOrigins = [];
    private string? _detailPageMediaId;
    private int _detailPageEpisode;
    private readonly Dictionary<string, (UIElement Page, int Episode)> _cachedDetailPages = [];
    private bool _navigating;
    private readonly Dictionary<string, UIElement> _cachedPages = [];
    private CancellationTokenSource? _load;
    private long _loadGeneration;
    private bool _closing, _exitReady;
    private bool _localPlayerMode;
    private readonly AmbientBackdropController _ambient;
    private readonly PageTransitionController _transitions;
    private readonly global::Windows.UI.ViewManagement.UISettings _uiSettings = new();
    private bool _active = true;
    private string _searchSource = "library";
    private BitmapImage _avatarColor = new(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", "avatar-nav.png"))) { DecodePixelWidth = 54 };
    private WriteableBitmap? _avatarGray;
    private CancellationTokenSource? _avatarLoad;

    public MainWindow()
    {
        InitializeComponent();
        InitializeBrowserParity();
        Title = App.DemoMode ? "OcPlayer · WinUI Demo" : "OcPlayer";
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Branding", "OcPlayer.ico"));
        ExtendsContentIntoTitleBar = true;
        if (AppWindowTitleBar.IsCustomizationSupported())
            AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        SetTitleBar(TitleBar);
        if (MicaController.IsSupported()) SystemBackdrop = new MicaBackdrop();
        AppWindow.ResizeClient(new SizeInt32(1130, 670));
        _ambient = new AmbientBackdropController(Ambience, _model);
        _transitions = new PageTransitionController(PageHost);
        Activated += (_, args) => { _active = args.WindowActivationState != WindowActivationState.Deactivated; UpdateAmbientActivity(); };
        if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) _uiSettings.AnimationsEnabledChanged += AnimationsEnabledChanged;
        Avatar.Source = _avatarColor;
        Root.Loaded += async (_, _) =>
        {
            if (Root.XamlRoot is { } xamlRoot) xamlRoot.Changed += (_, _) => UpdateTitleBarRegions();
            UpdateTitleBarRegions();
            await LoadNavigationAvatar();
        };
        _pages = new DemoPages(_model, _pageLayout, Navigate, OpenDetail, Play, SetTheme, ToggleWatched, SetEpisodeWatched,
            () => LoadLibrary(true), () => LoadLibrary(), () => LoadHome(), () => Navigate("settings:首页栏目"), () => LoadSeason(_model.PendingSeasonId ?? _model.SelectedMedia.SelectedSeasonId ?? ""));
        _integrationPages = new IntegrationPages(_pageLayout, Navigate, OpenDetail, activate: Activate);
        _integrationPages.HeaderChanged += () => { if (_model.Route.StartsWith("viewing:")) ApplyIntegrationHeader(); };
        Closed += (_, _) =>
        {
            _closing = true;
            Root.ActualThemeChanged -= Root_ActualThemeChanged;
            _load?.Cancel(); DismissPlayer(false);
            if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041)) _uiSettings.AnimationsEnabledChanged -= AnimationsEnabledChanged;
            _ambient.Dispose();
            _transitions.Dispose();
        };
        AppWindow.Closing += async (_, args) =>
        {
            if (_exitReady) return;
            args.Cancel = true; if (_closing) return;
            _closing = true; _load?.Cancel(); ++_loadGeneration; DismissPlayer(false);
            if (App.Core is not null) await App.Core.FinishReports();
            _exitReady = true; Close();
        };
        var route = Environment.GetCommandLineArgs().FirstOrDefault(x => x.StartsWith("--demo-route="))?.Split('=', 2)[1] ?? "home";
        Navigate(route == "player" ? "home" : route);
        if (route == "player") Root.Loaded += (_, _) => PresentPlayer(DemoCatalog.All[4] with { Progress = 12 });
        Root.ActualThemeChanged += Root_ActualThemeChanged;
        TitleBar.SizeChanged += (_, _) => UpdateTitleBarRegions();
        BackButton.SizeChanged += (_, _) => UpdateTitleBarRegions();
        MainNavigation.SizeChanged += (_, _) => UpdateTitleBarRegions();
        Root.SizeChanged += (_, _) => UpdateTitleBarRegions();
        AppWindow.Changed += (_, args) =>
        {
            if (args.DidSizeChange || args.DidPresenterChange)
                DispatcherQueue.TryEnqueue(UpdateTitleBarRegions);
        };
        SetCaptionTheme();
#if DEBUG
        AttachPlayerVerification();
        AttachBrowsingVerification();
        AttachDetailTransitionVerification();
#endif
        if (!App.DemoMode)
        {
            UpdateServerLabel();
            if (App.CoreError is { } error) Notify("无法加载播放核心：" + error);
            var open = Environment.GetCommandLineArgs().FirstOrDefault(x => x.StartsWith("--open="))?[7..]
                ?? Environment.GetCommandLineArgs().Skip(1).FirstOrDefault(x => !x.StartsWith('-') && (File.Exists(x) || Uri.TryCreate(x, UriKind.Absolute, out var u) && u.Scheme is "http" or "https" or "file"));
            Root.Loaded += (_, _) =>
            {
                if (App.Core is null) Notify("无法加载播放核心：" + App.CoreError);
                else if (!string.IsNullOrWhiteSpace(open)) OpenSource(open);
                else if (App.Core.Server is not null) LoadHome();
                else if (_localPlayerMode) Notify("点击标题栏的「打开文件」，选择本地视频开始播放。");
            };
        }
    }

    private void Navigate(string route)
    {
        if (_closing) return;
        var changedDetail = _detailPageMediaId != _model.SelectedMedia.Id;
        if (_transitions.IsTransitioning && (_model.Route is "detail" or "detail-info")
            && (route is "detail" or "detail-info") && route != _model.Route && !changedDetail) return;
        if (route.StartsWith("genre:"))
        {
            _model.Category = route[6..]; _model.Query = "";
            _model.LibraryId = null; _model.LibraryName = _model.Category;
            _cachedPages.Remove("library");
            Navigate("library");
            if (!App.DemoMode) LoadLibrary();
            return;
        }
        if (route.StartsWith("season:")) { LoadSeason(route[7..]); return; }
        if (route != _model.Route) { _load?.Cancel(); ++_loadGeneration; _model.LibraryLoading = false; _model.HomeLoading = false; _model.EpisodesLoading = false; }
        if (route == "detail:retry") { OpenDetail(_model.SelectedMedia); return; }
        if (!App.DemoMode && route == "settings:退出确认") { DisconnectServer(); return; }
        var previous = _model.Route;
        var serverConnectionPage = !App.DemoMode && App.Core is not null && (route == "settings:连接服务器"
            || route == "home" && App.Core.Server is null && _model.Catalog.Count == 0 && !_localPlayerMode);
        var restoreNavigationFocus = BackButton.FocusState != FocusState.Unfocused;
        if (_transitions.Content is { } current)
        {
            if (previous == "library") _cachedPages["library"] = current;
            if (!changedDetail && previous != route && (previous is "detail" or "detail-info")) _cachedDetailPages[previous] = (current, _detailPageEpisode);
        }
        if (changedDetail || previous == route && (route is "detail" or "detail-info")) ClearDetailPages();
        _detailPageMediaId = _model.SelectedMedia.Id;
        _navigating = true;
        if (previous != route && (route.StartsWith("viewing:resources") || route == "viewing:downloads") && _moviePilotOrigins.GetValueOrDefault(previous) != route) _moviePilotOrigins[route] = previous;
        _model.Route = route;
        var section = route.StartsWith("settings") ? "settings" : route.StartsWith("viewing") ? "viewing" : route is "library" or "detail" or "detail-info" ? "home" : route;
        MainNavigation.SelectedItem = section switch
        {
            "viewing" => ViewingNavigationItem,
            "settings" => SettingsNavigationItem,
            _ => HomeNavigationItem
        };
        UpdateNavigationAvatar();
        BackButton.Visibility = route is "library" or "detail" or "detail-info" || route.StartsWith("settings:") || route.StartsWith("viewing:") ? Visibility.Visible : Visibility.Collapsed;
        SortButton.Visibility = route == "library" ? Visibility.Visible : Visibility.Collapsed;
        if (route == "library")
        {
            var sort = _model.LibrarySort;
            var direction = sort.Field == "random" ? "" : sort.Ascending ? "，升序" : "，降序";
            AutomationProperties.SetHelpText(SortButton, $"{LibrarySort.Label(sort.Field)}{direction}，{LibrarySort.WatchLabel(sort.WatchState)}");
        }
        HeaderActions.Visibility = !serverConnectionPage && (route is "home" or "library") ? Visibility.Visible : Visibility.Collapsed;
        ViewingActions.Visibility = route == "viewing" ? Visibility.Visible : Visibility.Collapsed;
        NavGroup.Visibility = !serverConnectionPage && (route is "home" or "settings" or "viewing") ? Visibility.Visible : Visibility.Collapsed;
        HeaderShade.Visibility = serverConnectionPage ? Visibility.Collapsed : Visibility.Visible;
        // When the focused back button disappears, keep focus on the selected section.
        // SelectionFollowsFocus would otherwise select the first (home) item on return.
        if (restoreNavigationFocus && NavGroup.Visibility == Visibility.Visible && MainNavigation.SelectedItem is Control navigationItem)
            navigationItem.Focus(FocusState.Programmatic);
        ServerButton.Visibility = route == "home" && !serverConnectionPage ? Visibility.Visible : Visibility.Collapsed;
        if (serverConnectionPage) { Notice.IsOpen = false; Notice.Visibility = Visibility.Collapsed; }
        _ambient.Update();
        UpdateAmbientActivity();
        if (_searchSource == "bangumi" && !_model.BangumiEnabled || _searchSource == "moviepilot" && !_model.MoviePilotEnabled) _searchSource = "library";
        UpdateSearchSource();
        PageTitle.Text = route.StartsWith("settings:") ? route[9..] : route switch { "home" => "首页", "library" => _model.LibraryName, "detail" or "detail-info" => _model.SelectedMedia.Title, "viewing" => "观影空间", _ => "设置" };
        if (serverConnectionPage) PageTitle.Text = "OcPlayer";
        if (route.StartsWith("viewing:")) PageTitle.Text = "观影空间";
        var detailFlip = !changedDetail && previous != route && (previous is "detail" or "detail-info") && (route is "detail" or "detail-info");
        var page = serverConnectionPage ? ServerConnectionPage()
            : route == "library" && previous is "detail" or "detail-info" && _cachedPages.TryGetValue("library",out var library) ? library
            : detailFlip && _cachedDetailPages.TryGetValue(route, out var detailPage) && detailPage.Episode == _model.SelectedEpisode ? detailPage.Page
            : route == "settings:服务器管理" ? ServerManagementPage()
            : !App.DemoMode && App.Core is not null && route is "settings:Bangumi" or "settings:MoviePilot" ? _integrationPages.Settings(route == "settings:Bangumi")
            : !App.DemoMode && App.Core is not null && route.StartsWith("viewing:") ? _integrationPages.Route(route)
            : !App.DemoMode && route == "viewing" ? _integrationPages.Dashboard()
            : route.StartsWith("settings:") ? _pages.SettingsSubpage(route[9..]) : route switch { "library" => _pages.Library(), "detail" => _pages.Detail(), "detail-info" => _pages.DetailInformation(),
                "viewing" => _pages.Viewing(), "settings" => _pages.Settings(), _ => _pages.Home() };
        var transition = previous == route ? PageTransitionKind.None : detailFlip ? PageTransitionKind.DetailFlip
            : (previous is "home" or "viewing" or "settings") && (route is "home" or "viewing" or "settings") ? PageTransitionKind.Section
            : PageTransitionKind.Route;
        _transitions.Show(page, transition);
        ApplyIntegrationHeader();
        _detailPageEpisode = _model.SelectedEpisode;
        _navigating = false;
        DispatcherQueue.TryEnqueue(UpdateTitleBarRegions);
        if (!App.DemoMode && route == "library" && previous != "detail" && previous != "detail-info") LoadLibrary();
    }
    private async void OpenDetail(DemoMedia media)
    {
        if (_model.Route is not ("detail" or "detail-info")) _detailOrigin = _model.Route;
        if (!App.DemoMode && media.SourceUri is null && App.Core?.Server is { } server)
        {
            var cached = server.CachedDetail(media);
            if (cached is not null)
            {
                _model.SelectedMedia = cached with { DetailWarning = null };
                _model.SelectedEpisode = cached.InitialEpisodeNumber; ClearDetailPages(); Navigate("detail");
            }
            var (token, generation) = BeginLoad();
            try
            {
                media = await server.Detail(media, token);
                media = await EnrichDetail(media, server, token);
                if (generation != _loadGeneration) return;
                if (cached is not null)
                {
                    if (media.DetailWarning is { } warning) AppDiagnostics.Write("debug", warning);
                    if (media.Progress >= 100) _model.Watched.Add(media.Id);
                    var selectedNumber = _model.SelectedEpisode;
                    _model.SelectedMedia = media with { DetailWarning = null };
                    _model.SelectedEpisode = cached.SelectedSeasonId == media.SelectedSeasonId
                        && media.Episodes?.Any(x => x.Number == selectedNumber) == true ? selectedNumber : media.InitialEpisodeNumber;
                    RefreshPlaybackPage(_model.Route);
                    return;
                }
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex)
            {
                if (generation != _loadGeneration) return;
                if (cached is not null) AppDiagnostics.Write("debug", "详情缓存后台更新失败：" + ex.Message);
                else Notify("无法加载详情：" + ex.Message);
                return;
            }
        }
        if (media.Progress >= 100) _model.Watched.Add(media.Id);
        ClearDetailPages();
        _model.SelectedMedia = media; _model.SelectedEpisode = media.InitialEpisodeNumber; Navigate("detail");
    }
    private void ClearDetailPages()
    {
        _cachedDetailPages.Clear();
    }
    private async void ToggleWatched(DemoMedia media, bool watched)
    {
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
            if (_model.SelectedMedia.Id == media.Id)
            {
                _model.SelectedMedia = media with { Progress = watched ? 100 : 0, Played = watched,
                    Episodes = media.Episodes?.Select(x => x with { Progress = watched ? 100 : 0, Played = watched }).ToArray() };
                Navigate(_model.Route);
            }
            App.Core?.RefreshProgress();
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            if (!_closing && generation == _loadGeneration && _model.SelectedMedia.Id == media.Id) Navigate(_model.Route);
            Notify("无法更新观看状态：" + ex.Message);
        }
    }
    private async void SetEpisodeWatched(DemoMedia media, DemoEpisode episode, bool watched)
    {
        if (App.Core?.Server is not { } server) return;
        var (token, generation) = BeginLoad();
        try
        {
            var updated = await server.SetEpisodeWatched(episode, watched, token);
            if (_closing || generation != _loadGeneration) return;
            if (_model.SelectedMedia.Id == media.Id && _model.SelectedMedia.SelectedSeasonId == media.SelectedSeasonId)
            {
                _model.SelectedMedia = _model.SelectedMedia with { Episodes = _model.SelectedMedia.Episodes?.Select(x =>
                    x.MediaId == episode.MediaId ? updated : x).ToArray() };
                Navigate(_model.Route);
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            if (!_closing && generation == _loadGeneration && _model.SelectedMedia.Id == media.Id) Navigate(_model.Route);
            Notify("无法更新此集的观看状态：" + ex.Message);
        }
    }

    private async void Play(DemoMedia media)
    {
        if (!App.DemoMode && App.Core is null) { Notify(App.CoreError ?? "播放核心不可用。"); return; }
        var episodeNumber = _model.SelectedEpisode;
        PlaybackSource? source = null;
        if (!App.DemoMode && media.SourceUri is null && App.Core?.Server is { } server)
        {
            await PrepareServerPlayback(media, episodeNumber, server); return;
        }
        else if (!App.DemoMode && media.SourceUri is null) { Notify("此条目没有可播放的片源。"); return; }
        if (media.Kind == "series" && media.Episodes?.FirstOrDefault(x => x.Number == episodeNumber) is { } selected)
        {
            var label = $"S{selected.SeasonNumber}E{selected.Number}";
            media = media with { EpisodeLabel = label, EpisodeNumber = selected.Number, SeasonNumber = selected.SeasonNumber,
                Progress = App.DemoMode && media.EpisodeLabel == label ? media.Progress : selected.Progress,
                DurationSeconds = selected.DurationSeconds > 0 ? selected.DurationSeconds : media.DurationSeconds };
        }
        if (_closing) return;
        PresentPlayer(media, source);
    }

    private void PresentPlayer(DemoMedia media, PlaybackSource? source = null)
    {
        _playingMedia = media; _playingEpisode = media.EpisodeNumber ?? _model.SelectedEpisode; _playingSource = source;
        if (_player is not null) { _player.SetMedia(media, source); return; }
        _focusBeforePlayback = Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(Root.XamlRoot) as Control;
        _presenterBeforePlayback = AppWindow.Presenter;
        _sizeBeforePlayback = AppWindow.Size;
        _player = new PlayerView(this, media, source);
        _player.CloseRequested += Player_CloseRequested;
        _player.PlaybackEnded += Player_PlaybackEnded;
        _player.RetryRequested += Player_RetryRequested;
        _player.PlaybackFailed += Player_PlaybackFailed;
        _player.VideoDimensionsAvailable += Player_VideoDimensionsAvailable;
        PlayerHost.Children.Add(_player);
        PlayerHost.Visibility = Visibility.Visible;
        // Retain the actual page tree: selection and scroll position survive playback.
        Root.Visibility = Visibility.Collapsed;
        SetTitleBar(_player.DragRegion);
        SetCaptionTheme();
        UpdateAmbientActivity();
    }

    private void Player_CloseRequested(object? sender, EventArgs args) => DismissPlayer();

    private void DismissPlayer(bool refresh = true)
    {
        _playPrepare?.Cancel(); _playPrepare?.Dispose(); _playPrepare = null;
        if (_player is not { } player) return;
        player.CloseRequested -= Player_CloseRequested;
        player.PlaybackEnded -= Player_PlaybackEnded;
        player.RetryRequested -= Player_RetryRequested;
        player.PlaybackFailed -= Player_PlaybackFailed;
        player.VideoDimensionsAvailable -= Player_VideoDimensionsAvailable;
        // Detach the swap chain and finish progress reporting before removing its XAML surface.
        try { player.Dispose(); }
        catch (Exception ex) { Notify("停止播放时发生错误：" + ex.Message); }
        _player = null;
        PlayerHost.Children.Clear();
        PlayerHost.Visibility = Visibility.Collapsed;
        Root.Visibility = Visibility.Visible;
        if (!_closing)
        {
            if (_presenterBeforePlayback is { } presenter && AppWindow.Presenter != presenter)
                AppWindow.SetPresenter(presenter);
            if (_sizeBeforePlayback is { } size) AppWindow.Resize(size);
            SetTitleBar(TitleBar);
            SetCaptionTheme();
            Root.UpdateLayout();
            UpdateTitleBarRegions();
            _focusBeforePlayback?.Focus(FocusState.Programmatic);
            UpdateAmbientActivity();
            if (refresh) RefreshAfterPlayback();
        }
        _focusBeforePlayback = null;
        _presenterBeforePlayback = null;
        _sizeBeforePlayback = null;
    }

    private async void RefreshAfterPlayback()
    {
        if (_closing || App.DemoMode) return;
        App.Core?.RefreshProgress();
        var route = _model.Route;
        RefreshPlaybackPage(route);
        if (App.DemoMode || route is not ("detail" or "detail-info") || _model.SelectedMedia.SourceUri is not null
            || App.Core is not { Server: { } server } core) return;
        var media = _model.SelectedMedia;
        var (token, generation) = BeginLoad();
        try
        {
            await core.FinishReports();
            var refreshed = await server.Detail(media, token, media.SelectedSeasonId);
            if (generation != _loadGeneration || _closing || _player is not null) return;
            var selectedNumber = _model.SelectedEpisode;
            _model.SelectedMedia = refreshed;
            _model.SelectedEpisode = refreshed.Episodes?.Any(x => x.Number == selectedNumber) == true
                ? selectedNumber : refreshed.InitialEpisodeNumber;
            RefreshPlaybackPage(route);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { Notify("无法刷新观看状态：" + ex.Message); }
    }
    private void RefreshPlaybackPage(string route)
    {
        static IEnumerable<ScrollViewer> Scrolls(DependencyObject parent)
        {
            if (parent is ScrollViewer scroll) yield return scroll;
            for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
                foreach (var child in Scrolls(VisualTreeHelper.GetChild(parent, i))) yield return child;
        }
        var offsets = Scrolls(PageHost).Select(x => (x.HorizontalOffset, x.VerticalOffset)).ToArray();
        Navigate(route);
        PageHost.UpdateLayout();
        foreach (var (scroll, offset) in Scrolls(PageHost).Zip(offsets))
            scroll.ChangeView(offset.HorizontalOffset, offset.VerticalOffset, null, true);
    }
    private void SetTheme(bool dark)
    {
        Root.RequestedTheme = _model.ThemeMode switch { "dark" => ElementTheme.Dark, "light" => ElementTheme.Light, _ => ElementTheme.Default };
        _model.DarkTheme = Root.ActualTheme == ElementTheme.Dark;
        SetCaptionTheme();
        DispatcherQueue.TryEnqueue(() => Navigate(_model.Route));
    }
    private void SetCaptionTheme()
    {
        if (_closing || AppWindow?.TitleBar is not { } caption) return;
        _model.DarkTheme = Root.ActualTheme == ElementTheme.Dark;
        Root.Background = new SolidColorBrush(Controls.AmbientBackdropView.PageColor(_model.DarkTheme));
        Ambience.SetStyle(_model.DarkTheme, _model.Route == "detail-info");
        caption.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
        caption.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
        caption.ButtonForegroundColor = _player is not null || Root.ActualTheme == ElementTheme.Dark ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black;
        caption.ButtonInactiveForegroundColor = _player is not null ? Microsoft.UI.Colors.LightGray : null;
    }
    private void Root_ActualThemeChanged(FrameworkElement sender, object args) => SetCaptionTheme();
    private void UpdateAmbientActivity()
    {
        _ambient.SetActivity(_active && !_closing && _player is null, _uiSettings.AnimationsEnabled);
        _transitions.SetAnimationsEnabled(_uiSettings.AnimationsEnabled);
    }
    private void AnimationsEnabledChanged(global::Windows.UI.ViewManagement.UISettings sender, object args) => DispatcherQueue.TryEnqueue(UpdateAmbientActivity);
    private void Notify(string message) { if (_closing) return; Notice.Visibility = Visibility.Visible; Notice.Message = message; Notice.IsOpen = true; }
    private void MainNavigation_SelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        if (!_navigating && args.SelectedItem is NavigationViewItem { Tag: string route }) Navigate(route);
    }
    private void UpdateNavigationAvatar() => Avatar.Source = MainNavigation.SelectedItem is NavigationViewItem { Tag: "home" }
        ? _avatarColor : (ImageSource?)_avatarGray ?? _avatarColor;

    private async Task LoadNavigationAvatar()
    {
        _avatarLoad?.Cancel(); _avatarLoad?.Dispose(); _avatarLoad = new CancellationTokenSource(); var token = _avatarLoad.Token;
        var server = App.Core?.Server;
        try
        {
            var path = !App.DemoMode && App.Core?.Server?.UserAvatarUrl is { } avatar
                ? await ImageDiskCache.Resolve(avatar, token)
                : Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", "avatar-nav.png");
            if (_closing || token.IsCancellationRequested || server != App.Core?.Server) return;
            _avatarColor = new BitmapImage(new Uri(path)) { DecodePixelWidth = 54 }; _avatarGray = null; UpdateNavigationAvatar();
            using var file = File.OpenRead(path);
            using var stream = file.AsRandomAccessStream();
            var decoder = await BitmapDecoder.CreateAsync(stream);
            // The icon asset already contains the centered circular crop and
            // transparent edges, matching macOS's 18pt avatar in an icon-only item.
            var scale = 54d / Math.Min(decoder.PixelWidth, decoder.PixelHeight);
            var width = (uint)Math.Max(1, Math.Round(decoder.PixelWidth * scale));
            var height = (uint)Math.Max(1, Math.Round(decoder.PixelHeight * scale));
            var pixels = (await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
                new BitmapTransform { ScaledWidth = width, ScaledHeight = height, InterpolationMode = BitmapInterpolationMode.Fant },
                ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.ColorManageToSRgb)).DetachPixelData();
            for (var i = 0; i < pixels.Length; i += 4)
            {
                var luminance = (byte)((pixels[i + 2] * 77 + pixels[i + 1] * 150 + pixels[i] * 29 + 128) >> 8);
                pixels[i] = pixels[i + 1] = pixels[i + 2] = luminance;
            }
            if (_closing || token.IsCancellationRequested || server != App.Core?.Server) return;
            _avatarGray = new WriteableBitmap((int)width, (int)height);
            using var buffer = _avatarGray.PixelBuffer.AsStream();
            buffer.Write(pixels); _avatarGray.Invalidate();
            UpdateNavigationAvatar();
        }
        catch (Exception) { /* Keep the color picture if an optional grayscale decode is unavailable. */ }
    }
    private void GlobalSearch_QuerySubmitted(AutoSuggestBox sender, AutoSuggestBoxQuerySubmittedEventArgs args)
    {
        if (!App.DemoMode && _searchSource != "library")
        {
            Navigate("viewing:" + _searchSource + ":" + (_searchSource == "bangumi" ? "q=" : "") + Uri.EscapeDataString(args.QueryText));
            return;
        }
        _model.Query = args.QueryText;
        if (_model.Route != "library") { _model.LibraryName = "全部媒体库"; _model.LibraryId = null; _model.Category = "全部"; }
        Navigate("library");
    }
    private void Refresh_Click(object sender, RoutedEventArgs e) { if (App.Core?.Server is not null) { if (_model.Route == "library") LoadLibrary(); else LoadHome(); } else { App.Core?.RefreshProgress(); Navigate(_model.Route); } if (App.DemoMode) Notify("示例片库已刷新。当前是离线前端演示。"); }
    private void ApplyIntegrationHeader()
    {
        var show = !App.DemoMode && _model.Route.StartsWith("viewing:");
        IntegrationHeaderLeading.Content = show ? _integrationPages.HeaderLeading : null;
        IntegrationHeaderTrailing.Content = show ? _integrationPages.HeaderTrailing : null;
        IntegrationHeaderLeading.Visibility = IntegrationHeaderLeading.Content is null ? Visibility.Collapsed : Visibility.Visible;
        IntegrationHeaderTrailing.Visibility = IntegrationHeaderTrailing.Content is null ? Visibility.Collapsed : Visibility.Visible;
        IntegrationSubtitle.Text = show ? _integrationPages.HeaderSubtitle ?? "" : "";
        IntegrationSubtitle.Visibility = IntegrationSubtitle.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (show && _integrationPages.HeaderTitle is { } title) PageTitle.Text = title;
        _ambient.Update(resourceArtwork: show ? _integrationPages.HeaderBackdrop : null);
        DispatcherQueue.TryEnqueue(UpdateTitleBarRegions);
    }
    private void ViewingMenu_Opening(object sender, object e)
    {
        var menu = (MenuFlyout)sender; menu.Items.Clear(); var source = _integrationPages.ViewingMenu();
        foreach (var item in source.Items.ToArray()) { source.Items.Remove(item); menu.Items.Add(item); }
    }
    private async void ViewingRefresh_Click(object sender, RoutedEventArgs e)
    {
        ViewingRefreshButton.IsEnabled = false;
        try { if (App.DemoMode) Navigate("viewing"); else await _integrationPages.RefreshDashboard(); }
        finally { ViewingRefreshButton.IsEnabled = true; }
    }
    private void UpdateTitleBarRegions()
    {
        if (_closing || Root.XamlRoot is not { } xamlRoot) return;
        if (_player is not null) { _player.UpdateWindowChrome(); return; }
        var scale = xamlRoot.RasterizationScale;
        // AppWindow metrics are physical pixels; XAML layout uses logical pixels.
        // Keep content and native caption buttons on the same vertical center,
        // and reserve the real caption width across DPI and presenter changes.
        var titleBar = AppWindow.TitleBar;
        if (titleBar.Height > 0) TitleBarRow.Height = new GridLength(titleBar.Height / scale);
        _pageLayout.HeaderHeight = TitleBarRow.Height.Value;
        HeaderShade.Height = _pageLayout.HeaderHeight + 64;
        // Match one native caption button: full title-bar height, no inset or
        // rounded hover surface. RightInset covers the three caption buttons.
        BackButton.Width = titleBar.RightInset > 0 ? titleBar.RightInset / (3 * scale) : 46;
        BackButton.Height = TitleBarRow.Height.Value;
        TitleBar.Margin = new Thickness((BackButton.Visibility == Visibility.Visible ? 0 : 18) + titleBar.LeftInset / scale,
            0, 10 + titleBar.RightInset / scale, 0);
        RectInt32 Bounds(FrameworkElement element)
        {
            var point = element.TransformToVisual(Root).TransformPoint(new global::Windows.Foundation.Point());
            return new RectInt32((int)(point.X * scale), (int)(point.Y * scale), (int)(element.ActualWidth * scale), (int)(element.ActualHeight * scale));
        }
        if (IntegrationHeaderTrailing.Content is AutoSuggestBox search) search.Width = Root.ActualWidth < 800 ? 170 : 280;
        PageTitle.MaxWidth = Root.ActualWidth < 800 ? 160 : 280;
        IntegrationSubtitle.MaxWidth = PageTitle.MaxWidth;
        var regions = new FrameworkElement[] { NavGroup, BackButton, SortButton, ServerButton, HeaderActions, ViewingActions, IntegrationHeaderLeading, IntegrationHeaderTrailing }.Where(x => x.Visibility == Visibility.Visible && x.ActualWidth > 0).Select(Bounds).ToArray();
        InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(NonClientRegionKind.Passthrough, regions);
    }
    private void Back_Click(object sender, RoutedEventArgs e) => Navigate(_model.Route == "detail-info" ? "detail" : _model.Route == "detail" ? _detailOrigin : _model.Route.StartsWith("settings:") ? "settings" : _model.Route.StartsWith("viewing:resources") || _model.Route == "viewing:downloads" ? _moviePilotOrigins.GetValueOrDefault(_model.Route, "viewing:moviepilot") : _model.Route.StartsWith("viewing:") ? "viewing" : "home");
    private void GlobalSearch_TextChanged(AutoSuggestBox sender, AutoSuggestBoxTextChangedEventArgs e)
    {
        if (_navigating || _model.Route is not ("library" or "home") || _searchSource != "library" || e.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
        _model.Query = GlobalSearch.Text;
        if (_model.Route == "home") { if (string.IsNullOrWhiteSpace(_model.Query)) return; _model.LibraryId = null; _model.LibraryName = "全部媒体库"; _model.Category = "全部"; Navigate("library"); return; }
        if (App.Core?.Server is not null) { LoadLibrary(); return; }
        PageHost.Children.Clear(); PageHost.Children.Add(_pages.Library());
    }
    private void UpdateSearchSource()
    {
        SearchSourceButton.Content = _searchSource switch { "bangumi" => "Bangumi", "moviepilot" => "MoviePilot", _ => "媒体库" };
        GlobalSearch.PlaceholderText = _searchSource switch { "bangumi" => "搜索 Bangumi 动画", "moviepilot" => "搜索 MoviePilot 媒体", _ => _model.Route == "library" ? "搜索本库" : "搜索全部媒体库" };
        AutomationProperties.SetName(GlobalSearch, GlobalSearch.PlaceholderText);
    }
    private void SearchSources_Opening(object sender, object e)
    {
        var menu = (MenuFlyout)sender; menu.Items.Clear();
        foreach (var (key, title, enabled) in new[] { ("library", "媒体库", true), ("bangumi", "Bangumi", !App.DemoMode && _model.BangumiEnabled), ("moviepilot", "MoviePilot", !App.DemoMode && _model.MoviePilotEnabled) })
        {
            if (!enabled) continue;
            var item = new RadioMenuFlyoutItem { Text = title, IsChecked = _searchSource == key, GroupName = "SearchSource" };
            item.Click += (_, _) => { _searchSource = key; UpdateSearchSource(); };
            menu.Items.Add(item);
        }
    }
    private void SortMenu_Opening(object sender, object e)
    {
        var menu = (MenuFlyout)sender;
        menu.Items.Clear();
        var settings = _model.LibrarySort;
        foreach (var field in LibrarySort.Options(_model.LibraryCollectionType))
        {
            var glyph = field switch { "name" => "\uE8D2", "dateAdded" => "\uE81C", "year" => "\uE787",
                "rating" => "\uE734", "runtime" => "\uE916", _ => "\uE8B1" };
            AddChoice(LibrarySort.Label(field), glyph, "LibrarySortField", settings.Field == field,
                () => settings with { Field = field, Ascending = field == "name" });
        }
        if (settings.Field != "random")
        {
            menu.Items.Add(new MenuFlyoutSeparator());
            AddChoice("升序", "\uE74A", "LibrarySortDirection", settings.Ascending, () => settings with { Ascending = true });
            AddChoice("降序", "\uE74B", "LibrarySortDirection", !settings.Ascending, () => settings with { Ascending = false });
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        foreach (var state in new[] { "all", "watched", "unwatched" })
        {
            var glyph = state switch { "watched" => "\uE930", "unwatched" => "\uEA3A", _ => "\uE80A" };
            AddChoice(LibrarySort.WatchLabel(state), glyph, "LibraryWatchState", settings.WatchState == state,
                () => settings with { WatchState = state });
        }

        void AddChoice(string label, string glyph, string group, bool selected, Func<LibrarySortSettings> change)
        {
            var item = new RadioMenuFlyoutItem { Text = label, Icon = new FontIcon { Glyph = glyph }, GroupName = group, IsChecked = selected };
            item.Click += (_, _) =>
            {
                if (selected) return;
                try { _model.LibrarySort = change(); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Notify("无法保存媒体库排序：" + ex.Message); }
                Navigate("library");
            };
            menu.Items.Add(item);
        }
    }
    private async void OpenFile_Click(object sender, RoutedEventArgs e) => await OpenLocalFile();
    private async void OpenFileButton_Click(SplitButton sender, SplitButtonClickEventArgs args) => await OpenLocalFile();
    private async Task OpenLocalFile()
    {
        var picker = new global::Windows.Storage.Pickers.FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        picker.FileTypeFilter.Add("*");
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
        var input = new TextBox { PlaceholderText = "https://…、file:///… 或本地文件路径", MinWidth = 340 };
        var access = new PasswordBox { Header = "AccessToken（可选）" };
        var fields = new StackPanel { Spacing = 12, Children = { input, access } };
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "打开直连链接", Content = fields,
            PrimaryButtonText = "打开", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Primary, RequestedTheme = Root.RequestedTheme };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary) return;
        OpenSource(input.Text.Trim().Trim('"'), access.Password);
    }
    private void Server_Click(object sender, RoutedEventArgs e) { if (App.Core?.Servers.Items.Count > 0) Navigate("settings:服务器管理"); else ConnectServer(); }
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
        _model.HomeLoading = true; RefreshHomePage();
        try { await server.Refresh(token); if (generation != _loadGeneration) return; _model.ServerItems = server.Latest; _cachedPages.Clear(); UpdateServerLabel(); await LoadNavigationAvatar(); _ambient.Update(true); }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (generation == _loadGeneration) { server.HomeRefreshFailed("刷新失败：" + ex.Message); Notify(server.HomeWarning!); } }
        finally { if (generation == _loadGeneration) { _model.HomeLoading = false; RefreshHomePage(); } }
    }
    private void RefreshHomePage() { if (_model.Route == "home") _transitions.Show(_pages.Home(), PageTransitionKind.None); }
    private string? _libraryQueryKey;
    private async void LoadLibrary(bool append = false)
    {
        if (App.Core?.Server is not { } server) return;
        if (append && (_model.LibraryLoading || !_model.LibraryHasMore)) return;
        var libraryId = _model.LibraryId; var query = _model.Query; var sort = _model.LibrarySort;
        var cacheRevision = server.CacheRevision;
        var key = server.Profile.Id + ":" + libraryId + ":" + query + ":" + sort;
        if (append && key != _libraryQueryKey) return;
        var (token, generation) = BeginLoad();
        if (!append)
        {
            if (key != _libraryQueryKey) { _model.ServerItems = []; _model.LibraryNextIndex = 0; _model.LibraryHasMore = false; _model.LibraryTotalCount = null; }
            _libraryQueryKey = key; _model.LibraryCacheNotice = null;
            if (server.CachedBrowse(libraryId, query, sort) is { } cached)
            {
                _model.ServerItems = cached.Value.Items; _model.LibraryTotalCount = cached.Value.TotalCount;
                _model.LibraryNextIndex = cached.Value.NextIndex; _model.LibraryHasMore = cached.Value.HasMore;
                _model.LibraryCacheNotice = $"缓存更新于 {cached.SavedAt.LocalDateTime:g}";
            }
        }
        _model.LibraryLoading = true; _model.LibraryError = null; RenderLibrary();
        try
        {
            if (!append) await Task.Delay(350, token);
            var page = await server.BrowsePage(libraryId, query, sort, append ? _model.LibraryNextIndex : 0, token);
            if (generation != _loadGeneration || _model.Route != "library") return;
            _model.ServerItems = (append ? (_model.ServerItems ?? []).Concat(page.Items) : page.Items).DistinctBy(x => x.Id).ToArray();
            _model.LibraryNextIndex = page.NextIndex; _model.LibraryHasMore = page.HasMore; _model.LibraryTotalCount = page.TotalCount;
            _model.LibraryCacheNotice = null;
            server.CacheBrowse(libraryId, query, sort, new BrowserPage(_model.ServerItems.ToArray(), 0, page.TotalCount, page.HasMore), cacheRevision);
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (generation == _loadGeneration) _model.LibraryError = "加载失败：" + ex.Message; }
        finally { if (generation == _loadGeneration) { _model.LibraryLoading = false; RenderLibrary(); } }
    }
    private void RenderLibrary()
    {
        if (_model.Route != "library") return;
        var offsets = FindVisual<ScrollViewer>(PageHost)?.VerticalOffset ?? 0;
        _transitions.Show(_pages.Library(), PageTransitionKind.None); PageHost.UpdateLayout();
        FindVisual<ScrollViewer>(PageHost)?.ChangeView(null, offsets, null, true);
    }
    private static T? FindVisual<T>(DependencyObject parent) where T : DependencyObject
    {
        if (parent is T result) return result;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++) if (FindVisual<T>(VisualTreeHelper.GetChild(parent, i)) is { } child) return child;
        return null;
    }
    private async void LoadSeason(string seasonId)
    {
        if (App.Core?.Server is not { } server) return;
        _model.SeasonSelection[server.Profile.Id + ":" + _model.SelectedMedia.Id + ":" + _model.SelectedMedia.SelectedSeasonId] = _model.SelectedEpisode;
        var (token, generation) = BeginLoad();
        _model.PendingSeasonId = seasonId; _model.EpisodesLoading = true; _model.EpisodeError = null;
        RefreshPlaybackPage(_model.Route);
        try
        {
            var media = seasonId.StartsWith("tmdb:") && int.TryParse(seasonId[5..], out var tmdbSeason)
                ? _model.SelectedMedia with { SelectedSeasonId = seasonId, SeasonNumber = tmdbSeason, EpisodeNumber = null, EpisodeLabel = null, Episodes = [] }
                : await server.Detail(_model.SelectedMedia, token, seasonId);
            media = await EnrichDetail(media, server, token);
            if (generation != _loadGeneration) return;
            _model.SelectedMedia = media;
            _model.SelectedEpisode = _model.SeasonSelection.TryGetValue(server.Profile.Id + ":" + media.Id + ":" + seasonId, out var remembered)
                && media.Episodes?.Any(x => x.Number == remembered && x.Available) == true ? remembered : media.InitialEpisodeNumber;
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (generation == _loadGeneration) _model.EpisodeError = "加载分季失败：" + ex.Message; }
        finally { if (generation == _loadGeneration) { _model.EpisodesLoading = false; RefreshPlaybackPage(_model.Route); } }
    }
    private void ConnectServer()
    {
        if (_closing) return;
        try { App.EnsureCore(); }
        catch (Exception ex) { Notify("无法加载播放核心：" + ex.Message); return; }
        Navigate("settings:连接服务器");
    }
    private UIElement ServerConnectionPage()
    {
        var initial = _loginProfile; _loginProfile = null;
        return new ServerConnectionView(App.Core!, async server =>
        {
            if (_closing) return;
            await ActivateServer(server);
            Notify($"已连接 {server.Profile.DisplayName}，读取到 {server.Libraries.Count} 个媒体库。" + (server.HomeWarning is { } warning ? " " + warning : ""));
        }, () =>
        {
            _localPlayerMode = true; Navigate("home");
        }, initial);
    }
    private void DisconnectServer()
    {
        _switchServer?.Cancel(); _avatarLoad?.Cancel();
        try
        {
            DismissPlayer(false); App.Core?.DisconnectServer(); BeginLoad(); _model.LibraryId = null; _model.ServerItems = null; _model.Watched.Clear(); _cachedPages.Clear(); UpdateServerLabel(); Navigate("home"); Notify("已断开服务器连接。可以连接其它服务器，或打开本地文件。");
        }
        catch (Exception ex) { Notify("断开连接失败：" + ex.Message); }
    }
    private void OpenSource(string source, string? accessToken = null)
    {
        _playPrepare?.Cancel();
        try
        {
            if (Uri.TryCreate(source, UriKind.Absolute, out var fileUri) && fileUri.IsFile) source = fileUri.LocalPath;
            if (App.DemoMode) { Play(DemoCatalog.Movies[0] with { Title = Path.GetFileNameWithoutExtension(source), Progress = 0 }); return; }
            var remote = Uri.TryCreate(source, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https";
            if (!remote && !File.Exists(source)) throw new FileNotFoundException("文件不存在", source);
            source = remote ? uri!.AbsoluteUri : Path.GetFullPath(source);
            var id = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(source)));
            var title = remote ? Path.GetFileName(Uri.UnescapeDataString(uri!.AbsolutePath)) : Path.GetFileNameWithoutExtension(source);
            var media = new DemoMedia(id, string.IsNullOrWhiteSpace(title) ? "直连媒体" : title, "", "", remote ? "网络媒体" : "本地文件", "", "", DurationSeconds: 0, SourceUri: source);
            App.Core?.Remember(media);
            if (remote && !string.IsNullOrWhiteSpace(accessToken)) PresentPlayer(media, new PlaybackSource(id, media.Title, source,
                HttpHeaders: new Dictionary<string, string> { ["X-Emby-Token"] = accessToken }));
            else Play(media);
        }
        catch (Exception ex) { Notify("无法打开媒体：" + ex.Message); }
    }
}

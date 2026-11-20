using System.Diagnostics;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;
using Windows.Graphics;
using Microsoft.UI.Xaml.Automation;
using Windows.System;

namespace OcPlayer.Windows;

public sealed partial class PlayerView : UserControl, IDisposable
{
    private readonly DispatcherTimer _backgroundClock = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private bool _renderingSubscribed;
    private TimeSpan _lastRenderingTime = TimeSpan.MinValue;
    private double _presentationClockOffset = double.NaN;
    private readonly Stopwatch _time = Stopwatch.StartNew();
    private PlaybackSession? _session;
    private SwapChainPanelHost? _surface;
    private bool _playing = true, _scrubbing, _updating, _closed, _attached;
    private double _rate = 1, _lastDemoTick, _lastHudUpdate;
    private DateTime _lastInteraction = DateTime.UtcNow;
    private DateTime _ignoreEscapeUntil;
    private DemoMedia _media = null!;
    private PlaybackSource? _source;
    private ViewingRecorder? _viewingRecorder;

    private readonly Window _window;
    private readonly bool _demoMode = App.DemoMode;
    private XamlRoot? _attachedRoot;
    private MenuFlyout? _activeMenu;
    private AppWindowPresenter? _windowedPresenter;
    private bool _controlsHovered;
    private bool _pointerInside = true, _userHidden;
    private int _modalInteractions;
    private readonly HashSet<FlyoutBase> _openFlyouts = [];
    private bool _menuOpen => _openFlyouts.Count > 0 || _modalInteractions > 0;
    private readonly PlayerHudVisibilityController _hudVisibility;
    private readonly DispatcherTimer _singleTap = new();
    private global::Windows.Foundation.Point? _lastPointer;
    public event EventHandler? CloseRequested;
    internal FrameworkElement DragRegion => PlayerTitleBar;
    internal bool IsDisposed => _closed;

    public PlayerView(Window window, DemoMedia media, PlaybackSource? source = null)
    {
        InitializeComponent();
        _window = window;
        _hudVisibility = new PlayerHudVisibilityController(Hud, UpdateWindowChrome);
        PlayerRoot.AddHandler(UIElement.PointerExitedEvent, new PointerEventHandler(Player_PointerExited), true);
        _singleTap.Interval = TimeSpan.FromMilliseconds(new global::Windows.UI.ViewManagement.UISettings().DoubleClickTime);
        _singleTap.Tick += (_, _) =>
        {
            _singleTap.Stop();
            if (_closed || _menuOpen || _scrubbing) return;
            if (_hudVisibility.IsVisible) { _userHidden = true; _hudVisibility.Hide(); }
            else ShowHud();
        };
        PlayerRoot.Loaded += (_, _) => { UpdateWindowChrome(); AttachNative(); UpdatePlaybackClock(); Focus(FocusState.Programmatic); };
        PlayerRoot.SizeChanged += (_, _) => { UpdateWindowChrome(); ResizeNative(); };
        _window.AppWindow.Changed += WindowChanged;
        Unloaded += (_, _) => Dispose();
        Timeline.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => { _scrubbing = true; ShowHud(); }), true);
        Timeline.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => CommitScrub()), true);
        Timeline.PointerCaptureLost += (_, _) => CommitScrub();
        Volume.ValueChanged += (_, args) => { if (!_restoringPreferences) _muted = false; Run(() => _session?.SetVolume(_muted ? 0 : args.NewValue / 100)); SchedulePlaybackPreferences(); UpdateVolumeIcon(); ShowHud(); };
        foreach (var button in new[] { PlayButton, SkipBackButton, SkipForwardButton }) AddTransportFeedback(button);
        InitializeMoreMenu();
        InitializeRuntime();
        SetMedia(media, source);
        _backgroundClock.Tick += (_, _) => { UpdatePlaybackClock(); if (!_renderingSubscribed) Tick(false); };
        UpdatePlaybackClock();

    }

    public void SetMedia(DemoMedia media, PlaybackSource? source = null)
    {
        EndFastForward();
        ResetDanmakuSource();
        DanmakuNotice.IsOpen = false;
        Run(() => _viewingRecorder?.Flush());
        _viewingRecorder = null;
        if (!_demoMode && App.Core is { } core)
        {
            var item = source is null ? media : media with { Id = source.Id, Kind = media.Kind == "series" ? "episode" : media.Kind };
            _viewingRecorder = new ViewingRecorder(core.ViewingHistory, source?.Report is null ? "local" : ViewingHistory.Source(core.Server), item);
        }
        _updating = true; _scrubbing = false;
        _activeMenu?.Hide(); VolumeFlyout.Hide();
        _singleTap.Stop(); ResetMenuState();
        _media = media; _source = source;
        ResetTrackMenus();
        ResetServerSubtitles();
        ResetSkipPrompts();
        ResetDanmakuMenuState();
        var episode = media.Episodes?.FirstOrDefault(x => x.Number == (media.EpisodeNumber ?? media.InitialEpisodeNumber));
        var episodeLabel = media.EpisodeLabel ?? (media.Kind == "series" && episode is not null ? $"S{episode.SeasonNumber}E{episode.Number}" : null);
        var episodeTitle = media.Kind == "episode" ? media.Title : episode?.Title;
        MediaTitle.Text = media.Kind == "episode" && !string.IsNullOrWhiteSpace(media.SeriesTitle) ? media.SeriesTitle : media.Title;
        EpisodeTitle.Text = string.IsNullOrWhiteSpace(episodeLabel) ? "" : string.IsNullOrWhiteSpace(episodeTitle) ? episodeLabel : $"{episodeLabel} · {episodeTitle}";
        EpisodeTitle.Visibility = EpisodeTitle.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ResetMoreMedia();
        PlaybackError.IsOpen = false;
        if (_demoMode)
        {
            Backdrop.Source = new BitmapImage(new Uri(media.Backdrop));
            Timeline.Maximum = media.DurationSeconds > 0 ? media.DurationSeconds : 1440;
            Timeline.Value = Timeline.Maximum * media.Progress / 100;
            DurationLabel.Text = TimeLabel(Timeline.Maximum);
            SetPlaying(!Environment.GetCommandLineArgs().Any(x => x.StartsWith("--demo-capture=")));
        }
        else
        {
            Backdrop.Visibility = Visibility.Collapsed; VideoPanel.Visibility = Visibility.Visible;
            Timeline.Maximum = 1; Timeline.Value = 0; Timeline.IsEnabled = false;
            DurationLabel.Text = "--:--"; _playing = false;
            ShowPreparation(media.Title);
            if (_attached) Run(OpenNative);
        }
        PositionLabel.Text = TimeLabel(Timeline.Value);
        _updating = false; UpdatePlayIcon(); ShowHud();
    }

    private void AttachNative()
    {
        if (_demoMode || _attached || _closed || App.Core is null) return;
        Run(() =>
        {
            AppDiagnostics.ConfigureNativeTrace();
            _session = new PlaybackSession(App.Core.Client);
            InitializeDanmaku();
            _session.Failed += ShowError; _session.Failure += OnNativeFailure; _session.Ended += OnNativeEnded; _session.VideoDimensionsChanged += OnNativeDimensions;
            _surface = new SwapChainPanelHost(VideoPanel);
            _surface.CompositionScaleChanged += (_, _) => ResizeNative();
            var (width, height, scale) = Geometry();
            var hwnd = (ulong)WinRT.Interop.WindowNative.GetWindowHandle(_window).ToInt64();
            _session.Attach(hwnd, width, height, scale); _surface.Bind(_session.GetSwapChain());
            _attached = true; _attachedRoot = PlayerRoot.XamlRoot; _attachedRoot.Changed += RootChanged; OpenNative();
        });
    }

    private void OpenNative()
    {
        if (_source is null && _media.SourceUri is null) { ShowPreparation(_media.Title); return; }
        AppDiagnostics.ConfigureNativeTrace();
        ApplyRuntimeSettings(RuntimeSettings.Current);
        _session!.Open(_source ?? new PlaybackSource(_media.Id, _media.Title, _media.SourceUri!));
        _session.SetVolume(_muted ? 0 : Volume.Value / 100); _session.SetRate(_rate); _session.SetDanmaku(_danmakuEnabled);
        _session.SetSubtitleScale(_subtitleScale);
        try { _session.ConfigureDanmaku(App.Core!.Danmaku.Settings.Current.Renderer); }
        catch (Exception ex) { ShowDanmakuError(ex.Message); }
        StartDanmaku();
    }

    private (uint Width, uint Height, double Scale) Geometry()
    {
        var scale = PlayerRoot.XamlRoot?.RasterizationScale ?? 1;
        return ((uint)Math.Max(1, Math.Round(VideoPanel.ActualWidth * scale)), (uint)Math.Max(1, Math.Round(VideoPanel.ActualHeight * scale)), scale);
    }
    private void RootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => ResizeNative();
    private void ResizeNative()
    {
        if (!_attached || _closed) return;
        Run(() => { var (width, height, scale) = Geometry(); _session!.Resize(width, height, scale); _surface!.Bind(_session.GetSwapChain()); });
    }

    private void UpdatePlaybackClock()
    {
        if (_closed) return;
        var minimized = _window.AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized };
        if (minimized)
        {
            if (_renderingSubscribed) CompositionTarget.Rendering -= OnRendering;
            _renderingSubscribed = false;
            _backgroundClock.Start();
        }
        else
        {
            _backgroundClock.Stop();
            if (_renderingSubscribed) return;
            _lastRenderingTime = TimeSpan.MinValue;
            _presentationClockOffset = double.NaN;
            CompositionTarget.Rendering += OnRendering;
            _renderingSubscribed = true;
        }
    }

    private void OnRendering(object? sender, object args)
    {
        if (_closed || !_renderingSubscribed) return;
        if (args is RenderingEventArgs frame)
        {
            if (frame.RenderingTime == _lastRenderingTime) return;
            _lastRenderingTime = frame.RenderingTime;
            var now = (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency;
            if (double.IsNaN(_presentationClockOffset)) _presentationClockOffset = now - frame.RenderingTime.TotalSeconds;
            Tick(true, _presentationClockOffset + frame.RenderingTime.TotalSeconds);
            return;
        }
        Tick();
    }

    private void Tick(bool renderOverlay = true, double? presentationTimestamp = null)
    {
        if (_closed) return;
        var seconds = _time.Elapsed.TotalSeconds;
        var updateHud = seconds - _lastHudUpdate >= .2;
        if (updateHud) _lastHudUpdate = seconds;
        if (_demoMode)
        {
            if (_playing && !_scrubbing) { Timeline.Value = Math.Min(Timeline.Maximum, Timeline.Value + (seconds - _lastDemoTick) * _rate); if (Timeline.Value >= Timeline.Maximum) SetPlaying(false); }
            _lastDemoTick = seconds;
        }
        else if (_attached)
        {
            _session!.Tick(seconds, presentationTimestamp); Run(() => _surface!.Bind(_session.GetSwapChain())); App.Core?.DrainEvents();
            StartServerSubtitlesIfReady();
            Run(() => _viewingRecorder?.Sample(seconds, _session.PositionSeconds, _session.Ready && _session.Playing && !_scrubbing, _rate, DateTimeOffset.Now));
            if (updateHud)
            {
                _updating = true;
                var wasPlaying = _playing; _playing = _session.Playing;
                if (wasPlaying && !_playing) ShowHud();
                UpdatePlayIcon(); UpdateMenuIndicators(); Timeline.IsEnabled = _session.Ready && _session.DurationSeconds > 0;
                if (_session.DurationSeconds > 0) { Timeline.Maximum = _session.DurationSeconds; DurationLabel.Text = TimeLabel(Timeline.Maximum); }
                if (!_scrubbing) Timeline.Value = _session.PositionSeconds;
                _updating = false;
            }
        }
        if (renderOverlay) DrawDanmakuOverlay(presentationTimestamp);
        TickRuntime(seconds);
        if (updateHud) UpdateChapterSelection();
        RefreshMoreInfo();
        if (_hudVisibility.IsVisible && !_userHidden && _playing && !_scrubbing && !_menuOpen && !_controlsHovered
            && _session?.Buffering != true && !_screenReader
            && DateTime.UtcNow - _lastInteraction > TimeSpan.FromSeconds(3) && !HasControlFocus())
        { _hudVisibility.Hide(); }
    }

    public void Dispose()
    {
        if (_closed) return;
        RestoreWindowChrome();
        DisposeRuntime();
        _closed = true; _backgroundClock.Stop();
        if (_renderingSubscribed) CompositionTarget.Rendering -= OnRendering;
        _renderingSubscribed = false;
        DisposeDanmaku();
        DisposeServerSubtitles();
        DisposeTrackMenus(); DisposeMoreMenu();
        _singleTap.Stop(); _hudVisibility.Dispose();
        Run(() => _viewingRecorder?.Flush());
        _window.AppWindow.Changed -= WindowChanged;
        _activeMenu?.Hide();
        VolumeFlyout.Hide();
        if (_attachedRoot is not null) _attachedRoot.Changed -= RootChanged;
        if (_session is not null) { _session.Failed -= ShowError; _session.Failure -= OnNativeFailure; _session.Ended -= OnNativeEnded; _session.VideoDimensionsChanged -= OnNativeDimensions; }
        try { _surface?.Dispose(); }
        finally
        {
            try { _session?.Dispose(); }
            finally { if (_session is not null) App.Core?.TrackReports(_session.ReportingCompleted); }
        }
    }
    private void Run(Action action) { try { action(); } catch (Exception ex) { ShowError(ex.Message); } }
    private void ShowError(string message) { if (_closed) return; EndFastForward(); _playing = false; _preparing = false; _loadingLayer.Visibility = Visibility.Collapsed; _systemSession?.SetAwake(false); var failure = PlaybackFailure.Classify(message); PlaybackError.Title = failure.Title; PlaybackError.Message = message; PlaybackError.IsOpen = true; ShowHud(); }
    private static string TimeLabel(double seconds)
    {
        var time = TimeSpan.FromSeconds(double.IsFinite(seconds) ? Math.Max(0, seconds) : 0);
        return time.TotalHours >= 1 ? $"{(int)time.TotalHours}:{time.Minutes:00}:{time.Seconds:00}" : $"{time.Minutes}:{time.Seconds:00}";
    }
    private void ShowHud()
    {
        if (_closed) return;
        _userHidden = false;
        _lastInteraction = DateTime.UtcNow;
        _hudVisibility.Show();
    }
    private bool HasControlFocus()
    {
        // The player itself receives keyboard focus for transport shortcuts. Only a
        // focused HUD control must hold the HUD open; root focus is ordinary playback.
        if (FocusManager.GetFocusedElement(PlayerRoot.XamlRoot) is not Control { FocusState: FocusState.Keyboard } control) return false;
        DependencyObject? current = control;
        while (current is not null)
        {
            if (ReferenceEquals(current, Hud)) return true;
            current = VisualTreeHelper.GetParent(current);
        }
        return false;
    }
    private void UpdatePlayIcon()
    {
        PlayIcon.Visibility = _playing ? Visibility.Collapsed : Visibility.Visible;
        PauseIcon.Visibility = _playing ? Visibility.Visible : Visibility.Collapsed;
        var label = _playing ? "暂停" : "播放";
        AutomationProperties.SetName(PlayButton, label);
        ToolTipService.SetToolTip(PlayButton, label + " (Space)");
    }
    private void UpdateVolumeIcon()
    {
        MuteIcon.Symbol = VolumeIcon.Symbol = (_muted || Volume.Value == 0) ? Symbol.Mute : Symbol.Volume;
        VolumeLabel.Text = Math.Round(Volume.Value).ToString("0");
        AutomationProperties.SetName(MuteButton, (_muted || Volume.Value == 0) ? "取消静音" : "静音");
        ToolTipService.SetToolTip(MuteButton, (_muted || Volume.Value == 0) ? "取消静音 (M)" : "静音 (M)");
        ToolTipService.SetToolTip(VolumeButton, (_muted || Volume.Value == 0) ? "音量 · 已静音" : $"音量 · {VolumeLabel.Text}%");
    }
    private void RequestClose() => CloseRequested?.Invoke(this, EventArgs.Empty);
    private void SetPlaying(bool playing)
    {
        _viewingRecorder?.ResetClock();
        Run(() =>
        {
            if (playing && Timeline.IsEnabled && Timeline.Value >= Timeline.Maximum) SetPosition(0);
            if (_session is not null) { _session.SetPlaying(playing); _playing = _session.Playing; }
            else _playing = _demoMode && playing;
        });
        UpdatePlayIcon(); ShowHud();
    }
    private void Seek(double seconds) => Run(() => { SetPosition(Timeline.Value + seconds); ShowHud(); });
    private void SetPosition(double seconds)
    {
        _viewingRecorder?.ResetClock();
        var previous = PositionSeconds;
        seconds = Math.Clamp(seconds, 0, Math.Max(0, Timeline.Maximum - .5));
        LearnIntroFromSeek(previous, seconds);
        _session?.Seek(seconds); _updating = true; Timeline.Value = seconds; _updating = false;
    }
    private void CommitScrub() { if (!_scrubbing) return; _scrubbing = false; Run(() => SetPosition(Timeline.Value)); FinishInteraction(); }
    private void SetRate(double rate) => RunMenuAction(() => { EndFastForward(); _viewingRecorder?.ResetClock(); _session?.SetRate(rate); _rate = rate; SchedulePlaybackPreferences(); ToolTipService.SetToolTip(RateButton, $"播放设置 · {rate:0.##}×"); ShowHud(); });
    internal void ToggleFullscreen()
    {
        if (_window.AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen)
        {
            _window.AppWindow.SetPresenter(_windowedPresenter ?? OverlappedPresenter.Create());
            ShowHud();
        }
        else
        {
            SetNativeCaptionButtonsVisible(true);
            ShowHud();
            _windowedPresenter = _window.AppWindow.Presenter;
            _window.AppWindow.SetPresenter(AppWindowPresenterKind.FullScreen);
        }
        UpdateWindowChrome();
    }
    private void AddShortcut(VirtualKey key, Action action)
    {
        var shortcut = new KeyboardAccelerator { Key = key };
        shortcut.Invoked += (_, args) =>
        {
            var focus = FocusManager.GetFocusedElement(PlayerRoot.XamlRoot);
            if (_closed || focus is TextBox or PasswordBox || _menuOpen) return;
            // Keep the native keyboard behavior of focused sliders and buttons.
            if (focus is Slider { FocusState: FocusState.Keyboard } && key is VirtualKey.Left or VirtualKey.Right or VirtualKey.Up or VirtualKey.Down or VirtualKey.Space) return;
            if (focus is ButtonBase { FocusState: FocusState.Keyboard } && key is VirtualKey.Space or VirtualKey.Enter) return;
            action(); args.Handled = true;
        };
        KeyboardAccelerators.Add(shortcut);
    }
    private void WindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        if (args.DidSizeChange || args.DidPresenterChange) DispatcherQueue.TryEnqueue(() => { UpdatePlaybackClock(); UpdateWindowChrome(); });
    }
    internal void UpdateWindowChrome()
    {
        if (_closed || PlayerRoot.XamlRoot is not { } root) return;
        var appWindow = _window.AppWindow;
        var fullscreen = appWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen;
        if (!fullscreen && appWindow.TitleBar.Height > 0) _captionHeight = appWindow.TitleBar.Height;
        if (!fullscreen && appWindow.TitleBar.RightInset > 0)
        {
            _captionLeftInset = appWindow.TitleBar.LeftInset;
            _captionRightInset = appWindow.TitleBar.RightInset;
        }
        if (!fullscreen) SetNativeCaptionButtonsVisible(_hudVisibility.IsVisible);
        var scale = root.RasterizationScale;
        var narrow = PlayerRoot.ActualWidth < 560;
        BottomDock.Margin = new Thickness(narrow ? 16 : 28, 0, narrow ? 16 : 28, narrow ? 16 : 28);
        BottomDock.Spacing = narrow ? 10 : 14;
        TransportControls.Spacing = narrow ? 38 : 58;
        PlayButton.Width = PlayButton.Height = narrow ? 70 : 82;
        SkipBackButton.Width = SkipBackButton.Height = SkipForwardButton.Width = SkipForwardButton.Height = narrow ? 58 : 66;
        MediaTitle.FontSize = narrow ? 18 : 22;
        EpisodeTitle.FontSize = narrow ? 12 : 13;
        RefreshMoreInfo();
        PlayerTitleBar.Height = fullscreen || _captionHeight <= 0 ? 48 : _captionHeight / scale;
        ReturnButton.Height = FullscreenButton.Height = VolumeButton.Height = PlayerTitleBar.Height;
        ReturnButton.Width = FullscreenButton.Width = VolumeButton.Width = !fullscreen && _captionRightInset > 0 ? _captionRightInset / (3 * scale) : 46;
        TitleActions.Margin = new Thickness(fullscreen ? 0 : _captionLeftInset / scale, 0, 0, 0);
        VolumeButton.Margin = new Thickness(0, 0, fullscreen ? 0 : _captionRightInset / scale, 0);
        FullscreenIcon.Symbol = fullscreen ? Symbol.BackToWindow : Symbol.FullScreen;
        var label = fullscreen ? "退出全屏" : "全屏";
        AutomationProperties.SetName(FullscreenButton, label);
        ToolTipService.SetToolTip(FullscreenButton, label + " (F)");
        RectInt32 Bounds(FrameworkElement element)
        {
            var point = element.TransformToVisual(_window.Content as UIElement).TransformPoint(new global::Windows.Foundation.Point());
            return new RectInt32((int)(point.X * scale), (int)(point.Y * scale), (int)(element.ActualWidth * scale), (int)(element.ActualHeight * scale));
        }
        Microsoft.UI.Input.InputNonClientPointerSource.GetForWindowId(appWindow.Id).SetRegionRects(
            Microsoft.UI.Input.NonClientRegionKind.Passthrough,
            !fullscreen && Hud.IsHitTestVisible && Hud.Visibility == Visibility.Visible ? [Bounds(TitleActions), Bounds(VolumeButton)] : []);
    }
    private void ShowMenu(object sender, MenuFlyout menu)
    {
        if (_closed) return;
        var maxWidth = PlayerMenuMaxWidth;
        var presenterStyle = new Style(typeof(MenuFlyoutPresenter))
        {
            BasedOn = menu.MenuFlyoutPresenterStyle ?? (Application.Current.Resources.TryGetValue("DefaultMenuFlyoutPresenterStyle", out var defaultStyle) ? defaultStyle as Style : null)
        };
        presenterStyle.Setters.Add(new Setter(FrameworkElement.MaxWidthProperty, maxWidth));
        presenterStyle.Setters.Add(new Setter(FrameworkElement.MinWidthProperty, Math.Min(160, maxWidth)));
        menu.MenuFlyoutPresenterStyle = presenterStyle;
        menu.Placement = FlyoutPlacementMode.TopEdgeAlignedRight;
        ConstrainPlayerMenuItems(menu.Items);
        _singleTap.Stop();
        _activeMenu?.Hide();
        _activeMenu = menu;
        menu.Opened += (_, _) => { _openFlyouts.Add(menu); ShowHud(); };
        menu.Closed += (_, _) =>
        {
            _openFlyouts.Remove(menu);
            if (ReferenceEquals(_activeMenu, menu)) _activeMenu = null;
            _ignoreEscapeUntil = DateTime.UtcNow.AddMilliseconds(300);
            FinishInteraction();
        };
        menu.ShowAt((FrameworkElement)sender);
    }
    private double PlayerMenuMaxWidth => Math.Max(1, Math.Min(360, PlayerRoot.ActualWidth > 0 ? PlayerRoot.ActualWidth - 24 : 360));
    private void ConstrainPlayerMenuItems(IEnumerable<MenuFlyoutItemBase> items)
    {
        foreach (var item in items)
        {
            item.MaxWidth = Math.Max(1, PlayerMenuMaxWidth - 16);
            item.Resources["MenuFlyoutItemTextTrimming"] = TextTrimming.CharacterEllipsis;
            var text = item switch { MenuFlyoutItem row => row.Text, MenuFlyoutSubItem submenu => submenu.Text, _ => null };
            if (text is { Length: > 24 } && ToolTipService.GetToolTip(item) is null) ToolTipService.SetToolTip(item, text);
            if (item is MenuFlyoutSubItem sub) ConstrainPlayerMenuItems(sub.Items);
        }
    }
    private void BeginModalInteraction() { _modalInteractions++; _singleTap.Stop(); ShowHud(); }
    private void EndModalInteraction() { _modalInteractions = Math.Max(0, _modalInteractions - 1); FinishInteraction(); }
    private void FinishInteraction()
    {
        if (_closed) return;
        if (!_pointerInside && !_menuOpen && !_scrubbing && !HasControlFocus() && !_screenReader && _session?.Buffering != true) _hudVisibility.Hide();
        else ShowHud();
    }
    private void VolumeFlyout_Opened(object sender, object e) { _singleTap.Stop(); _openFlyouts.Add(VolumeFlyout); ShowHud(); }
    private void VolumeFlyout_Closed(object sender, object e)
    {
        _openFlyouts.Remove(VolumeFlyout);
        _ignoreEscapeUntil = DateTime.UtcNow.AddMilliseconds(300);
        FinishInteraction();
    }
    private void Video_Tapped(object sender, TappedRoutedEventArgs e)
    {
        Focus(FocusState.Programmatic);
        _singleTap.Stop(); _singleTap.Start();
        e.Handled = true;
    }
    private void Video_DoubleTapped(object sender, DoubleTappedRoutedEventArgs e)
    {
        _singleTap.Stop(); ToggleFullscreen(); e.Handled = true;
    }
    private void Player_PointerMoved(object sender, PointerRoutedEventArgs e)
    {
        var point = e.GetCurrentPoint(PlayerRoot).Position;
        _pointerInside = true;
        if (_lastPointer is { } previous && previous == point) return;
        _lastPointer = point;
        ProtectedCursor = _normalCursor; _pointerHidden = false;
        ShowHud();
    }
    private void Player_PointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (IsPointerInsideWindow()) return;
        PointerLeftPlayer();
    }
    private void Controls_PointerEntered(object sender, PointerRoutedEventArgs e)
    {
        _controlsHovered = true;
        if (!_userHidden) ShowHud();
    }
    private void Controls_PointerExited(object sender, PointerRoutedEventArgs e)
    {
        _controlsHovered = false;
        if (!_userHidden) _lastInteraction = DateTime.UtcNow;
    }
    private static void AddTransportFeedback(Button button)
    {
        if (button.Content is not FrameworkElement content) return;
        var scale = new ScaleTransform();
        content.RenderTransformOrigin = new global::Windows.Foundation.Point(.5, .5);
        content.RenderTransform = scale;
        void Press(bool pressed) { content.Opacity = pressed ? .72 : 1; scale.ScaleX = scale.ScaleY = pressed ? .94 : 1; }
        button.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => Press(true)), true);
        button.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => Press(false)), true);
        button.PointerCaptureLost += (_, _) => Press(false);
        button.PointerCanceled += (_, _) => Press(false);
        button.LostFocus += (_, _) => Press(false);
        button.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler((_, e) => { if (e.Key is VirtualKey.Space or VirtualKey.Enter) Press(true); }), true);
        button.AddHandler(UIElement.KeyUpEvent, new KeyEventHandler((_, e) => { if (e.Key is VirtualKey.Space or VirtualKey.Enter) Press(false); }), true);
    }
    private void Close_Click(object sender, RoutedEventArgs e) => RequestClose();
    private void Play_Click(object sender, RoutedEventArgs e) => SetPlaying(!_playing);
    private void Back_Click(object sender, RoutedEventArgs e) => Seek(-10);
    private void Forward_Click(object sender, RoutedEventArgs e) => Seek(10);
    private void Fullscreen_Click(object sender, RoutedEventArgs e) => ToggleFullscreen();
    private void Timeline_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (PositionLabel is not null) PositionLabel.Text = TimeLabel(e.NewValue);
        if (!_updating && !_scrubbing && _session?.Ready == true) Run(() => SetPosition(e.NewValue));
    }
    private void ToggleMute() { _muted = !_muted; Run(() => _session?.SetVolume(_muted ? 0 : Volume.Value / 100)); SchedulePlaybackPreferences(); UpdateVolumeIcon(); ShowHud(); }
    private void Mute_Click(object sender, RoutedEventArgs e) => ToggleMute();
}

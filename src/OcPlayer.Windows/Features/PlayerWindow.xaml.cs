using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media.Imaging;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.Preview;
using Windows.Graphics;
using Windows.System;

namespace OcPlayer.Windows;

public sealed partial class PlayerWindow : Window
{
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromMilliseconds(16) };
    private readonly Stopwatch _time = Stopwatch.StartNew();
    private PlaybackSession? _session;
    private SwapChainPanelHost? _surface;
    private bool _playing = true, _scrubbing, _menuOpen, _updating, _closed, _attached;
    private double _rate = 1, _previousVolume = 40, _lastDemoTick, _lastHudUpdate;
    private DateTime _lastInteraction = DateTime.UtcNow;
    private DateTime _ignoreEscapeUntil;
    private DemoMedia _media = null!;
    private PlaybackSource? _source;

    public PlayerWindow(DemoMedia media, PlaybackSource? source = null)
    {
        InitializeComponent();
        Title = App.DemoMode ? "OcPlayer · 播放器演示" : "OcPlayer · 播放器";
        ExtendsContentIntoTitleBar = true; SetTitleBar(PlayerTitleBar);
        AppWindow.ResizeClient(new SizeInt32(1130, 670));
        AppWindow.TitleBar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
        AppWindow.TitleBar.ButtonForegroundColor = Microsoft.UI.Colors.White;
        PlayerRoot.Loaded += (_, _) => { UpdateRegions(); AttachNative(); };
        PlayerRoot.SizeChanged += (_, _) => { UpdateRegions(); ResizeNative(); };
        Timeline.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => _scrubbing = true), true);
        Timeline.AddHandler(UIElement.PointerReleasedEvent, new PointerEventHandler((_, _) => CommitScrub()), true);
        Timeline.PointerCaptureLost += (_, _) => CommitScrub();
        Volume.ValueChanged += (_, args) => Run(() => _session?.SetVolume(args.NewValue / 100));
        SetMedia(media, source);
        _clock.Tick += (_, _) => Tick(); _clock.Start();
        Closed += (_, _) => Shutdown();
        AddShortcut(VirtualKey.Space, () => SetPlaying(!_playing));
        AddShortcut(VirtualKey.Left, () => Seek(-10)); AddShortcut(VirtualKey.Right, () => Seek(10));
        AddShortcut(VirtualKey.F, ToggleFullscreen); AddShortcut(VirtualKey.M, ToggleMute);
        AddShortcut(VirtualKey.Escape, () => { if (_menuOpen || DateTime.UtcNow < _ignoreEscapeUntil) return; if (AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen) ToggleFullscreen(); else Close(); });
    }

    public void SetMedia(DemoMedia media, PlaybackSource? source = null)
    {
        _updating = true; _scrubbing = false;
        _media = media; _source = source; MediaTitle.Text = media.Title;
        EpisodeTitle.Text = media.EpisodeLabel ?? (App.DemoMode ? "界面演示 · 模拟时钟" : media.Category);
        PlaybackError.IsOpen = false;
        if (App.DemoMode)
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
            if (_attached) Run(OpenNative);
        }
        _updating = false;
    }

    private void AttachNative()
    {
        if (App.DemoMode || _attached || _closed || App.Core is null) return;
        Run(() =>
        {
            _session = new PlaybackSession(App.Core.Client);
            _session.Failed += ShowError; _surface = new SwapChainPanelHost(VideoPanel);
            var (width, height, scale) = Geometry();
            var hwnd = (ulong)WinRT.Interop.WindowNative.GetWindowHandle(this).ToInt64();
            _session.Attach(hwnd, width, height, scale); _surface.Bind(_session.GetSwapChain());
            _attached = true; PlayerRoot.XamlRoot.Changed += RootChanged; OpenNative();
        });
    }

    private void OpenNative()
    {
        if (_source is null && _media.SourceUri is null) throw new InvalidOperationException("此条目没有可播放的片源。");
        _session!.Open(_source ?? new PlaybackSource(_media.Id, _media.Title, _media.SourceUri!));
        _session.SetVolume(Volume.Value / 100); _session.SetRate(_rate);
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

    private void Tick()
    {
        if (_closed) return;
        var seconds = _time.Elapsed.TotalSeconds;
        if (App.DemoMode)
        {
            if (_playing && !_scrubbing) { Timeline.Value = Math.Min(Timeline.Maximum, Timeline.Value + (seconds - _lastDemoTick) * _rate); if (Timeline.Value >= Timeline.Maximum) SetPlaying(false); }
            _lastDemoTick = seconds;
        }
        else if (_attached)
        {
            _session!.Tick(seconds); Run(() => _surface!.Bind(_session.GetSwapChain())); App.Core?.DrainEvents();
            if (seconds - _lastHudUpdate >= .2)
            {
                _lastHudUpdate = seconds; _updating = true; _playing = _session.Playing;
                PlayButton.Content = _playing ? "\uE769" : "\uE768"; Timeline.IsEnabled = _session.Ready;
                if (_session.DurationSeconds > 0) { Timeline.Maximum = _session.DurationSeconds; DurationLabel.Text = TimeLabel(Timeline.Maximum); }
                if (!_scrubbing) Timeline.Value = _session.PositionSeconds;
                _updating = false;
            }
        }
        if (_playing && !_scrubbing && !_menuOpen && DateTime.UtcNow - _lastInteraction > TimeSpan.FromSeconds(3) && !HasControlFocus()) Hud.Visibility = Visibility.Collapsed;
    }

    private void Shutdown()
    {
        if (_closed) return;
        _closed = true; _clock.Stop();
        if (_attached) PlayerRoot.XamlRoot.Changed -= RootChanged;
        try { _surface?.Dispose(); }
        finally
        {
            try { _session?.Dispose(); }
            finally { if (_session is not null) App.Core?.TrackReports(_session.ReportingCompleted); }
        }
    }
    private void Run(Action action) { try { action(); } catch (Exception ex) { ShowError(ex.Message); } }
    private void ShowError(string message) { _playing = false; PlaybackError.Message = message; PlaybackError.IsOpen = true; ShowHud(); }
    private static string TimeLabel(double seconds) => TimeSpan.FromSeconds(Math.Max(0, seconds)).ToString(seconds >= 3600 ? @"h\:mm\:ss" : @"m\:ss");
    private void ShowHud() { _lastInteraction = DateTime.UtcNow; Hud.Visibility = Visibility.Visible; }
    private bool HasControlFocus() => FocusManager.GetFocusedElement(PlayerRoot.XamlRoot) is Control;
    private void SetPlaying(bool playing)
    {
        Run(() => { if (_session is not null) { _session.SetPlaying(playing); _playing = _session.Playing; } else _playing = App.DemoMode && playing; });
        PlayButton.Content = _playing ? "\uE769" : "\uE768"; ShowHud();
    }
    private void Seek(double seconds) => Run(() => { SetPosition(Timeline.Value + seconds); ShowHud(); });
    private void SetPosition(double seconds)
    {
        seconds = Math.Clamp(seconds, 0, Timeline.Maximum);
        _session?.Seek(seconds); _updating = true; Timeline.Value = seconds; _updating = false;
    }
    private void CommitScrub() { if (!_scrubbing) return; _scrubbing = false; Run(() => SetPosition(Timeline.Value)); }
    private void SetRate(double rate) => Run(() => { _session?.SetRate(rate); _rate = rate; });
    private void ToggleFullscreen()
    {
        AppWindow.SetPresenter(AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen ? AppWindowPresenterKind.Overlapped : AppWindowPresenterKind.FullScreen);
        VolumeControls.Margin = new Thickness(0, 16, AppWindow.Presenter.Kind == AppWindowPresenterKind.FullScreen ? 24 : 150, 0); ShowHud();
    }
    private void AddShortcut(VirtualKey key, Action action)
    {
        var shortcut = new KeyboardAccelerator { Key = key };
        shortcut.Invoked += (_, args) => { var focus = FocusManager.GetFocusedElement(PlayerRoot.XamlRoot); if (focus is TextBox or PasswordBox || _menuOpen) return; action(); args.Handled = true; };
        PlayerRoot.KeyboardAccelerators.Add(shortcut);
    }
    private void UpdateRegions()
    {
        var scale = PlayerRoot.XamlRoot?.RasterizationScale ?? 1;
        RectInt32 Bounds(FrameworkElement element) { var point = element.TransformToVisual(PlayerRoot).TransformPoint(new global::Windows.Foundation.Point()); return new RectInt32((int)(point.X * scale), (int)(point.Y * scale), (int)(element.ActualWidth * scale), (int)(element.ActualHeight * scale)); }
        Microsoft.UI.Input.InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(Microsoft.UI.Input.NonClientRegionKind.Passthrough, [Bounds(TopActions), Bounds(VolumeControls)]);
    }
    private void Menu(object sender, params (string Label, Action Action)[] items)
    {
        var menu = new MenuFlyout();
        foreach (var pair in items) { var item = new MenuFlyoutItem { Text = pair.Label }; item.Click += (_, _) => Run(pair.Action); menu.Items.Add(item); }
        menu.Opened += (_, _) => { _menuOpen = true; ShowHud(); }; menu.Closed += (_, _) => { _menuOpen = false; _ignoreEscapeUntil = DateTime.UtcNow.AddMilliseconds(300); ShowHud(); }; menu.ShowAt((FrameworkElement)sender);
    }
    private void TrackMenu(object sender, bool subtitle)
    {
        if (App.DemoMode)
        {
            if (subtitle) Menu(sender, ("字幕轨道 · 关闭", () => SubtitlePreview.Visibility = Visibility.Collapsed),
                ("简体中文", () => { SubtitlePreview.Text = "字幕预览"; SubtitlePreview.Visibility = Visibility.Visible; }),
                ("English", () => { SubtitlePreview.Text = "Subtitle preview"; SubtitlePreview.Visibility = Visibility.Visible; }),
                ("字体大小 · 100%", () => SubtitlePreview.FontSize = 24));
            else Menu(sender, ("音轨 · 中文 · 立体声", () => { }), ("English · 5.1", () => { }));
            return;
        }
        var items = new List<(string, Action)>();
        if (subtitle) items.Add(("关闭字幕", () => _session?.SelectTrack(-1, true)));
        if (_session?.Tracks is { ValueKind: JsonValueKind.Array } tracks)
            foreach (var track in tracks.EnumerateArray().Where(x => x.GetProperty("kind").GetInt32() == (subtitle ? 2 : 1)))
            {
                var id = track.GetProperty("id").GetInt64();
                var title = track.GetProperty("title").GetString(); var language = track.GetProperty("language").GetString(); var codec = track.GetProperty("codec").GetString();
                items.Add(($"{(track.GetProperty("selected").GetBoolean() ? "✓ " : "")}{title ?? language ?? "轨道 " + id} · {codec}", () => _session.SelectTrack(id, subtitle)));
            }
        if (subtitle) items.Add(("加载外挂字幕…", () => PickOverlay(false)));
        if (items.Count == 0) items.Add(("没有可用音轨", () => { })); Menu(sender, items.ToArray());
    }
    private async void PickOverlay(bool danmaku)
    {
        var picker = new global::Windows.Storage.Pickers.FileOpenPicker();
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        foreach (var extension in danmaku ? new[] { ".xml", ".json" } : new[] { ".ass", ".ssa", ".srt", ".vtt" }) picker.FileTypeFilter.Add(extension);
        try { var file = await picker.PickSingleFileAsync(); if (file is not null && !_closed) { if (danmaku) _session?.LoadDanmaku(file.Path); else _session?.LoadSubtitle(file.Path); } }
        catch (Exception ex) { ShowError(ex.Message); }
    }
    private void Audio_Click(object sender, RoutedEventArgs e) => TrackMenu(sender, false);
    private void Subtitles_Click(object sender, RoutedEventArgs e) => TrackMenu(sender, true);
    private void Danmaku_Click(object sender, RoutedEventArgs e)
    {
        if (App.DemoMode) Menu(sender, ("自动加载弹幕", () => { }), ("手动匹配…", () => { }), ("显示弹幕", () => { }));
        else Menu(sender, ("加载本地弹幕…", () => PickOverlay(true)), ("显示弹幕", () => _session?.SetDanmaku(true)), ("隐藏弹幕", () => _session?.SetDanmaku(false)));
    }
    private void Chapters_Click(object sender, RoutedEventArgs e)
    {
        if (App.DemoMode) Menu(sender, ("第 1 章", () => SetPosition(0)), ("第 2 章", () => SetPosition(Timeline.Maximum * .5)));
        else Menu(sender, ("从头播放", () => SetPosition(0)));
    }
    private void More_Click(object sender, RoutedEventArgs e) => Menu(sender, ("播放速度 · 1.0×", () => SetRate(1)), ("播放速度 · 1.5×", () => SetRate(1.5)), ("播放速度 · 2.0×", () => SetRate(2)), ("从头播放", () => SetPosition(0)), ("全屏", ToggleFullscreen));
    private void Player_PointerMoved(object sender, PointerRoutedEventArgs e) => ShowHud();
    private void Close_Click(object sender, RoutedEventArgs e) => Close();
    private void Play_Click(object sender, RoutedEventArgs e) => SetPlaying(!_playing);
    private void Back_Click(object sender, RoutedEventArgs e) => Seek(-10);
    private void Forward_Click(object sender, RoutedEventArgs e) => Seek(10);
    private void Fullscreen_Click(object sender, RoutedEventArgs e) => ToggleFullscreen();
    private void Timeline_ValueChanged(object sender, Microsoft.UI.Xaml.Controls.Primitives.RangeBaseValueChangedEventArgs e)
    {
        if (PositionLabel is not null) PositionLabel.Text = TimeLabel(e.NewValue);
        if (!_updating && !_scrubbing && _session?.Ready == true) Run(() => _session.Seek(e.NewValue));
    }
    private void ToggleMute() { if (Volume.Value > 0) { _previousVolume = Volume.Value; Volume.Value = 0; MuteButton.Content = "\uE74F"; } else { Volume.Value = _previousVolume > 0 ? _previousVolume : 40; MuteButton.Content = "\uE767"; } }
    private void Mute_Click(object sender, RoutedEventArgs e) => ToggleMute();
}

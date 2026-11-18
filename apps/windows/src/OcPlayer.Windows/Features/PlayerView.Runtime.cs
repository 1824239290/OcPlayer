using System.Runtime.InteropServices;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Services;
using Windows.Media;
using Windows.System;

namespace OcPlayer.Windows;

public sealed partial class PlayerView
{
    private PlaybackSystemSession? _systemSession;
    private bool _muted, _restoringPreferences, _preparing, _fastForward, _rightDown, _pointerHidden;
    private double _rightPressedAt, _bufferingAt = -1, _bufferShownAt, _lastSystemUpdate = -1, _stallPosition, _stallSince, _lastAccessibilityCheck;
    private bool _stallReported, _screenReader;
    private Func<bool> _readScreenReader = ReadScreenReaderState;
    private readonly DispatcherTimer _preferenceSave = new() { Interval = TimeSpan.FromMilliseconds(350) };
    private Border _loadingLayer = null!, _fastForwardBadge = null!;
    private TextBlock _loadingTitle = null!;
    private ProgressRing _bufferingRing = null!;
    private InputSystemCursor? _normalCursor;
    public event EventHandler? PlaybackEnded;
    public event EventHandler? RetryRequested;
    public event Action<PlaybackFailure>? PlaybackFailed;
    public event Action<uint, uint>? VideoDimensionsAvailable;
    public double PositionSeconds => _session?.PositionSeconds ?? Timeline.Value;

    private void InitializeRuntime()
    {
        _normalCursor = InputSystemCursor.Create(InputSystemCursorShape.Arrow);
        _restoringPreferences = true;
        var preferences = !_demoMode && App.Core is { } core ? PlaybackPreferences.Load(core.DataDirectory) : new();
        _rate = preferences.Rate; _muted = preferences.Muted; Volume.Value = preferences.Volume * 100;
        _restoringPreferences = false;
        _preferenceSave.Tick += (_, _) => FlushPlaybackPreferences();
        var loading = new StackPanel { Spacing = 18, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, MaxWidth = 480 };
        loading.Children.Add(new ProgressRing { IsActive = true, Width = 42, Height = 42 });
        _loadingTitle = new TextBlock { TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, FontSize = 20 };
        loading.Children.Add(_loadingTitle);
        var cancel = new Button { Content = "取消准备", HorizontalAlignment = HorizontalAlignment.Center };
        cancel.Click += (_, _) => { CancelPreparation(); RequestClose(); };
        loading.Children.Add(cancel);
        _loadingLayer = new Border { Child = loading, Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(215, 0, 0, 0)), Visibility = Visibility.Collapsed };
        PlayerRoot.Children.Add(_loadingLayer);
        _bufferingRing = new ProgressRing { IsActive = false, Width = 48, Height = 48, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed, IsHitTestVisible = false };
        PlayerRoot.Children.Add(_bufferingRing);
        _fastForwardBadge = new Border { Child = new TextBlock { Text = "2× 快进", FontSize = 18 }, Padding = new Thickness(14, 8, 14, 8), CornerRadius = new CornerRadius(8), Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(180, 0, 0, 0)), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 76, 0, 0), Visibility = Visibility.Collapsed, IsHitTestVisible = false };
        PlayerRoot.Children.Add(_fastForwardBadge);
        var retry = new Button { Content = "重试" };
        retry.Click += (_, _) => { if (RetryRequested is not null) RetryRequested.Invoke(this, EventArgs.Empty); else RetryPlayback(); };
        PlaybackError.ActionButton = retry;
        PreviewKeyDown += PlayerKeyDown;
        PreviewKeyUp += PlayerKeyUp;
        LostFocus += (_, _) => { if (!IsKeyboardFocusWithin()) EndFastForward(); };
        _window.Activated += RuntimeWindowActivated;
        RuntimeSettings.Changed += RuntimeSettingsChanged;
        if (!_demoMode)
        {
            try
            {
                _systemSession = new PlaybackSystemSession(_window);
                _systemSession.Command += command =>
                {
                    switch (command)
                    {
                        case SystemMediaTransportControlsButton.Play: SetPlaying(true); break;
                        case SystemMediaTransportControlsButton.Pause: SetPlaying(false); break;
                        case SystemMediaTransportControlsButton.Stop: SetPlaying(false); break;
                        case SystemMediaTransportControlsButton.FastForward: Seek(10); break;
                        case SystemMediaTransportControlsButton.Rewind: Seek(-10); break;
                        case SystemMediaTransportControlsButton.Next: Seek(10); break;
                        case SystemMediaTransportControlsButton.Previous: Seek(-10); break;
                    }
                };
                _systemSession.Seek += seconds => Run(() => SetPosition(seconds));
                _systemSession.Rate += rate => SetRate(Math.Clamp(rate, .5, 2));
            }
            catch (Exception ex) { System.Diagnostics.Trace.WriteLine($"System media session: {ex.GetType().Name}"); }
        }
        InitializeSkipPrompts();
        UpdateVolumeIcon();
    }

    private bool IsKeyboardFocusWithin()
    {
        var focus = FocusManager.GetFocusedElement(XamlRoot) as DependencyObject;
        while (focus is not null) { if (ReferenceEquals(focus, this)) return true; focus = VisualTreeHelper.GetParent(focus); }
        return false;
    }
    private void RuntimeWindowActivated(object sender, WindowActivatedEventArgs args)
    { if (args.WindowActivationState == WindowActivationState.Deactivated) EndFastForward(); UpdatePlaybackClock(); }
    private void PlayerKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (_closed || _menuOpen || FocusManager.GetFocusedElement(XamlRoot) is TextBox or PasswordBox) return;
        var key = args.Key;
        if (key == VirtualKey.Right)
        {
            if (!_rightDown) { _rightDown = true; _rightPressedAt = _time.Elapsed.TotalSeconds; }
            args.Handled = true; return;
        }
        Action? action = key switch
        {
            VirtualKey.Space or VirtualKey.Enter => () => SetPlaying(!_playing),
            VirtualKey.Left or VirtualKey.J => () => Seek(-10), VirtualKey.L => () => Seek(10),
            VirtualKey.Up => () => Volume.Value = Math.Min(100, Volume.Value + 10),
            VirtualKey.Down => () => Volume.Value = Math.Max(0, Volume.Value - 10),
            VirtualKey.F => ToggleFullscreen, VirtualKey.M => ToggleMute,
            VirtualKey.Escape => () => { if (DateTime.UtcNow < _ignoreEscapeUntil) return; if (_window.AppWindow.Presenter.Kind == Microsoft.UI.Windowing.AppWindowPresenterKind.FullScreen) ToggleFullscreen(); else RequestClose(); }, _ => null
        };
        if (action is null) return;
        args.Handled = true;
        if (args.KeyStatus.WasKeyDown && key is VirtualKey.Space or VirtualKey.Enter or VirtualKey.F or VirtualKey.M or VirtualKey.Escape) return;
        action();
    }
    private void PlayerKeyUp(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key != VirtualKey.Right || !_rightDown) return;
        var tap = !_fastForward;
        EndFastForward(); if (tap) Seek(10);
        args.Handled = true;
    }
    private void EndFastForward()
    {
        _rightDown = false;
        if (!_fastForward) return;
        _fastForward = false;
        Run(() => _session?.SetRate(_rate));
        _fastForwardBadge.Visibility = Visibility.Collapsed;
    }
    private void SchedulePlaybackPreferences() { if (!_restoringPreferences) { _preferenceSave.Stop(); _preferenceSave.Start(); } }
    private void FlushPlaybackPreferences()
    {
        _preferenceSave.Stop();
        if (_demoMode || App.Core is not { } core) return;
        try { (PlaybackPreferences.Load(core.DataDirectory) with { Rate = _rate, Volume = Volume.Value / 100, Muted = _muted }).Save(core.DataDirectory); }
        catch (Exception ex) { System.Diagnostics.Trace.WriteLine($"Playback preferences: {ex.GetType().Name}"); }
    }
    public void ShowPreparation(string title)
    {
        if (_session is { Ready: true }) Run(() => _session.Stop());
        _playing = false; _systemSession?.SetAwake(false);
        _preparing = true; _loadingTitle.Text = "正在准备播放\n" + title;
        _loadingLayer.Visibility = Visibility.Visible; PlaybackError.IsOpen = false; _bufferingAt = -1;
    }
    public void ShowPreparationFailure(string message) => ShowError(message);
    public void CancelPreparation() { _preparing = false; _loadingLayer.Visibility = Visibility.Collapsed; Run(() => _session?.Stop()); }
    public void RetryPlayback(PlaybackSource? source = null)
    {
        if (_closed) return;
        source ??= _source is { } previous ? previous with { ResumeSeconds = PositionSeconds } : null;
        SetMedia(_media, source);
    }
    private void OnNativeEnded() { var generation = _mediaGeneration; DispatcherQueue.TryEnqueue(() => { if (!_closed && generation == _mediaGeneration) PlaybackEnded?.Invoke(this, EventArgs.Empty); }); }
    private void OnNativeFailure(PlaybackFailure failure) { var generation = _mediaGeneration; DispatcherQueue.TryEnqueue(() => { if (!_closed && generation == _mediaGeneration) PlaybackFailed?.Invoke(failure); }); }
    private void OnNativeDimensions(uint width, uint height) { var generation = _mediaGeneration; DispatcherQueue.TryEnqueue(() => { if (!_closed && generation == _mediaGeneration) VideoDimensionsAvailable?.Invoke(width, height); }); }
    private void RuntimeSettingsChanged(RuntimePreferences preferences) => DispatcherQueue.TryEnqueue(() => { if (!_closed) Run(() => ApplyRuntimeSettings(preferences)); });
    private void ApplyRuntimeSettings(RuntimePreferences preferences)
    {
        if (_session is null) return;
        _session.HttpReadAheadBytes = (long)preferences.NetworkBufferMiB * 1024 * 1024;
        _session.HttpBackBufferBytes = (long)preferences.BackBufferMiB * 1024 * 1024;
        _session.UserAgent = preferences.EffectiveUserAgent;
        _session.SetUpscaler(preferences.QualityEnhancement switch { "artcnn-f16" => 1, "artcnn-f32" => 2, "artcnn-f16-denoise" => 3, _ => 0 });
        ApplySubtitleStyle(preferences);
        ApplyPreferredSubtitle(true);
    }
    private void TickRuntime(double seconds)
    {
        if (_rightDown && !_fastForward && seconds - _rightPressedAt >= .35)
        { _fastForward = true; Run(() => _session?.SetRate(2)); _fastForwardBadge.Visibility = Visibility.Visible; }
        var buffering = _session?.Buffering == true && _session?.Playing == true;
        if (buffering && _bufferingAt < 0) _bufferingAt = seconds;
        if (!buffering) _bufferingAt = -1;
        var showBuffer = !_preparing && buffering && seconds - _bufferingAt >= .4;
        if (showBuffer && _bufferingRing.Visibility != Visibility.Visible) _bufferShownAt = seconds;
        if (showBuffer || _bufferingRing.IsActive && seconds - _bufferShownAt < .25) { _bufferingRing.Visibility = Visibility.Visible; _bufferingRing.IsActive = true; }
        else { _bufferingRing.Visibility = Visibility.Collapsed; _bufferingRing.IsActive = false; }
        if (_preparing && _session is { Ready: true } && (_session.HasFirstFrame || _session.VideoWidth == 0 && !HasVideoTrack()))
        { _preparing = false; _loadingLayer.Visibility = Visibility.Collapsed; }
        if (seconds - _lastAccessibilityCheck >= 2)
        { _lastAccessibilityCheck = seconds; _screenReader = _readScreenReader(); }
        if (seconds - _lastSystemUpdate >= .5)
        {
            _lastSystemUpdate = seconds;
            try { _systemSession?.Update(MediaTitle.Text, EpisodeTitle.Text, PositionSeconds, _session?.DurationSeconds ?? 0, _fastForward ? 2 : _rate, _playing && !PlaybackError.IsOpen, buffering); } catch { }
            Run(() => ApplyPreferredSubtitle());
            DetectStall(seconds);
        }
        var hidePointer = !_hudVisibility.IsVisible && !_menuOpen && _pointerInside;
        if (hidePointer != _pointerHidden) { ProtectedCursor = hidePointer ? null : _normalCursor; _pointerHidden = hidePointer; }
        TickSkipPrompt();
    }
    private double StatsNumber(string key) => _session?.Stats is { ValueKind: System.Text.Json.JsonValueKind.Object } stats && stats.TryGetProperty(key, out var v) && v.TryGetDouble(out var n) ? n : 0;
    private bool HasVideoTrack() => _session?.Tracks is { ValueKind: System.Text.Json.JsonValueKind.Array } tracks
        && tracks.EnumerateArray().Any(t => t.TryGetProperty("kind", out var k) && k.TryGetInt32(out var kind) && kind == 0);
    private void DetectStall(double seconds)
    {
        var eligible = _session is { Ready: true, Playing: true, Buffering: false } && !_scrubbing;
        if (!eligible || Math.Abs(PositionSeconds - _stallPosition) > .05)
        {
            if (_stallReported) LogPlaybackDiagnostic("stall recovered");
            _stallReported = false; _stallSince = seconds; _stallPosition = PositionSeconds; return;
        }
        if (!_stallReported && seconds - _stallSince >= 8) { _stallReported = true; LogPlaybackDiagnostic("stall: position unchanged for 8 seconds while playing without buffering"); }
    }
    private void LogPlaybackDiagnostic(string text)
    {
        AppDiagnostics.Write(text.StartsWith("stall:", StringComparison.Ordinal) ? "warning" : "info", $"{text}; position={PositionSeconds:0.00}");
    }
    private void DisposeRuntime()
    {
        EndFastForward(); FlushPlaybackPreferences();
        RuntimeSettings.Changed -= RuntimeSettingsChanged;
        _window.Activated -= RuntimeWindowActivated;
        try { _systemSession?.Dispose(); } catch (Exception ex) { AppDiagnostics.Write("warning", "释放系统媒体会话失败：" + ex.Message); }
        _systemSession = null;
        ProtectedCursor = _normalCursor;
        DisposeSkipPrompts();
    }
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SystemParametersInfo(uint action, uint parameter, [MarshalAs(UnmanagedType.Bool)] out bool value, uint flags);
    private static bool ReadScreenReaderState() => SystemParametersInfo(0x0046, 0, out var active, 0) && active;
}

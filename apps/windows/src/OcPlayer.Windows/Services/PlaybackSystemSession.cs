using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Windows.Media;
using Windows.System.Display;

namespace OcPlayer.Windows.Services;

/// One system session and one display request per visible player. Never owns the decoder.
internal sealed class PlaybackSystemSession : IDisposable
{
    private readonly SystemMediaTransportControls _controls;
    private readonly DisplayRequest _display = new();
    private readonly DispatcherQueue _dispatcher;
    private bool _awake, _disposed;
    private string _title = "", _subtitle = "";
    public event Action<SystemMediaTransportControlsButton>? Command;
    public event Action<double>? Seek;
    public event Action<double>? Rate;

    public PlaybackSystemSession(Window window)
    {
        _dispatcher = window.DispatcherQueue;
        _controls = SystemMediaTransportControlsInterop.GetForWindow(WinRT.Interop.WindowNative.GetWindowHandle(window));
        _controls.IsEnabled = _controls.IsPlayEnabled = _controls.IsPauseEnabled = true;
        _controls.IsFastForwardEnabled = _controls.IsRewindEnabled = true;
        _controls.IsNextEnabled = _controls.IsPreviousEnabled = true;
        _controls.ButtonPressed += ButtonPressed;
        _controls.PlaybackPositionChangeRequested += PositionRequested;
        _controls.PlaybackRateChangeRequested += RateRequested;
    }
    private void ButtonPressed(SystemMediaTransportControls sender, SystemMediaTransportControlsButtonPressedEventArgs args)
        => _dispatcher.TryEnqueue(() => { if (!_disposed) Command?.Invoke(args.Button); });
    private void PositionRequested(SystemMediaTransportControls sender, PlaybackPositionChangeRequestedEventArgs args)
        => _dispatcher.TryEnqueue(() => { if (!_disposed) Seek?.Invoke(args.RequestedPlaybackPosition.TotalSeconds); });
    private void RateRequested(SystemMediaTransportControls sender, PlaybackRateChangeRequestedEventArgs args)
        => _dispatcher.TryEnqueue(() => { if (!_disposed) Rate?.Invoke(args.RequestedPlaybackRate); });

    public void Update(string title, string subtitle, double position, double duration, double rate, bool playing, bool buffering)
    {
        if (_disposed) return;
        SetAwake(playing && !buffering);
        if (_title != title || _subtitle != subtitle)
        {
            _title = title; _subtitle = subtitle;
            var updater = _controls.DisplayUpdater;
            updater.Type = MediaPlaybackType.Video;
            updater.VideoProperties.Title = title;
            updater.VideoProperties.Subtitle = subtitle;
            updater.Update();
        }
        _controls.PlaybackStatus = playing ? MediaPlaybackStatus.Playing : MediaPlaybackStatus.Paused;
        _controls.PlaybackRate = rate;
        _controls.UpdateTimelineProperties(new SystemMediaTransportControlsTimelineProperties
        {
            StartTime = TimeSpan.Zero, MinSeekTime = TimeSpan.Zero,
            EndTime = TimeSpan.FromSeconds(Math.Max(0, duration)), MaxSeekTime = TimeSpan.FromSeconds(Math.Max(0, duration - .5)),
            Position = TimeSpan.FromSeconds(Math.Clamp(position, 0, Math.Max(0, duration)))
        });
    }
    public void SetAwake(bool awake)
    {
        if (_awake == awake) return;
        if (awake) _display.RequestActive(); else _display.RequestRelease();
        _awake = awake;
    }
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        SetAwake(false);
        _controls.ButtonPressed -= ButtonPressed;
        _controls.PlaybackPositionChangeRequested -= PositionRequested;
        _controls.PlaybackRateChangeRequested -= RateRequested;
        _controls.PlaybackStatus = MediaPlaybackStatus.Closed;
        _controls.DisplayUpdater.ClearAll();
        _controls.DisplayUpdater.Update();
        _controls.IsEnabled = false;
    }
}

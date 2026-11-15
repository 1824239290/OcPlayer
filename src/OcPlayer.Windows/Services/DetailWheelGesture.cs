namespace OcPlayer.Windows.Services;

internal enum DetailWheelAction { Scroll, Consume, Flip }

// Windows exposes wheel deltas but no touchpad gesture phase on this event.
// A normal wheel tick is independent; smooth input uses macOS's 120 ms gap.
internal sealed class DetailWheelGesture(bool bodyPage)
{
    private long _lastEvent;
    private bool _armed;
    private int _pendingDelta;

    public DetailWheelAction Handle(int delta, bool atTop, long timestamp)
    {
        if (delta == 0) return DetailWheelAction.Scroll;
        var newGesture = _lastEvent == 0 || timestamp - _lastEvent >= 120 || Math.Abs(delta) >= 120;
        _lastEvent = timestamp;
        if (newGesture) { _armed = !bodyPage || atTop; _pendingDelta = 0; }
        if (bodyPage && !atTop) { _armed = false; _pendingDelta = 0; return DetailWheelAction.Scroll; }
        var towardOtherPage = bodyPage ? delta > 0 : delta < 0;
        if (!towardOtherPage)
        {
            _pendingDelta = 0; _armed = false;
            return bodyPage ? DetailWheelAction.Scroll : DetailWheelAction.Consume;
        }
        if (!_armed) return DetailWheelAction.Consume;
        _pendingDelta += Math.Abs(delta);
        if (_pendingDelta < (bodyPage ? 18 : 5)) return DetailWheelAction.Consume;
        _armed = false; _pendingDelta = 0;
        return DetailWheelAction.Flip;
    }
}

namespace OcPlayer.CoreAdapter;

/// Interpolates native progress for animation only. Persistence and transport UI
/// continue to use the reported position. All timestamps are monotonic seconds.
internal sealed class PlaybackRenderClock
{
    private double _position, _anchor, _lastSample, _correction, _correctionDuration;
    private double _rate = 1;
    private bool _running;

    public double Position(double now)
    {
        if (!_running) return _position;
        // Do not let comments run indefinitely if native progress stops arriving.
        var elapsed = Math.Min(now, _lastSample + .5) - _anchor;
        return Math.Max(0, _position + elapsed * _rate
            + (_correctionDuration > 0 ? _correction * Math.Clamp(elapsed / _correctionDuration, 0, 1) : 0));
    }

    public void Reset(double position, double now)
    {
        _position = position;
        _anchor = _lastSample = now;
        _correction = _correctionDuration = 0;
    }

    public void Synchronize(double position, double now)
    {
        var current = Position(now);
        var error = position - current;
        if (!_running || Math.Abs(error) > .5)
        {
            Reset(position, now);
            return;
        }
        _position = current;
        _anchor = _lastSample = now;
        _correction = error;
        // Small timestamp/dispatch errors change speed by at most 2%, rather
        // than jumping backwards at each roughly 100 ms native progress event.
        _correctionDuration = Math.Max(.25, Math.Abs(error) / (_rate * .02));
    }

    public void SetRunning(bool running, double now)
    {
        if (_running == running) return;
        Reset(Position(now), now);
        _running = running;
    }

    public void SetRate(double rate, double now)
    {
        Reset(Position(now), now);
        _rate = rate;
    }
}

using System.Text.Json;

namespace OcPlayer.CoreAdapter;

public sealed record PlaybackSource(string Id, string Title, string Uri, string TenantId = "local",
    double ResumeSeconds = 0, IReadOnlyDictionary<string, string>? HttpHeaders = null, PlaybackReport? Report = null);
public sealed record PlaybackReport(JsonElement Profile, string ItemId, string? MediaSourceId, string? PlaySessionId);

/// Coordinates Core policy/persistence with actual native decoder feedback.
/// Commands and render ticks are serialized by the window's UI dispatcher.
public sealed class PlaybackSession(OcpCoreClient core) : IDisposable
{
    private readonly ErikaPresenter _presenter = new();
    private PlaybackSource? _source;
    private bool _ready, _attached, _ended, _failed, _disposed;
    private double _resume, _lastSave;
    public double PositionSeconds { get; private set; }
    public double DurationSeconds { get; private set; }
    public bool Playing { get; private set; }
    public bool Ready => _ready;
    public JsonElement Stats { get; private set; }
    public JsonElement Tracks { get; private set; }
    public Task ReportingCompleted { get; private set; } = Task.CompletedTask;
    public string? ReportingError { get; private set; }
    public event Action<string>? Failed;

    public void Attach(ulong hwnd, uint width, uint height, double scale)
    {
        _presenter.Attach(hwnd, width, height, scale);
        try { core.AttachSurface(hwnd, width, height, scale); }
        catch { _presenter.Detach(); throw; }
        _attached = true;
    }

    public void Resize(uint width, uint height, double scale)
    {
        _presenter.Resize(width, height, scale);
        core.ResizeSurface(width, height, scale);
    }

    public IntPtr GetSwapChain() => _presenter.GetSwapChain();

    public void Open(PlaybackSource source)
    {
        if (_source is not null) Stop();
        _source = source;
        _ready = _ended = _failed = false;
        Playing = false;
        PositionSeconds = DurationSeconds = _lastSave = 0;
        Tracks = default;
        _resume = source.ResumeSeconds;
        var saved = Require(core.Call("progress.get", new { tenantId = source.TenantId, itemId = source.Id }));
        if (saved.GetProperty("progress") is { ValueKind: JsonValueKind.Object } progress &&
            !progress.GetProperty("completed").GetBoolean())
            _resume = progress.GetProperty("positionSeconds").GetDouble();
        Require(core.Call("playback.open", new { source = source.Uri }));
        try
        {
            _presenter.Invoke("open", new { uri = source.Uri, httpHeaders = source.HttpHeaders ?? new Dictionary<string, string>() });
            // Opening is asynchronous. Play is requested only after native Ready.
        }
        catch (Exception ex) { ReportFailure(ex.Message); throw; }
    }

    public void Tick(double seconds)
    {
        if (_disposed || !_attached || _source is null || _failed) return;
        try
        {
            Stats = _presenter.RenderTick(seconds);
            core.RenderTick(seconds);
            while (_presenter.PollEvent() is { } value) HandleEvent(value);
            if (_ready && !_ended && seconds - _lastSave >= 5)
            {
                SaveProgress();
                _lastSave = seconds;
            }
        }
        catch (Exception ex) { ReportFailure(ex.Message); }
    }

    private void HandleEvent(JsonElement value)
    {
        switch (value.GetProperty("kind").GetInt32())
        {
            case 1:
                var state = value.GetProperty("state").GetInt32();
                if (state == 2 && !_ready)
                {
                    _ready = true;
                    Require(core.Call("playback.ready", new { durationSeconds = DurationSeconds > 0 ? (double?)DurationSeconds : null }));
                    Tracks = _presenter.Invoke("tracks");
                    if (_resume > 0) Seek(_resume);
                    SetPlaying(true);
                    QueueReport("report.start");
                }
                else if (state is 3 or 4) Playing = state == 3;
                else if (state == 5 && _ready && !_ended)
                {
                    _ended = true;
                    Playing = false;
                    Require(core.Call("playback.ended"));
                    SaveProgress();
                    QueueReport("report.stopped");
                }
                break;
            case 2:
                DurationSeconds = value.GetProperty("durationMicros").GetUInt64() / 1_000_000d;
                if (_ready) Require(core.Call("playback.position", new { positionSeconds = PositionSeconds, durationSeconds = DurationSeconds }));
                break;
            case 3:
                PositionSeconds = value.GetProperty("positionMicros").GetUInt64() / 1_000_000d;
                Require(core.Call("playback.position", new { positionSeconds = PositionSeconds, durationSeconds = DurationSeconds > 0 ? (double?)DurationSeconds : null }));
                break;
            case 4:
            case 10:
                Tracks = _presenter.Invoke("tracks");
                break;
            case 9:
                ReportFailure(value.TryGetProperty("message", out var message) ? message.GetString() ?? "播放失败" : "播放失败");
                break;
        }
    }

    public void SetPlaying(bool playing)
    {
        if (!_ready) return;
        _presenter.Invoke(playing ? "play" : "pause");
        Require(core.Call(playing ? "playback.play" : "playback.pause"));
        Playing = playing;
        if (!playing) SaveProgress();
    }

    public void Seek(double seconds)
    {
        if (!_ready || !double.IsFinite(seconds)) return;
        seconds = Math.Clamp(seconds, 0, DurationSeconds > 0 ? DurationSeconds : double.MaxValue);
        _presenter.Invoke("seek", new { positionMicros = checked((ulong)(seconds * 1_000_000)) });
        Require(core.Call("playback.seek", new { positionSeconds = seconds }));
        PositionSeconds = seconds;
        _ended = false;
    }

    public void SetVolume(double volume)
    {
        _presenter.Invoke("setVolume", new { volume });
        Require(core.Call("playback.setVolume", new { volume }));
    }

    public void SetRate(double rate)
    {
        _presenter.Invoke("setPlaybackRate", new { rate });
        Require(core.Call("playback.setRate", new { rate }));
    }

    public void SelectTrack(long id, bool subtitle)
    {
        _presenter.Invoke(subtitle ? "selectSubtitleTrack" : "selectAudioTrack", new { trackId = id });
        Require(core.Call(subtitle ? "playback.selectSubtitle" : "playback.selectAudio", new { trackId = id < 0 ? null : id.ToString(System.Globalization.CultureInfo.InvariantCulture) }));
        Tracks = _presenter.Invoke("tracks");
    }

    public void LoadSubtitle(string uri) => _presenter.Invoke("addExternalSubtitle", new { uri });
    public void LoadDanmaku(string uri) => _presenter.Invoke("loadDanmakuFile", new { uri });
    public void SetDanmaku(bool enabled) => _presenter.Invoke("setDanmakuEnabled", new { enabled });

    public void SaveProgress()
    {
        if (_source is null || !_ready) return;
        Require(core.Call("progress.save", new { tenantId = _source.TenantId, itemId = _source.Id,
            positionSeconds = PositionSeconds, durationSeconds = DurationSeconds > 0 ? (double?)DurationSeconds : null,
            completed = _ended, played = _ended,
            item = new { id = _source.Id, title = _source.Title } }));
        if (!_ended) QueueReport("report.progress");
    }

    public void Stop()
    {
        if (_source is null) return;
        SaveProgress();
        if (_ready && !_ended) QueueReport("report.stopped");
        try { _presenter.Invoke("stop"); }
        catch (InvalidOperationException) when (!_ready || _failed) { /* Failed opens have no native media to stop. */ }
        Require(core.Call("playback.stop"));
        _source = null;
        _ready = Playing = false;
        while (_presenter.PollEvent() is not null) { }
    }

    private void ReportFailure(string message)
    {
        if (_failed) return;
        _failed = true;
        Playing = false;
        _ = core.Call("playback.failed", new { category = "decode", message, retryable = false });
        Failed?.Invoke(message);
    }

    private void QueueReport(string method)
    {
        if (_source?.Report is not { } report) return;
        var arguments = new { profile = report.Profile, itemId = report.ItemId, mediaSourceId = report.MediaSourceId,
            playSessionId = report.PlaySessionId, positionSeconds = PositionSeconds, paused = !Playing, playMethod = "DirectPlay" };
        // Preserve start/progress/stop ordering without blocking the render thread.
        ReportingCompleted = ReportingCompleted.ContinueWith(async _ =>
        {
            try { Require(await core.CallAsync(method, arguments).ConfigureAwait(false)); }
            catch (Exception ex) { ReportingError = ex.Message; }
        }, CancellationToken.None, TaskContinuationOptions.None, TaskScheduler.Default).Unwrap();
    }

    public void Dispose()
    {
        if (_disposed) return;
        try { Stop(); }
        finally
        {
            try { if (_attached) { core.DetachSurface(); _presenter.Detach(); } }
            finally { _presenter.Dispose(); _disposed = true; }
        }
    }

    public static JsonElement Require(OcpResponse response)
    {
        if (!response.Ok) throw new InvalidOperationException($"{response.Message} ({response.Code})");
        return response.Data;
    }
}

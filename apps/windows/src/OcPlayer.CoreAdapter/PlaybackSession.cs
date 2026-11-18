using System.Diagnostics;
using System.Text.Json;

namespace OcPlayer.CoreAdapter;

public sealed record PlaybackSource(string Id, string Title, string Uri, string TenantId = "local",
    double ResumeSeconds = 0, IReadOnlyDictionary<string, string>? HttpHeaders = null, PlaybackReport? Report = null,
    PlaybackMetadata? Metadata = null);
public sealed record PlaybackReport(JsonElement Profile, string ItemId, string? MediaSourceId, string? PlaySessionId);
public sealed record PlaybackMetadata(string? FileName, long? FileSize, double? DurationSeconds,
    string? AnimeTitle, string? OriginalTitle, int? EpisodeNumber, int? SeasonNumber,
    long? TmdbId = null, long? SeriesTmdbId = null, bool IsMovie = false);

/// Coordinates Core policy/persistence with actual native decoder feedback.
/// Commands and render ticks are serialized by the window's UI dispatcher.
public sealed class PlaybackSession(OcpCoreClient core) : IDisposable
{
    private readonly ErikaPresenter _presenter = new();
    private readonly PlaybackRenderClock _renderClock = new();
    private static double ClockSeconds => (double)Stopwatch.GetTimestamp() / Stopwatch.Frequency;
    private PlaybackSource? _source;
    private bool _ready, _attached, _ended, _failed, _disposed;
    private double _resume, _lastSave;
    private DateTime _openStarted;
    private double _openedRenderedFrames;
    public double PositionSeconds { get; private set; }
    /// Continuous position for app-layer animation, bounded by native feedback.
    public double RenderPositionSeconds => RenderPositionAt(ClockSeconds);
    public double RenderPositionAt(double monotonicSeconds) => Math.Min(DurationSeconds > 0 ? DurationSeconds : double.MaxValue, _renderClock.Position(monotonicSeconds));
    public double DurationSeconds { get; private set; }
    public bool Playing { get; private set; }
    public bool Ready => _ready;
    public JsonElement Stats { get; private set; }
    public JsonElement Tracks { get; private set; }
    public int PlaybackState { get; private set; }
    public bool Buffering { get; private set; }
    public bool HasSurface { get; private set; }
    public uint VideoWidth { get; private set; }
    public uint VideoHeight { get; private set; }
    public int VideoPrimaries { get; private set; }
    public int VideoTransfer { get; private set; }
    public int DolbyVisionProfile { get; private set; }
    public JsonElement DecoderInfo { get; private set; }
    public JsonElement AudioOutputInfo { get; private set; }
    public double SubtitleScale { get; private set; } = 1;
    public Task ReportingCompleted { get; private set; } = Task.CompletedTask;
    public string? ReportingError { get; private set; }
    public event Action<string>? Failed;
    public event Action<PlaybackFailure>? Failure;
    public event Action? Ended;
    public event Action<uint, uint>? VideoDimensionsChanged;
    public bool HasEnded => _ended;
    public bool HasFirstFrame { get; private set; }
    public int TracksRevision { get; private set; }
    public long HttpReadAheadBytes { get; set; } = 2 * 1024 * 1024;
    public long HttpBackBufferBytes { get; set; } = 16 * 1024 * 1024;
    public string UserAgent { get; set; } = "";

    public void Attach(ulong hwnd, uint width, uint height, double scale)
    {
        _presenter.Attach(hwnd, width, height, scale);
        try { core.AttachSurface(hwnd, width, height, scale); }
        catch { _presenter.Detach(); throw; }
        _attached = HasSurface = true;
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
        _openStarted = DateTime.UtcNow;
        HasFirstFrame = false;
        var counters = _presenter.Invoke("getPresenterStats");
        _openedRenderedFrames = counters.TryGetProperty("renderedVideoFrames", out var rendered) ? rendered.GetDouble() : 0;
        _ready = _ended = _failed = false;
        Playing = false;
        PositionSeconds = DurationSeconds = _lastSave = 0;
        _renderClock.SetRunning(false, ClockSeconds);
        _renderClock.Reset(0, ClockSeconds);
        Tracks = default;
        PlaybackState = 1; Buffering = false;
        VideoWidth = VideoHeight = 0; VideoPrimaries = VideoTransfer = DolbyVisionProfile = 0;
        DecoderInfo = AudioOutputInfo = Stats = default;
        _resume = source.ResumeSeconds;
        var saved = Require(core.Call("progress.get", new { tenantId = source.TenantId, itemId = source.Id }));
        if (_resume <= 0 && saved.GetProperty("progress") is { ValueKind: JsonValueKind.Object } progress &&
            !progress.GetProperty("completed").GetBoolean())
            _resume = progress.GetProperty("positionSeconds").GetDouble();
        Require(core.Call("playback.open", new { source = source.Uri }));
        try
        {
            // A presenter is reused across episodes. Neither tracks nor a manual time correction may leak into the next one.
            ClearDanmaku();
            SetDanmakuOffset(0);
            var headers = source.HttpHeaders is null ? new Dictionary<string, string>() : new Dictionary<string, string>(source.HttpHeaders);
            if (!string.IsNullOrWhiteSpace(UserAgent)) headers["User-Agent"] = UserAgent;
            _presenter.Invoke("open", new { uri = source.Uri, httpHeaders = headers, httpReadAheadBytes = HttpReadAheadBytes, httpBackBufferBytes = HttpBackBufferBytes });
            // Opening is asynchronous. Play is requested only after native Ready.
        }
        catch (Exception ex) { ReportFailure(ex.Message); throw; }
    }

    public void Tick(double seconds, double? presentationTimestamp = null)
    {
        if (_disposed || !_attached || _source is null || _failed) return;
        if (!_ready && DateTime.UtcNow - _openStarted >= TimeSpan.FromSeconds(60))
        {
            try { _presenter.Invoke("stop"); } catch { }
            ReportFailure("打开片源超时（超过 60 秒），请检查网络后重试。");
            return;
        }
        try
        {
            Stats = _presenter.RenderTick(seconds, presentationTimestamp);
            if (Stats.TryGetProperty("renderedVideoFrames", out var frames) && frames.TryGetDouble(out var count) && count > 0 && count != _openedRenderedFrames) HasFirstFrame = true;
            core.RenderTick(seconds);
            var clockTimestamp = presentationTimestamp ?? ClockSeconds;
            while (_presenter.PollEvent() is { } value) HandleEvent(value, clockTimestamp);
            if (_ready && !_ended && seconds - _lastSave >= 5)
            {
                SaveProgress();
                _lastSave = seconds;
            }
        }
        catch (Exception ex) { ReportFailure(ex.Message); }
    }

    private void HandleEvent(JsonElement value, double clockTimestamp)
    {
        switch (value.GetProperty("kind").GetInt32())
        {
            case 1:
                var state = value.GetProperty("state").GetInt32();
                PlaybackState = state;
                if (state == 2 && !_ready)
                {
                    _ready = true;
                    Require(core.Call("playback.ready", new { durationSeconds = DurationSeconds > 0 ? (double?)DurationSeconds : null }));
                    Tracks = _presenter.Invoke("tracks");
                    TracksRevision++;
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
                    Ended?.Invoke();
                }
                break;
            case 2:
                DurationSeconds = value.GetProperty("durationMicros").GetUInt64() / 1_000_000d;
                if (_ready) Require(core.Call("playback.position", new { positionSeconds = PositionSeconds, durationSeconds = DurationSeconds }));
                break;
            case 3:
                PositionSeconds = value.GetProperty("positionMicros").GetUInt64() / 1_000_000d;
                // Anchor feedback on the same display timeline used for drawing.
                // Anchoring after the native call would revise an already sampled
                // past frame when the display target precedes event dispatch.
                _renderClock.Synchronize(PositionSeconds, clockTimestamp);
                Require(core.Call("playback.position", new { positionSeconds = PositionSeconds, durationSeconds = DurationSeconds > 0 ? (double?)DurationSeconds : null }));
                break;
            case 4:
            case 10:
                Tracks = _presenter.Invoke("tracks");
                TracksRevision++;
                break;
            case 5:
                Buffering = value.GetProperty("buffering").GetBoolean();
                break;
            case 6:
                var video = value.GetProperty("video");
                VideoWidth = video.GetProperty("width").GetUInt32();
                VideoHeight = video.GetProperty("height").GetUInt32();
                VideoPrimaries = video.GetProperty("primaries").GetInt32();
                VideoTransfer = video.GetProperty("transfer").GetInt32();
                if (video.TryGetProperty("dolbyVisionProfile", out var profile) && profile.ValueKind == JsonValueKind.Number && profile.TryGetInt32(out var dv) && dv > 0) DolbyVisionProfile = dv;
                VideoDimensionsChanged?.Invoke(VideoWidth, VideoHeight);
                break;
            case 7: HasSurface = true; break;
            case 8: HasSurface = false; break;
            case 11:
                DecoderInfo = value.TryGetProperty("decoder", out var decoder) ? decoder.Clone() : default;
                if (DecoderInfo.ValueKind == JsonValueKind.Object && DecoderInfo.TryGetProperty("dolbyVisionProfile", out var dovi) && dovi.ValueKind == JsonValueKind.Number && dovi.TryGetInt32(out var decodedProfile) && decodedProfile > 0)
                    DolbyVisionProfile = decodedProfile;
                break;
            case 12:
                AudioOutputInfo = value.TryGetProperty("audio", out var audio) ? audio.Clone() : default;
                break;
            case 9:
                ReportFailure(value.TryGetProperty("error", out var error) ? error.GetString() ?? "播放失败" : value.TryGetProperty("message", out var message) ? message.GetString() ?? "播放失败" : "播放失败");
                break;
        }
        UpdateRenderClock(clockTimestamp);
    }

    private void UpdateRenderClock(double? clockTimestamp = null) => _renderClock.SetRunning(_ready && Playing && !Buffering && !_ended && !_failed, clockTimestamp ?? ClockSeconds);

    public void SetPlaying(bool playing)
    {
        if (!_ready) return;
        _presenter.Invoke(playing ? "play" : "pause");
        Require(core.Call(playing ? "playback.play" : "playback.pause"));
        Playing = playing;
        UpdateRenderClock();
        if (!playing) SaveProgress();
    }

    public void Seek(double seconds)
    {
        if (!_ready || !double.IsFinite(seconds)) return;
        seconds = Math.Clamp(seconds, 0, DurationSeconds > 0 ? Math.Max(0, DurationSeconds - .5) : double.MaxValue);
        _presenter.Invoke("seek", new { positionMicros = checked((ulong)(seconds * 1_000_000)) });
        Require(core.Call("playback.seek", new { positionSeconds = seconds }));
        PositionSeconds = seconds;
        _renderClock.Reset(seconds, ClockSeconds);
        _ended = false;
        UpdateRenderClock();
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
        _renderClock.SetRate(rate, ClockSeconds);
    }

    public void SelectTrack(long id, bool subtitle)
    {
        _presenter.Invoke(subtitle ? "selectSubtitleTrack" : "selectAudioTrack", new { trackId = id });
        Require(core.Call(subtitle ? "playback.selectSubtitle" : "playback.selectAudio", new { trackId = id < 0 ? null : id.ToString(System.Globalization.CultureInfo.InvariantCulture) }));
        Tracks = _presenter.Invoke("tracks");
        TracksRevision++;
    }

    public long LoadSubtitle(string uri)
    {
        var id = _presenter.Invoke("addExternalSubtitle", new { uri }).GetInt64();
        Tracks = _presenter.Invoke("tracks");
        TracksRevision++;
        Require(core.Call("playback.selectSubtitle", new { trackId = id.ToString(System.Globalization.CultureInfo.InvariantCulture) }));
        return id;
    }
    public void RemoveSubtitle(long id)
    {
        _presenter.Invoke("removeSubtitleTrack", new { trackId = id });
        Tracks = _presenter.Invoke("tracks");
        TracksRevision++;
        var selected = Tracks.EnumerateArray().FirstOrDefault(track => track.GetProperty("kind").GetInt32() == 2
            && track.GetProperty("selected").GetBoolean());
        Require(core.Call("playback.selectSubtitle", new { trackId = selected.ValueKind == JsonValueKind.Object
            ? selected.GetProperty("id").GetInt64().ToString(System.Globalization.CultureInfo.InvariantCulture) : null }));
    }
    public void SetUpscaler(int mode) => _presenter.Invoke("setUpscaler", new { mode });
    public void SetSubtitleStyle(ErikaPresenter.SubtitleStyle style) => _presenter.SetSubtitleStyle(style);
    public void SetSubtitleScale(double scale)
    {
        if (!double.IsFinite(scale) || scale is < .5 or > 3) throw new ArgumentOutOfRangeException(nameof(scale));
        _presenter.Invoke("setSubtitleScale", new { scale });
        SubtitleScale = scale;
    }
    public byte[] CaptureFrameRgba(uint width, uint height) => _presenter.CaptureFrameRgba(width, height);
    public JsonElement GetOutputStatus() => _presenter.Invoke("getOutputStatus");
    public JsonElement GetResourceStatus() => _presenter.Invoke("getResourceStatus");
    public void LoadDanmaku(string uri) => _presenter.Invoke("loadDanmakuFile", new { uri });
    public void SetDanmaku(bool enabled) => _presenter.Invoke("setDanmakuEnabled", new { enabled });
    public void ConfigureDanmaku(object configuration) => _presenter.Invoke("setDanmakuConfig", configuration);
    public void ClearDanmaku() => _presenter.Invoke("clearDanmaku");
    public void LoadDanmakuJson(string json) => _presenter.Invoke("loadDanmakuJson", new { json });
    public JsonElement DanmakuTracks => _presenter.Invoke("danmakuTracks");
    public void SetDanmakuOffset(double seconds)
    {
        if (!double.IsFinite(seconds)) throw new ArgumentOutOfRangeException(nameof(seconds));
        _presenter.Invoke("setDanmakuGlobalOffset", new { offsetMicros = checked((long)(seconds * 1_000_000)) });
    }

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
        UpdateRenderClock();
        PlaybackState = 5; Buffering = false;
        while (_presenter.PollEvent() is not null) { }
    }

    private void ReportFailure(string message)
    {
        if (_failed) return;
        _failed = true;
        Playing = false;
        PlaybackState = 7;
        Buffering = false;
        UpdateRenderClock();
        var failure = PlaybackFailure.Classify(message);
        _ = core.Call("playback.failed", new { category = failure.Category switch { "auth" => "unauthorized", "server" => "network", _ => failure.Category }, message, retryable = failure.Retryable, stopsAutomaticRecovery = !failure.CanTryAlternateSource });
        Failed?.Invoke(message);
        Failure?.Invoke(failure);
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

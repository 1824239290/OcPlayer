namespace OcPlayer.Windows.Services;

/// All host actions run on the caller's UI context. Every await is guarded against a replaced source or manual choice.
internal sealed class DanmakuCoordinator(
    Func<DanmakuContext, bool, DanmakuEpisode?, CancellationToken, Task<DanmakuPayload>> load,
    Func<bool> ready, Action<DanmakuPayload> apply, Action clear) : IDisposable
{
    private CancellationTokenSource? _load;
    private long _generation;
    private bool _disposed;
    private string? _matchContextKey;
    public string Status { get; private set; } = "等待加载";
    public bool Busy { get; private set; }
    public DanmakuEpisode? CurrentMatch { get; private set; }
    public Task Completion { get; private set; } = Task.CompletedTask;
    public int ElapsedSeconds { get; private set; }
    public event Action<DanmakuPayload>? PayloadReceived;
    public event Action? Changed;

    public void Start(DanmakuContext context, bool enabled, bool force = false, DanmakuEpisode? manual = null)
    {
        Cancel(resetMatch: _matchContextKey != context.CacheKey);
        if (_disposed) return;
        if (!enabled && !force && manual is null) { SetStatus("自动加载已关闭"); return; }
        var cancellation = _load = new CancellationTokenSource(TimeSpan.FromSeconds(60));
        var generation = _generation;
        SetStatus(manual is null ? "正在匹配弹幕…" : "正在获取弹幕…", true);
        Completion = Run(async token =>
        {
            var payload = await load(context, force, manual, token);
            await WaitReady(token);
            if (!Current(generation)) return;
            PayloadReceived?.Invoke(payload);
            if (payload.Kind == "loaded" && !string.IsNullOrEmpty(payload.Json)) apply(payload);
            else clear();
            CurrentMatch = payload.Kind is "loaded" or "empty" ? payload.Match : null;
            _matchContextKey = CurrentMatch is null ? null : context.CacheKey;
            SetStatus(payload.Kind switch { "loaded" => $"{payload.Title} · {payload.Count} 条", "empty" => $"{payload.Title} · 暂无弹幕", _ => "未匹配到剧集，可手动搜索" });
        }, cancellation, generation);
    }

    public void LoadLocal(string path, Action<string> import)
    {
        Cancel(resetMatch: false);
        if (_disposed) return;
        var cancellation = _load = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var generation = _generation;
        SetStatus("正在加载本地弹幕…", true);
        Completion = Run(async token =>
        {
            await WaitReady(token);
            if (!Current(generation)) return;
            import(path);
            CurrentMatch = null;
            _matchContextKey = null;
            SetStatus("本地弹幕 · " + Path.GetFileName(path));
        }, cancellation, generation);
    }

    private async Task Run(Func<CancellationToken, Task> operation, CancellationTokenSource cancellation, long generation)
    {
        using var elapsed = CancellationTokenSource.CreateLinkedTokenSource(cancellation.Token);
        var status = Status.TrimEnd('…');
        var timer = UpdateElapsed(status, generation, elapsed.Token);
        try { await operation(cancellation.Token); }
        catch (OperationCanceledException) { if (Current(generation)) SetStatus("弹幕加载超时，可重试或手动选择"); }
        catch (Exception ex) { if (Current(generation)) SetStatus(ex.Message); }
        finally
        {
            elapsed.Cancel();
            await timer;
            if (ReferenceEquals(_load, cancellation)) _load = null;
            cancellation.Dispose();
        }
    }
    private async Task UpdateElapsed(string status, long generation, CancellationToken token)
    {
        var started = System.Diagnostics.Stopwatch.StartNew(); ElapsedSeconds = 0;
        try { while (true) { await Task.Delay(1000, token); if (!Current(generation) || !Busy) return;
            ElapsedSeconds = (int)started.Elapsed.TotalSeconds; Status = $"{status} · {ElapsedSeconds}s"; Changed?.Invoke(); } }
        catch (OperationCanceledException) { }
    }
    private async Task WaitReady(CancellationToken token)
    {
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (!ready())
        {
            token.ThrowIfCancellationRequested();
            if (DateTime.UtcNow >= deadline) throw new InvalidOperationException("播放器尚未就绪，请在开始播放后重试弹幕。");
            await Task.Delay(50, token);
        }
        token.ThrowIfCancellationRequested();
    }
    private bool Current(long generation) => !_disposed && generation == _generation;
    private void SetStatus(string status, bool busy = false) { Status = status; Busy = busy; Changed?.Invoke(); }
    public void Cancel(bool resetMatch = true)
    {
        _generation++; _load?.Cancel(); _load = null; Busy = false;
        if (resetMatch) { CurrentMatch = null; _matchContextKey = null; }
    }
    public void Dispose() { _disposed = true; Cancel(); }
}

#if DEBUG
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows.Preview;

/// Measures the shipping player on its real UI dispatcher, decoder and swap chain.
internal sealed class DanmakuCadenceVerification : Window
{
    private sealed record Sample(double Seconds, double Position, double RenderPosition, long Frames, Dictionary<string, double> Left,
        double? NativeTime = null, uint? SubmittedPresents = null, uint? DisplayedPresents = null, double? NativeDanmakuTime = null,
        double? DisplaySeconds = null, double? DisplayPosition = null);
    [StructLayout(LayoutKind.Sequential)]
    private struct FrameStatistics
    {
        public uint PresentCount, PresentRefreshCount, SyncRefreshCount;
        public long SyncQpcTime, SyncGpuTime;
    }
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetFrameStatistics(IntPtr swapChain, out FrameStatistics statistics);
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate int GetLastPresentCount(IntPtr swapChain, out uint count);
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public DanmakuCadenceVerification(string mediaPath, string directory, string resource)
    {
        Title = "弹幕刷新与播放时钟验证";
        AppWindow.ResizeClient(new global::Windows.Graphics.SizeInt32(1120, 760));
        var core = App.Core!;
        RuntimeSettings.Save(new RuntimePreferences(SkipIntro: false, SkipOutro: false));
        var preferences = new DanmakuPreferences(AutoLoad: false);
        core.Danmaku.Settings.Save(preferences);
        var media = new DemoMedia("cadence-kernel", "弹幕刷新测试", "", "", "", "", "", SourceUri: mediaPath);
        var player = new PlayerView(this, media, new PlaybackSource(media.Id, media.Title, mediaPath));
        Content = player;
        player.Loaded += async (_, _) =>
        {
            Directory.CreateDirectory(directory);
            var assertions = new List<string>();
            var metrics = new List<object>();
            const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
            T Field<T>(string name) => (T)typeof(PlayerView).GetField(name, flags)!.GetValue(player)!;
            void Invoke(string name, params object[] args) => typeof(PlayerView).GetMethod(name, flags)!.Invoke(player, args);
            void Check(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); assertions.Add(message); }
            async Task Wait(Func<bool> condition)
            {
                var watch = Stopwatch.StartNew();
                while (!condition())
                {
                    if (watch.Elapsed.TotalSeconds > 15) throw new TimeoutException("Cadence condition did not settle.");
                    if (Field<InfoBar>("PlaybackError").IsOpen) throw new InvalidOperationException(Field<InfoBar>("PlaybackError").Message);
                    await Task.Delay(20);
                }
            }
            Dictionary<string, double> Coordinates() => Field<Canvas>("_danmakuCanvas").Children.OfType<TextBlock>().ToDictionary(x => x.Text,
                x => Canvas.GetLeft(x) + (x.RenderTransform is TranslateTransform transform ? transform.X : 0));
            try
            {
                var duration = double.TryParse(Environment.GetEnvironmentVariable("OCP_CADENCE_SECONDS"), out var configured) ? configured : 60;
                Check(duration is >= 2 and <= 60, "cadence sampling duration is within the local fixture");
                foreach (var kernel in new[] { true, false })
                {
                    var mode = kernel ? "kernel" : "overlay";
                    core.Danmaku.Settings.Save(preferences with { UseKernelRenderer = kernel });
                    if (!kernel)
                    {
                        media = media with { Id = "cadence-overlay" };
                        player.SetMedia(media, new PlaybackSource(media.Id, media.Title, mediaPath));
                    }
                    await Wait(() => Field<PlaybackSession>("_session") is { Ready: true, HasFirstFrame: true });
                    var session = Field<PlaybackSession>("_session");
                    Check(session.DurationSeconds >= duration + 8, mode + " input leaves time for sampling and transport checks");
                    session.SetVolume(0); session.SetRate(1); session.Seek(2);
                    if (!session.Playing) session.SetPlaying(true);
                    Invoke("ApplyDanmakuContent", JsonSerializer.Serialize(new { comments = Enumerable.Range(0, 20).Select(i => new
                    { time = i * 4, type = 1, color = 16777215, content = $"滚动弹幕 {i:00}" }) }));
                    await Task.Delay(1000);
                    var samples = new List<Sample>();
                    var timer = Stopwatch.StartNew();
                    var lastFrame = TimeSpan.MinValue;
                    var nativeDetails = Environment.GetEnvironmentVariable("OCP_CADENCE_NATIVE_DETAILS") == "1";
                    var presenter = (ErikaPresenter)typeof(PlaybackSession).GetField("_presenter", flags)!.GetValue(session)!;
                    Sample Snapshot(double elapsed)
                    {
                        double? nativeTime = null, nativeDanmakuTime = null; uint? submitted = null; uint? displayed = null;
                        if (nativeDetails && kernel)
                        {
                            var diagnostics = presenter.Invoke("getDiagnosticsSnapshot");
                            nativeTime = diagnostics.GetProperty("playback").GetProperty("mediaTimeSeconds").GetDouble();
                            if (diagnostics.GetProperty("presenter").TryGetProperty("currentDanmakuMediaTimeSeconds", out var visualTime)
                                && visualTime.ValueKind == JsonValueKind.Number) nativeDanmakuTime = visualTime.GetDouble();
                            var owned = session.GetSwapChain(); var id = new Guid("310d36a0-d2e7-4c0a-aa04-6a9d23b8886a");
                            IntPtr swapChain = IntPtr.Zero;
                            try
                            {
                                Marshal.ThrowExceptionForHR(Marshal.QueryInterface(owned, in id, out swapChain));
                                var table = Marshal.ReadIntPtr(swapChain);
                                var last = Marshal.GetDelegateForFunctionPointer<GetLastPresentCount>(Marshal.ReadIntPtr(table, 17 * IntPtr.Size));
                                if (last(swapChain, out var count) >= 0) submitted = count;
                                var stats = Marshal.GetDelegateForFunctionPointer<GetFrameStatistics>(Marshal.ReadIntPtr(table, 16 * IntPtr.Size));
                                if (stats(swapChain, out var statistics) >= 0) displayed = statistics.PresentCount;
                            }
                            finally { if (swapChain != IntPtr.Zero) Marshal.Release(swapChain); Marshal.Release(owned); }
                        }
                        return new(elapsed, session.PositionSeconds, session.RenderPositionSeconds,
                            session.Stats.GetProperty("danmakuFrames").GetInt64(), Coordinates(), nativeTime, submitted, displayed, nativeDanmakuTime,
                            Field<TimeSpan>("_lastRenderingTime").TotalSeconds,
                            session.RenderPositionAt(Field<double>("_presentationClockOffset") + Field<TimeSpan>("_lastRenderingTime").TotalSeconds));
                    }
                    void SampleFrame(object? sender, object args)
                    {
                        if (args is RenderingEventArgs frame)
                        {
                            if (frame.RenderingTime == lastFrame) return;
                            lastFrame = frame.RenderingTime;
                        }
                        samples.Add(Snapshot(timer.Elapsed.TotalSeconds));
                    }
                    CompositionTarget.Rendering += SampleFrame;
                    try { await Task.Delay(TimeSpan.FromSeconds(duration)); }
                    finally { CompositionTarget.Rendering -= SampleFrame; }
                    File.WriteAllText(Path.Combine(directory, mode + "-samples.json"), JsonSerializer.Serialize(samples));
                    Check(samples.Count > duration * 45, mode + " receives at least 45 display updates per second");
                    var intervals = samples.Zip(samples.Skip(1), (a, b) => (b.Seconds - a.Seconds) * 1000).Order().ToArray();
                    var median = intervals[intervals.Length / 2]; var p95 = intervals[(int)(intervals.Length * .95)];
                    var moves = new List<double>();
                    var backwards = 0; var nativeDelta = samples[^1].Frames - samples[0].Frames;
                    for (var i = 1; i < samples.Count; i++)
                    {
                        var a = samples[i - 1]; var b = samples[i];
                        // Compare the positions actually used for these display
                        // frames, rather than later wall-clock extrapolations.
                        if (b.DisplayPosition + .000001 < a.DisplayPosition) backwards++;
                        var moved = kernel ? b.Frames > a.Frames : b.Left.Any(pair => a.Left.TryGetValue(pair.Key, out var left) && pair.Value < left - .000001);
                        if (moved) moves.Add(b.Seconds);
                    }
                    var moveIntervals = moves.Zip(moves.Skip(1), (a, b) => (b - a) * 1000).Order().ToArray();
                    metrics.Add(new { mode, seconds = samples[^1].Seconds, callbacks = samples.Count, medianMs = median, p95Ms = p95,
                        moves = moves.Count, movementMedianMs = moveIntervals.Length > 0 ? moveIntervals[moveIntervals.Length / 2] : 0,
                        nativeDelta, backwards, session.Stats });
                    File.WriteAllText(Path.Combine(directory, "metrics.json"), JsonSerializer.Serialize(metrics, JsonOptions));
                    Check(median < 20 && p95 < 25, mode + " display callback cadence is smooth on the local 60 Hz display");
                    Check(moves.Count > (samples.Count - 1) * .95 && backwards == 0,
                        mode + " comments advance on at least 95% of display frames without backwards jumps");
                    Check(session.Stats.GetProperty("renderFailures").GetInt64() == 0 && session.Stats.GetProperty("audioFailures").GetInt64() == 0,
                        mode + " real native playback has no render or audio failures");
                    if (nativeDetails && kernel && samples.All(x => x.NativeDanmakuTime is not null))
                    {
                        var velocities = samples.Zip(samples.Skip(1), (a, b) =>
                            (b.NativeDanmakuTime!.Value - a.NativeDanmakuTime!.Value) / (b.DisplaySeconds!.Value - a.DisplaySeconds!.Value)).ToArray();
                        var phaseErrors = samples.Select(x => Math.Abs(x.NativeDanmakuTime!.Value - x.NativeTime!.Value)).ToArray();
                        metrics.Add(new { mode, stage = "visual-motion", minSpeed = velocities.Min(), maxSpeed = velocities.Max(), maxPhaseError = phaseErrors.Max(),
                            submittedPresents = samples[^1].SubmittedPresents - samples[0].SubmittedPresents });
                        File.WriteAllText(Path.Combine(directory, "metrics.json"), JsonSerializer.Serialize(metrics, JsonOptions));
                        Check(velocities.All(x => x is >= .979 and <= 1.021) && phaseErrors.Max() < .5,
                            "native visual motion stays within 2% of steady speed while following the authoritative media timeline");
                    }
                    if (!kernel)
                    {
                        var velocities = samples.Zip(samples.Skip(1), (a, b) =>
                            (b.DisplayPosition!.Value - a.DisplayPosition!.Value) / (b.DisplaySeconds!.Value - a.DisplaySeconds!.Value)).ToArray();
                        metrics.Add(new { mode, stage = "visual-motion", minSpeed = velocities.Min(), maxSpeed = velocities.Max() });
                        File.WriteAllText(Path.Combine(directory, "metrics.json"), JsonSerializer.Serialize(metrics, JsonOptions));
                        Check(velocities.All(x => x is >= .979 and <= 1.021),
                            "overlay display positions stay within 2% of steady speed across native progress events");
                    }

                    session.SetPlaying(false); session.Seek(2);
                    await Wait(() => !session.Playing && session.PlaybackState == 4 && Math.Abs(session.PositionSeconds - 2) < .15);
                    await Task.Delay(200);
                    var paused = session.RenderPositionSeconds; var leftBefore = Coordinates();
                    await Task.Delay(250);
                    Check(session.RenderPositionSeconds == paused && Coordinates().All(pair => leftBefore[pair.Key] == pair.Value),
                        mode + " paused comments and animation clock stay fixed");
                    session.Seek(2.25); await Task.Delay(150);
                    Check(Math.Abs(session.RenderPositionSeconds - 2.25) < .01, mode + " small paused seeks align immediately");
                    session.SetRate(2); session.SetPlaying(true);
                    // Native audio/clock transitions and the bounded drift correction
                    // need to settle before measuring steady-state double speed.
                    await Task.Delay(1000);
                    var rateClock = Stopwatch.StartNew(); var startPosition = session.RenderPositionSeconds;
                    var startReportedPosition = session.PositionSeconds;
                    var rateSamples = new List<Sample>();
                    void RateFrame(object? sender, object args) => rateSamples.Add(Snapshot(rateClock.Elapsed.TotalSeconds));
                    CompositionTarget.Rendering += RateFrame;
                    try { await Task.Delay(1000); }
                    finally { CompositionTarget.Rendering -= RateFrame; }
                    File.WriteAllText(Path.Combine(directory, mode + "-rate-samples.json"), JsonSerializer.Serialize(rateSamples));
                    var rateElapsed = rateClock.Elapsed.TotalSeconds;
                    var rateDelta = session.RenderPositionSeconds - startPosition;
                    metrics.Add(new { mode, stage = "double-speed", rateElapsed, rateDelta, reportedDelta = session.PositionSeconds - startReportedPosition,
                        session.Playing, session.Buffering });
                    File.WriteAllText(Path.Combine(directory, "metrics.json"), JsonSerializer.Serialize(metrics, JsonOptions));
                    Check(Math.Abs(rateDelta - rateElapsed * 2) <= rateElapsed * .2 + .02,
                        mode + $" animation follows native double-speed playback (elapsed={rateElapsed:0.000}, movement={rateDelta:0.000})");
                    Check(rateSamples.Count > 40 && rateSamples.Zip(rateSamples.Skip(1), (a, b) => b.DisplayPosition > a.DisplayPosition).All(x => x),
                        mode + " double-speed animation advances continuously without backwards jumps");
                    session.SetRate(1);
                    for (var cycle = 0; cycle < 2; cycle++)
                    {
                        ((OverlappedPresenter)AppWindow.Presenter).Minimize();
                        await Wait(() => !Field<bool>("_renderingSubscribed") && Field<DispatcherTimer>("_backgroundClock").IsEnabled);
                        var before = session.PositionSeconds;
                        await Task.Delay(1000);
                        Check(session.PositionSeconds > before + .5, mode + " minimized playback continues through the background timer");
                        ((OverlappedPresenter)AppWindow.Presenter).Restore(); Activate();
                        await Wait(() => Field<bool>("_renderingSubscribed") && !Field<DispatcherTimer>("_backgroundClock").IsEnabled);
                        Check(session.Playing, mode + " restoring the window resumes display rendering and preserves playback");
                    }
                }
                player.Dispose();
                Check(player.IsDisposed && !Field<bool>("_renderingSubscribed") && !Field<DispatcherTimer>("_backgroundClock").IsEnabled,
                    "closing releases the display subscription and background timer");
                File.WriteAllText(Path.Combine(directory, "results.json"), JsonSerializer.Serialize(new { passed = true, assertions, metrics }, JsonOptions));
            }
            catch (Exception ex)
            {
                File.WriteAllText(Path.Combine(directory, "results.json"), JsonSerializer.Serialize(new { passed = false, error = ex.ToString(), assertions, metrics }, JsonOptions));
            }
            finally
            {
                player.Dispose();
                var vault = new global::Windows.Security.Credentials.PasswordVault();
                try { vault.Remove(vault.Retrieve(resource, "danmaku-settings")); } catch (System.Runtime.InteropServices.COMException) { }
                Close();
            }
        };
    }
}
#endif

using OcPlayer.CoreAdapter;

internal static partial class Program
{
    private static void VerifyPlaybackRenderClock()
    {
        var clock = new PlaybackRenderClock();
        clock.Reset(2, 0); clock.SetRunning(true, 0);
        Assert(Math.Abs(clock.Position(.016) - 2.016) < 1e-9, "animation advances between native progress reports");
        clock.Synchronize(2.016, .016);
        Assert(Math.Abs(clock.Position(.008) - 2.008) < 1e-9,
            "fixed display timestamps interpolate before a later native sample without stalling a frame");
        var previous = clock.Position(.1);
        clock.Synchronize(2.08, .1);
        Assert(Math.Abs(clock.Position(.1) - previous) < 1e-9 && clock.Position(.116) > previous,
            "late progress samples correct drift without a backwards coordinate jump");
        var monotonic = true;
        for (var i = 2; i <= 100; i++)
        {
            var now = i * .1;
            clock.Synchronize(2 + now - .02, now);
            monotonic &= clock.Position(now + .016) > clock.Position(now);
        }
        Assert(monotonic, "jitter correction preserves forward motion across repeated native reports");
        clock.SetRunning(false, 10.1);
        var frozen = clock.Position(10.1);
        Assert(clock.Position(12) == frozen, "pause or buffering freezes animation immediately");
        clock.SetRunning(true, 12);
        Assert(Math.Abs(clock.Position(12.1) - frozen - .1) < 1e-9, "resuming does not include the paused wall-clock interval");
        clock.SetRate(2, 12.1);
        var doubled = clock.Position(12.1);
        Assert(Math.Abs(clock.Position(12.2) - doubled - .2) < 1e-9, "rate changes retain position and apply the actual playback rate");
        clock.Reset(3.25, 12.2);
        Assert(clock.Position(12.2) == 3.25, "small and backwards seeks align immediately instead of smoothing the seek");
        clock.Synchronize(40, 12.3);
        Assert(clock.Position(12.3) == 40, "large native discontinuities align immediately");
        Assert(clock.Position(13) == clock.Position(20), "missing native feedback bounds extrapolation to half a second");
        clock.SetRunning(false, 20); clock.Reset(0, 20); clock.SetRate(1, 20);
        Assert(clock.Position(100) == 0, "opening another source clears the previous animation timeline");
    }
}

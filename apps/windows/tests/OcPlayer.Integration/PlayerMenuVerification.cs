using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using OcPlayer.CoreAdapter;

internal static partial class Program
{
    private static void VerifyPlayerMenuNative(PlaybackSession session, OcpCoreClient core, string data)
    {
        var wasPlaying = session.Playing;
        var originalScale = session.SubtitleScale;
        var originalSubtitle = session.Tracks.EnumerateArray()
            .Where(track => track.GetProperty("kind").GetInt32() == 2 && track.GetProperty("selected").GetBoolean())
            .Select(track => track.GetProperty("id").GetInt64()).DefaultIfEmpty(-1).First();
        string? error = null;
        void OnFailure(string message) => error = message;
        session.Failed += OnFailure;
        try
        {
            Pump(session, core, () => session.VideoWidth > 0 && session.VideoHeight > 0 && session.PlaybackState == 3, () => error);
            Assert(session.Ready && session.Playing && session.HasSurface,
                "player menu diagnostics reflect the active native playback and attached surface");
            var video = session.Tracks.EnumerateArray().First(track => track.GetProperty("kind").GetInt32() == 0);
            var width = session.VideoWidth;
            var height = session.VideoHeight;
            Assert(width == video.GetProperty("width").GetUInt32() && height == video.GetProperty("height").GetUInt32(),
                "native video dimensions match the source track rather than the 640 by 360 test window");

            session.SetPlaying(false);
            Pump(session, core, () => session.PlaybackState == 4 && !session.Playing, () => error);
            using (var playback = core.Snapshot("playback"))
                Assert(playback.RootElement.GetProperty("state").GetString() == "paused",
                    "paused native playback state and shared Core diagnostics agree");
            session.SelectTrack(-1, true);
            session.SetSubtitleScale(1);
            PumpFor(session, core, .25);
            var pausedPosition = session.PositionSeconds;
            var clean = StablePlayerMenuFrame(session, core, width, height, () => error);
            Assert(clean.LongLength == checked((long)width * height * 4) && OpaquePlayerMenuFrame(clean),
                "native capture returns a complete opaque RGBA image at source resolution");
            var cleanAgain = StablePlayerMenuFrame(session, core, width, height, () => error);
            Assert(clean.AsSpan().SequenceEqual(cleanAgain) && Math.Abs(session.PositionSeconds - pausedPosition) < .05,
                "repeated captures of paused video have a stable image and media position");

            var subtitlePath = Path.Combine(data, "播放器菜单-外挂字幕.srt");
            File.WriteAllText(subtitlePath, "1\n00:00:00,000 --> 23:59:59,000\nOcPlayer\nSubtitle check 0123\n", new UTF8Encoding(false));
            var previousTrackCount = session.Tracks.GetArrayLength();
            var subtitleId = session.LoadSubtitle(subtitlePath);
            // Deliberately inspect Tracks before another Tick: the menu must
            // immediately see and select the external subtitle returned by import.
            var imported = session.Tracks.EnumerateArray().Single(track => track.GetProperty("id").GetInt64() == subtitleId);
            Assert(subtitleId >= 0 && session.Tracks.GetArrayLength() == previousTrackCount + 1
                && imported.GetProperty("kind").GetInt32() == 2 && imported.GetProperty("source").GetInt32() == 1,
                "subtitle import returns its native ID and immediately refreshes the external track list");
            Assert(imported.GetProperty("selected").GetBoolean()
                && session.Tracks.EnumerateArray().Count(track => track.GetProperty("kind").GetInt32() == 2
                    && track.GetProperty("selected").GetBoolean()) == 1,
                "the imported external subtitle is the only selected subtitle track");
            using (var playback = core.Snapshot("playback"))
                Assert(playback.RootElement.GetProperty("subtitleTrack").GetString() == subtitleId.ToString(CultureInfo.InvariantCulture),
                    "subtitle import immediately synchronizes the selected track with Core");

            var normal = WaitForPlayerMenuFrame(session, core, width, height,
                pixels => ComparePlayerMenuFrames(clean, pixels, width, height).ChangedPixels > 50,
                "imported subtitles did not appear in the source-resolution capture", () => error);
            normal = StablePlayerMenuFrame(session, core, width, height, () => error);
            var normalDifference = ComparePlayerMenuFrames(clean, normal, width, height);
            Assert(normalDifference.ChangedPixels > 50 && normalDifference.UpperHalfPixels == 0,
                $"imported subtitles alter the lower image without changing the paused video ({normalDifference.ChangedPixels} pixels)");

            session.SetSubtitleScale(.5);
            Assert(session.SubtitleScale == .5, "native subtitle scaling accepts the 50 percent lower limit");
            session.SetSubtitleScale(3);
            Assert(session.SubtitleScale == 3, "native subtitle scaling accepts the 300 percent upper limit");
            session.SetSubtitleScale(1.5);
            Assert(session.SubtitleScale == 1.5, "the selected 150 percent subtitle scale is retained by the player");
            var large = WaitForPlayerMenuFrame(session, core, width, height,
                pixels => ComparePlayerMenuFrames(normal, pixels, width, height).ChangedPixels > 50,
                "changing subtitle scale did not change the captured subtitle image", () => error);
            large = StablePlayerMenuFrame(session, core, width, height, () => error);
            var largeDifference = ComparePlayerMenuFrames(clean, large, width, height);
            Assert(largeDifference.ChangedPixels > normalDifference.ChangedPixels
                && largeDifference.BoundsHeight > normalDifference.BoundsHeight && largeDifference.UpperHalfPixels == 0,
                $"150 percent subtitles render larger at source resolution ({normalDifference.BoundsHeight} to {largeDifference.BoundsHeight} pixels high)");

            foreach (var invalid in new[] { .49, 3.01, double.NaN, double.PositiveInfinity, double.NegativeInfinity })
            {
                var rejected = false;
                try { session.SetSubtitleScale(invalid); }
                catch (ArgumentOutOfRangeException) { rejected = true; }
                Assert(rejected && session.SubtitleScale == 1.5,
                    $"invalid subtitle scale {invalid.ToString(CultureInfo.InvariantCulture)} is rejected without changing the selected scale");
            }
            Assert(large.AsSpan().SequenceEqual(StablePlayerMenuFrame(session, core, width, height, () => error)),
                "rejecting invalid subtitle scales leaves the actual captured image unchanged");

            session.SelectTrack(-1, true);
            Assert(!session.Tracks.EnumerateArray().Any(track => track.GetProperty("kind").GetInt32() == 2
                && track.GetProperty("selected").GetBoolean()), "disabling subtitles immediately clears the native menu selection");
            using (var playback = core.Snapshot("playback"))
                Assert(playback.RootElement.GetProperty("subtitleTrack").ValueKind == JsonValueKind.Null,
                    "disabling subtitles clears the selected track in Core");
            var disabled = WaitForPlayerMenuFrame(session, core, width, height,
                pixels => pixels.AsSpan().SequenceEqual(clean),
                "turning subtitles off did not restore the clean paused frame", () => error);
            Assert(disabled.AsSpan().SequenceEqual(clean), "turning subtitles off removes them from the native capture");

            session.SelectTrack(subtitleId, true);
            session.SetSubtitleScale(1);
            var restored = WaitForPlayerMenuFrame(session, core, width, height,
                pixels => pixels.AsSpan().SequenceEqual(normal),
                "reselecting the external subtitle did not restore its normal-size image", () => error);
            Assert(restored.AsSpan().SequenceEqual(normal) && Math.Abs(session.PositionSeconds - pausedPosition) < .05,
                "reselecting subtitles at 100 percent restores their image without advancing playback");
            Assert(error is null, "native player menu actions complete without a playback error");
            Evidence.Add(new
            {
                stage = "player-menus", width, height, pausedPosition, subtitleId, subtitleSource = imported.GetProperty("source").GetInt32(),
                normalDifference, largeDifference, cleanSha256 = Convert.ToHexStringLower(SHA256.HashData(clean)),
                subtitleSha256 = Convert.ToHexStringLower(SHA256.HashData(normal)), largerSubtitleSha256 = Convert.ToHexStringLower(SHA256.HashData(large))
            });
        }
        finally
        {
            session.Failed -= OnFailure;
            session.SetSubtitleScale(originalScale);
            session.SelectTrack(originalSubtitle, true);
            session.SetPlaying(wasPlaying);
        }
    }

    private static byte[] StablePlayerMenuFrame(PlaybackSession session, OcpCoreClient core, uint width, uint height, Func<string?> error)
    {
        var previous = session.CaptureFrameRgba(width, height);
        var timer = Stopwatch.StartNew();
        while (timer.Elapsed.TotalSeconds < 5)
        {
            PumpFor(session, core, .08);
            if (error() is { } failure) throw new InvalidOperationException(failure);
            var current = session.CaptureFrameRgba(width, height);
            if (previous.AsSpan().SequenceEqual(current)) return current;
            previous = current;
        }
        throw new InvalidOperationException($"Paused native captures did not stabilize at {width} by {height}, position {session.PositionSeconds:0.000}.");
    }

    private static byte[] WaitForPlayerMenuFrame(PlaybackSession session, OcpCoreClient core, uint width, uint height,
        Func<byte[], bool> expected, string failure, Func<string?> error)
    {
        var timer = Stopwatch.StartNew();
        do
        {
            PumpFor(session, core, .08);
            if (error() is { } message) throw new InvalidOperationException(message);
            var pixels = session.CaptureFrameRgba(width, height);
            if (expected(pixels)) return pixels;
        } while (timer.Elapsed.TotalSeconds < 10);
        throw new InvalidOperationException($"{failure}; video={width}x{height}, state={session.PlaybackState}, position={session.PositionSeconds:0.000}, scale={session.SubtitleScale}.");
    }

    private static bool OpaquePlayerMenuFrame(byte[] pixels)
    {
        for (var offset = 3; offset < pixels.Length; offset += 4)
            if (pixels[offset] != 255) return false;
        return true;
    }

    private readonly record struct PlayerMenuFrameDifference(long ChangedPixels, long UpperHalfPixels, int BoundsHeight);
    private static PlayerMenuFrameDifference ComparePlayerMenuFrames(byte[] before, byte[] after, uint width, uint height)
    {
        if (before.Length != after.Length || before.LongLength != (long)width * height * 4)
            throw new InvalidOperationException("Native captures returned inconsistent pixel dimensions.");
        long changed = 0, upperHalf = 0;
        var firstRow = (int)height;
        var lastRow = -1;
        var stride = checked((int)width * 4);
        for (var offset = 0; offset < before.Length; offset += 4)
        {
            if (Math.Abs(before[offset] - after[offset]) < 8 && Math.Abs(before[offset + 1] - after[offset + 1]) < 8
                && Math.Abs(before[offset + 2] - after[offset + 2]) < 8) continue;
            var row = offset / stride;
            changed++;
            if (row < height / 2) upperHalf++;
            firstRow = Math.Min(firstRow, row); lastRow = Math.Max(lastRow, row);
        }
        return new(changed, upperHalf, lastRow < firstRow ? 0 : lastRow - firstRow + 1);
    }
}

using System.Text.Json;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Services;

internal static partial class Program
{
    private static void VerifyPlayerParity(string directory)
    {
        var preferenceDirectory = Path.Combine(directory, "player-parity");
        Directory.CreateDirectory(preferenceDirectory);
        new PlaybackPreferences(1.3, 1.5, .67, true).Save(preferenceDirectory);
        var loaded = PlaybackPreferences.Load(preferenceDirectory);
        Assert(loaded.Rate == 1.5 && loaded.Volume == .67 && loaded.Muted && loaded.SubtitleScale == 1.3,
            "playback speed, independent mute, volume and subtitle scale survive a new preference load");
        (loaded with { Volume = .45 }).Save(preferenceDirectory);
        Assert(PlaybackPreferences.Load(preferenceDirectory).Muted, "changing saved volume does not erase the independent muted preference");
        var validated = new PlaybackPreferences(double.NaN, double.PositiveInfinity, double.NegativeInfinity).Validated();
        Assert(validated.SubtitleScale == 1 && validated.Rate == 1 && validated.Volume == .4,
            "nonfinite saved playback values recover to finite defaults");
        File.WriteAllText(Path.Combine(preferenceDirectory, "playback-preferences.json"), "{\"subtitleScale\":1.7}");
        loaded = PlaybackPreferences.Load(preferenceDirectory);
        Assert(loaded.SubtitleScale == 1.7 && loaded.Rate == 1 && loaded.Volume == .4 && !loaded.Muted,
            "legacy subtitle-only preferences migrate without losing subtitle scale");
        var chapters = new[] { new PlaybackChapter("冷开场", 0, 120), new PlaybackChapter("OP Part A", 120, 165),
            new PlaybackChapter("OP Part B", 165, 210), new PlaybackChapter("正片", 210, 1200),
            new PlaybackChapter("ED", 1200, 1290), new PlaybackChapter("下集预告", 1290, 1320) };
        var marks = PlaybackSkipMarks.FromChapters(chapters, 1320, false);
        Assert(marks.Single(m => m.Kind == "opening") is { Start: 120, End: 210 }, "adjacent OP chapters merge into one complete opening");
        Assert(marks.Single(m => m.Kind == "credits") is { Start: 1200, End: 1290 }, "ED ending preserves the following preview");
        Assert(!PlaybackSkipMarks.Matches("Cold Open", "opening") && !PlaybackSkipMarks.Matches("Intro End", "opening")
            && PlaybackSkipMarks.Matches("NCOP1", "opening") && PlaybackSkipMarks.Matches("片尾曲", "credits"),
            "chapter names honor keyword boundaries, end sentinels, numeric suffixes and CJK words");
        var movie = new[] { new PlaybackChapter("正片", 0, 6300), new PlaybackChapter("Credits", 6300, 7200) };
        Assert(PlaybackSkipMarks.FromChapters(movie, 7200, true).Any(m => m.Kind == "credits")
            && !PlaybackSkipMarks.FromChapters(movie, 7200, false).Any(m => m.Kind == "credits"),
            "movie credits accept the 900 second cap while episodes retain the 450 second cap");
        Assert(PlaybackSkipMarks.FromChapters(chapters, 0, false).Length == 0, "unknown durations never produce speculative skip regions");
        Assert(new PlaybackSkipMark("s", "opening", "mediaSegment", 0, 90).Rank > new PlaybackSkipMark("a", "opening", "aniskip", 0, 85).Rank
            && new PlaybackSkipMark("l", "opening", "learned", 0, 90).Rank > new PlaybackSkipMark("d", "opening", "danmaku", 0, 85).Rank,
            "server and learned intro signals outrank weaker alternatives");
        foreach (var (message, expected, alternate) in new[] { ("HTTP 401 unauthorized", "auth", false),
            ("Network connection reset", "network", true), ("Unsupported codec", "unsupported", true),
            ("HTTP 503 server error", "server", true), ("打开片源超时", "timeout", true), ("cancelled", "cancelled", false) })
        {
            var failure = PlaybackFailure.Classify(message);
            Assert(failure.Category == expected && failure.CanTryAlternateSource == alternate,
                $"playback {expected} failures use the matching recovery route");
        }
    }

    private static void VerifySubtitleRemoval(PlaybackSession session, OcpCoreClient core, string directory)
    {
        var path = Path.Combine(directory, "remove-subtitle.srt");
        File.WriteAllText(path, "1\n00:00:00,000 --> 23:00:00,000\nRemovable subtitle\n");
        var count = session.Tracks.GetArrayLength();
        var id = session.LoadSubtitle(path);
        Assert(session.Tracks.EnumerateArray().Any(t => t.GetProperty("id").GetInt64() == id && t.GetProperty("canRemove").GetBoolean()),
            "external subtitle imports expose the native removable flag");
        session.RemoveSubtitle(id);
        Assert(session.Tracks.GetArrayLength() == count && !session.Tracks.EnumerateArray().Any(t => t.GetProperty("id").GetInt64() == id),
            "subtitle removal deletes the native track and refreshes the menu immediately");
        using (var playback = core.Snapshot("playback"))
            Assert(playback.RootElement.GetProperty("subtitleTrack").ValueKind == JsonValueKind.Null,
                "removing the selected subtitle immediately clears its shared Core selection");
        var unselected = session.LoadSubtitle(path);
        var selected = session.LoadSubtitle(path);
        session.RemoveSubtitle(unselected);
        Assert(session.Tracks.GetArrayLength() == count + 1
            && !session.Tracks.EnumerateArray().Any(t => t.GetProperty("id").GetInt64() == unselected)
            && session.Tracks.EnumerateArray().Any(t => t.GetProperty("id").GetInt64() == selected && t.GetProperty("selected").GetBoolean()),
            "removing another external subtitle preserves the selected track");
        using (var playback = core.Snapshot("playback"))
            Assert(playback.RootElement.GetProperty("subtitleTrack").GetString() == selected.ToString(System.Globalization.CultureInfo.InvariantCulture),
                "unselected subtitle removal preserves the shared Core selection");
        session.RemoveSubtitle(selected);
        Assert(session.Tracks.GetArrayLength() == count, "successive subtitle removals leave the existing tracks intact");
    }
}

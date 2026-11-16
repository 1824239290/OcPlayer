using System.Text.Json;
using System.Text.RegularExpressions;
using OcPlayer.CoreAdapter;

namespace OcPlayer.Windows.Services;

internal sealed record PlaybackSkipMark(string Id, string Kind, string Source, double Start, double End)
{
    public int Rank => Source switch { "mediaSegment" => 6, "aniskip" => 5, "animeSkip" => 4, "learned" => 3, "theIntroDB" => 2, "danmaku" => 1, _ => 0 };
    public string Label => Kind == "opening" ? "跳过片头" : "跳过片尾";
}

internal static class PlaybackSkipMarks
{
    public static PlaybackSkipMark[] FromChapters(IReadOnlyList<PlaybackChapter> chapters, double duration, bool movie)
    {
        if (!double.IsFinite(duration) || duration <= 0) return [];
        var resolved = chapters.Select((c, i) => c with { EndSeconds = c.EndSeconds is { } end && end > c.StartSeconds ? Math.Min(end, duration) : i + 1 < chapters.Count ? chapters[i + 1].StartSeconds : duration }).ToArray();
        var result = new List<PlaybackSkipMark>();
        foreach (var kind in new[] { "opening", "credits" })
        {
            var groups = new List<(double Start, double End)>();
            foreach (var chapter in resolved.Where(c => Matches(c.Name, kind)))
            {
                var end = chapter.EndSeconds!.Value;
                if (groups.Count > 0 && chapter.StartSeconds >= groups[^1].Start && chapter.StartSeconds - groups[^1].End <= 1)
                    groups[^1] = (groups[^1].Start, Math.Max(groups[^1].End, end));
                else groups.Add((chapter.StartSeconds, end));
            }
            var cap = movie ? 900 : 450;
            bool Eligible((double Start, double End) g, bool named) => kind == "opening"
                ? g.Start <= Math.Min(duration * .25, 600) && g.End - g.Start >= 10 && g.End - g.Start <= (named ? 180 : 120)
                : g.Start >= duration * (named ? .7 : .85) && g.End - g.Start >= 15 && g.End - g.Start <= cap;
            var candidates = groups.Where(g => Eligible(g, true)).ToArray();
            if (candidates.Length == 0)
                candidates = (kind == "opening" ? resolved.Take(1) : resolved).Select(c => (Start: c.StartSeconds, End: c.EndSeconds!.Value)).Where(g => Eligible(g, false)).ToArray();
            if (candidates.Length == 0) continue;
            var chosen = kind == "opening" ? candidates[0] : candidates[^1];
            result.Add(new($"{kind}-{chosen.Start:0.###}", kind, "chapterHeuristic", chosen.Start, chosen.End));
        }
        return result.ToArray();
    }

    internal static bool Matches(string name, string kind)
    {
        var opening = kind == "opening";
        var normalized = name.Trim().ToLowerInvariant();
        var tokens = Regex.Matches(normalized, @"[\p{L}\p{N}]+").Select(x => x.Value).ToArray();
        var keywords = opening ? new[] { "op", "opening", "intro", "introduction", "ncop" } : ["ed", "ending", "credit", "credits", "outro", "nced"];
        for (var i = 0; i < tokens.Length; i++)
            if (keywords.Any(k => tokens[i] == k || tokens[i].StartsWith(k, StringComparison.Ordinal) && tokens[i].Length > k.Length && tokens[i][k.Length..].All(char.IsDigit))
                && (i + 1 >= tokens.Length || tokens[i + 1] != "end")) return true;
        return (opening ? new[] { "main title", "title sequence", "片头", "片頭", "主题曲", "主題曲", "オープニング" }
            : ["closing credits", "片尾", "结尾", "結尾", "尾声", "尾聲", "エンディング"]).Any(normalized.Contains);
    }

    public static async Task<PlaybackSkipMark[]> LoadSegmentsAsync(OcpCoreClient core, PlaybackReport report, CancellationToken token)
    {
        var profile = report.Profile.Deserialize<ServerProfile>(MediaServer.JsonOptions) ?? throw new InvalidOperationException("服务器资料不可读。");
        var data = await new MediaServer(core, profile).Request("media.segments", new { itemId = report.ItemId }, token);
        if (!data.TryGetProperty("items", out var rows) || rows.ValueKind != JsonValueKind.Array) return [];
        var result = new List<PlaybackSkipMark>();
        foreach (var row in rows.EnumerateArray())
        {
            var type = Property(row, "Type");
            var kind = type.ValueKind == JsonValueKind.String ? type.GetString()?.ToLowerInvariant() switch { "intro" => "opening", "outro" => "credits", _ => null } : null;
            if (kind is null) continue;
            var start = Number(Property(row, "StartTicks")) / 10_000_000;
            var end = Number(Property(row, "EndTicks")) / 10_000_000;
            if (!double.IsFinite(start) || !double.IsFinite(end) || start < 0 || end <= start + .5) continue;
            result.Add(new($"server-{kind}-{start:0.###}", kind, "mediaSegment", start, end));
        }
        return result.ToArray();
    }
    private static double Number(JsonElement element) => element.ValueKind == JsonValueKind.Number && element.TryGetDouble(out var number) ? number : double.NaN;
    private static JsonElement Property(JsonElement element, string key) => element.ValueKind == JsonValueKind.Object
        ? element.EnumerateObject().FirstOrDefault(p => p.Name.Equals(key, StringComparison.OrdinalIgnoreCase)).Value : default;
}

using System.Globalization;
using System.Text.Json;
using OcPlayer.CoreAdapter;

namespace OcPlayer.Windows.Services;

internal sealed record PlaybackChapter(string Name, double StartSeconds, double? EndSeconds);

internal static class PlaybackChapters
{
    public static async Task<PlaybackChapter[]> LoadAsync(OcpCoreClient core, PlaybackReport report, CancellationToken token)
    {
        var profile = report.Profile.Deserialize<ServerProfile>(MediaServer.JsonOptions)
            ?? throw new InvalidOperationException("无法读取当前片源的服务器信息。");
        var server = new MediaServer(core, profile);
        var response = await server.Request("browse.chapters", new { itemId = report.ItemId }, token);
        token.ThrowIfCancellationRequested();
        if (!response.TryGetProperty("chapters", out var rows) || rows.ValueKind != JsonValueKind.Array)
            throw new InvalidOperationException("服务器返回的章节信息格式不正确。");
        var starts = new List<(string Name, double Start)>();
        foreach (var row in rows.EnumerateArray())
        {
            if (row.ValueKind != JsonValueKind.Object)
                throw new InvalidOperationException("服务器返回的章节条目格式不正确。");
            var name = Property(row, "Name");
            var ticks = Property(row, "StartPositionTicks");
            var start = ticks.ValueKind == JsonValueKind.Number && ticks.TryGetDouble(out var number) ? number
                : ticks.ValueKind == JsonValueKind.String && double.TryParse(ticks.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out number) ? number : 0;
            if (!double.IsFinite(start) || start < 0) continue;
            var title = name.ValueKind == JsonValueKind.String ? name.GetString()?.Trim() : null;
            starts.Add((string.IsNullOrWhiteSpace(title) ? $"章节 {starts.Count + 1}" : title, start / 10_000_000));
        }
        return Build(starts);
    }

    public static PlaybackChapter[] Demo(double duration)
    {
        if (!double.IsFinite(duration) || duration <= 0) duration = 1440;
        return Build([("序章", 0), ("片头", duration * .06), ("正片", duration * .12),
            ("片尾", duration * .88), ("下集预告", duration * .96)]);
    }

    public static int CurrentIndex(IReadOnlyList<PlaybackChapter> chapters, double position)
    {
        for (var index = chapters.Count - 1; index >= 0; index--)
            if (position >= chapters[index].StartSeconds && (chapters[index].EndSeconds is not { } end || position < end)) return index;
        return -1;
    }

    private static PlaybackChapter[] Build(IEnumerable<(string Name, double Start)> starts)
    {
        var ordered = starts.OrderBy(x => x.Start).ToArray();
        return ordered.Select((chapter, index) => new PlaybackChapter(chapter.Name, chapter.Start,
            index + 1 < ordered.Length ? ordered[index + 1].Start : null)).ToArray();
    }

    private static JsonElement Property(JsonElement value, string name)
    {
        if (value.ValueKind == JsonValueKind.Object)
            foreach (var property in value.EnumerateObject())
                if (property.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) return property.Value;
        return default;
    }
}

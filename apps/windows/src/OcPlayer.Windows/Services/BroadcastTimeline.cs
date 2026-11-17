using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace OcPlayer.Windows.Services;

internal sealed record BroadcastEntry(JsonElement Subject, int Weekday, DateTimeOffset? Anchor, string Period, DateTimeOffset? End);
internal static class BroadcastTimeline
{
    private static readonly HttpClient PublicData = new() { Timeout = TimeSpan.FromSeconds(20) };
    public static async Task<JsonElement[]> Schedule(string directory, CancellationToken token)
    {
        var file = Path.Combine(directory, "bangumi-data.json");
        try
        {
            if (File.Exists(file) && DateTime.UtcNow - File.GetLastWriteTimeUtc(file) < TimeSpan.FromHours(6)) return Parse(File.ReadAllText(file));
            // Public dataset only. No account token, media-server profile or authenticated client.
            var json = await PublicData.GetStringAsync("https://unpkg.com/bangumi-data@0.3/dist/data.json", token);
            var records = Parse(json); token.ThrowIfCancellationRequested();
            var temporary = file + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllText(temporary, json); File.Move(temporary, file, true); return records;
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
        catch (Exception ex) when (ex is HttpRequestException or IOException or JsonException or OperationCanceledException or InvalidOperationException)
        {
            try { return File.Exists(file) ? Parse(File.ReadAllText(file)) : []; }
            catch (Exception read) when (read is IOException or JsonException or InvalidOperationException) { return []; }
        }
        static JsonElement[] Parse(string value) => Json.Items(JsonDocument.Parse(value).RootElement);
    }
    public static async Task<JsonElement[]> Library(MediaServer server, CancellationToken token)
    {
        var result = new List<JsonElement>();
        for (var offset = 0; offset < 50000;)
        {
            var page = await server.Request("browse.library", new { startIndex = offset, limit = 500, recursive = true, kinds = new[] { "series", "season" }, sort = new { field = "name", ascending = true } }, token);
            var items = Json.Items(page); result.AddRange(items); offset += items.Length;
            var total = Json.Number(page, "totalRecordCount", Json.Number(page, "total", -1));
            if (items.Length == 0 || total >= 0 && offset >= total || total < 0 && items.Length < 500) return result.ToArray();
        }
        throw new InvalidOperationException("媒体库过大，放送匹配未完成，请重试。");
    }
    internal static BroadcastEntry[] Match(JsonElement[] watching, JsonElement[] calendar, JsonElement[] library, JsonElement[] schedule, IEnumerable<BangumiMediaLink>? links = null, string? source = null)
    {
        var days = new Dictionary<long, int>();
        foreach (var day in calendar) foreach (var subject in Json.Items(Json.Get(day, "items"))) days[(long)Json.Number(subject, "id")] = (int)Json.Number(Json.Get(day, "weekday"), "id");
        var schedules = new Dictionary<long, JsonElement>();
        foreach (var record in schedule)
            foreach (var site in Json.Items(Json.Get(record, "sites")))
                if (Json.Text(site, "site") == "bangumi" && long.TryParse(Json.Text(site, "id"), out var id)) schedules[id] = record;
        var entries = new List<BroadcastEntry>(); var seen = new HashSet<long>();
        foreach (var row in watching)
        {
            var subject = Json.Subject(row); var id = (long)Json.Number(subject, "id");
            if (!seen.Add(id) || !days.TryGetValue(id, out var weekday)) continue;
            schedules.TryGetValue(id, out var record);
            var begin = Date(Json.Text(record, "begin")); var end = Date(Json.Text(record, "end"));
            var broadcast = Json.Text(record, "broadcast");
            if (record.ValueKind == JsonValueKind.Object && (Json.Text(record, "type") is not ("tv" or "web") || begin > DateTimeOffset.Now || end < DateTimeOffset.Now || broadcast.EndsWith("/P0D"))) continue;
            var titles = new HashSet<string>(new[] { Json.Text(subject, "name"), Json.First(subject, "name_cn", "nameCN"), Json.Text(record, "title") }.Select(Normalize).Where(x => x.Length > 0));
            var translated = Json.Get(record, "titleTranslate");
            if (translated.ValueKind == JsonValueKind.Object) foreach (var language in translated.EnumerateObject()) foreach (var title in Json.Items(language.Value)) titles.Add(Normalize(title.GetString() ?? ""));
            var season = 0;
            var sites = Json.Get(record, "sites");
            if (sites.ValueKind == JsonValueKind.Array) foreach (var site in Json.Items(sites))
            {
                var parts = Json.Text(site, "id").Split('/');
                if (Json.Text(site, "site") == "tmdb" && parts.Length == 4 && parts[2] == "season") int.TryParse(parts[3], out season);
            }
            long? Explicit(JsonElement item)
            {
                var itemId = Json.Text(item, "id"); var parentId = Json.First(item, "seriesID", "seriesId");
                var itemSeason = Json.Text(item, "kind") == "season" ? (int?)Json.Number(item, "seasonNumber") : null;
                var candidates = (links ?? []).Where(x => source is null || x.Source == source);
                return candidates.FirstOrDefault(x => (x.SeriesId == itemId || x.SeriesId == parentId) && x.Season == itemSeason)?.SubjectId ??
                    (itemSeason is null or 1 ? candidates.FirstOrDefault(x => (x.SeriesId == itemId || x.SeriesId == parentId) && x.Season is null)?.SubjectId : null);
            }
            bool External(JsonElement item)
            {
                foreach (var site in Json.OptionalItems(sites))
                {
                    var provider = Json.Text(site, "site"); var externalId = Json.Text(site, "id");
                    if (provider == "mal" && externalId == Json.First(item, "malID", "malId")) return true;
                    if (provider == "aniList" && externalId == Json.First(item, "anilistID", "anilistId", "aniListID")) return true;
                    if (provider != "tmdb") continue; var parts = externalId.Split('/'); if (parts.Length < 2 || parts[0] != "tv") continue;
                    var parent = library.FirstOrDefault(x => Json.Text(x, "id") == Json.First(item, "seriesID", "seriesId"));
                    var show = Json.Text(item, "kind") == "season" ? parent : item;
                    if (parts[1] != Json.First(show, "tmdbID", "tmdbId")) continue;
                    if (parts.Length == 2 && Json.Text(item, "kind") == "series" || parts.Length == 4 && parts[2] == "season" && Json.Text(item, "kind") == "season" && int.TryParse(parts[3], out var number) && Json.Number(item, "seasonNumber") == number) return true;
                }
                return false;
            }
            var available = library.Any(item => Json.Number(item, "childCount", 1) > 0 &&
                (season <= 1 || Json.Text(item, "kind") == "season" && Json.Number(item, "seasonNumber") == season) &&
                (Explicit(item) is { } linked ? linked == id : External(item) || new[] { Json.Text(item, "name"), Json.Text(item, "originalTitle") }.Any(title => titles.Contains(Normalize(title)))));
            if (!available) continue;
            var recurrence = broadcast.Split('/');
            var anchor = recurrence.Length == 3 ? Date(recurrence[1]) : begin;
            var period = recurrence.Length == 3 ? recurrence[2] : "P7D";
            if (period is not ("P1D" or "P7D" or "P1M")) anchor = null;
            entries.Add(new(subject, weekday, anchor, period, end));
        }
        return entries.ToArray();
    }
    internal static IEnumerable<(BroadcastEntry Entry, DateTimeOffset? Time)> OnDay(IEnumerable<BroadcastEntry> entries, DateTime day)
    {
        var start = new DateTimeOffset(day.Date); var finish = new DateTimeOffset(day.Date.AddDays(1));
        var result = new List<(BroadcastEntry, DateTimeOffset?)>();
        foreach (var entry in entries)
        {
            if (entry.Anchor is not { } anchor)
            {
                if (entry.Weekday == ((int)day.DayOfWeek + 6) % 7 + 1) result.Add((entry, null));
                continue;
            }
            DateTimeOffset candidate;
            if (entry.Period == "P1M")
            {
                anchor = anchor.ToUniversalTime();
                var months = Math.Max(0, (start.UtcDateTime.Year - anchor.Year) * 12 + start.UtcDateTime.Month - anchor.Month);
                candidate = anchor.AddMonths(months); if (candidate < start) candidate = anchor.AddMonths(months + 1);
            }
            else { var seconds = entry.Period == "P1D" ? 86400 : 604800; candidate = anchor.AddSeconds(Math.Max(0, Math.Ceiling((start - anchor).TotalSeconds / seconds)) * seconds); }
            if (candidate >= start && candidate < finish && (entry.End is null || candidate <= entry.End)) result.Add((entry, candidate));
        }
        return result.OrderBy(x => x.Item2 ?? DateTimeOffset.MaxValue);
    }
    private static DateTimeOffset? Date(string value) => DateTimeOffset.TryParse(value, out var date) ? date : null;
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int LCMapStringEx(string localeName, uint flags, string source, int sourceLength, StringBuilder destination, int destinationLength, nint version, nint reserved, nint sortHandle);
    internal static string Normalize(string title)
    {
        var simplified = new StringBuilder(title.Length * 3 + 8);
        // Request a terminating NUL. With an explicit source length LCMapStringEx does not
        // terminate its destination; StringBuilder marshalling could otherwise read stale
        // native buffer characters after the mapped title.
        if (OperatingSystem.IsWindows() && LCMapStringEx("zh-CN", 0x02000000, title, -1, simplified, simplified.Capacity, 0, 0, 0) > 0) title = simplified.ToString();
        return string.Concat(title.Normalize(NormalizationForm.FormKD).Where(char.IsLetterOrDigit)).ToUpperInvariant();
    }
}

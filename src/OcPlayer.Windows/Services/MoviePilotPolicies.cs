using System.Text.Json;
using System.Text.Json.Nodes;

namespace OcPlayer.Windows.Services;

internal static class MoviePilotPolicies
{
    public static readonly (string Label, string Key, bool Meta)[] FilterFields = [("站点", "site_name", false), ("季 / 季集", "season_episode", true), ("促销", "volume_factor", false), ("编码", "video_encode", true), ("质量 / 版本", "edition", true), ("分辨率", "resource_pix", true), ("制作组", "resource_team", true)];
    public static string FilterValue(JsonElement result, int index)
    { var field = FilterFields[index]; return Json.Text(Json.Get(result, field.Meta ? "meta" : "torrent"), field.Key); }
    public static JsonElement[] Filter(IEnumerable<JsonElement> rows, IReadOnlyList<HashSet<string>> selected, string keyword = "") => rows.Where(row =>
        Enumerable.Range(0, FilterFields.Length).All(i => selected[i].Count == 0 || selected[i].Contains(FilterValue(row, i))) &&
        Json.Title(Json.Get(row, "torrent")).Contains(keyword.Trim(), StringComparison.OrdinalIgnoreCase)).ToArray();
    public static IEnumerable<JsonElement> Sort(IEnumerable<JsonElement> rows, int field, bool ascending)
    {
        Func<JsonElement, IComparable> key = row => field switch
        {
            1 => Json.Text(Json.Get(row, "torrent"), "site_name"),
            2 => Json.Number(Json.Get(row, "torrent"), "size"),
            3 => Json.Number(Json.Get(row, "torrent"), "seeders"),
            4 => Json.Text(Json.Get(row, "torrent"), "pubdate"),
            _ => Json.Number(Json.Get(row, "torrent"), "pri_order")
        };
        return ascending ? rows.OrderBy(key) : rows.OrderByDescending(key);
    }
    public static string State(JsonElement value) => Json.Text(value, "state") switch { "P" => "暂停", "O" => "已完成", _ => "追更中" };
    public static bool IsMovie(JsonElement value) => Json.First(value, "type", "media_type").ToLowerInvariant() is "movie" or "电影";
    public static string Identity(JsonElement item)
    {
        if (Json.Text(item, "media_id") is { Length: > 0 } mediaId) return $"{mediaId}:{(IsMovie(item) ? "movie" : "tv")}:{Json.Number(item, "season", 1):0}";
        var sources = new[] { ("tmdb", new[] { "tmdbid", "tmdb_id" }), ("douban", new[] { "doubanid", "douban_id" }), ("bangumi", new[] { "bangumiid", "bangumi_id" }) };
        foreach (var (name, keys) in sources) if (Json.First(item, keys) is { Length: > 0 } id) return $"{name}:{id}:{(IsMovie(item) ? "movie" : "tv")}:{Json.Number(item, "season", 1):0}";
        return "";
    }
    public static bool Subscribed(JsonElement media, IEnumerable<JsonElement> subscriptions)
    {
        static HashSet<string> Keys(JsonElement row)
        {
            var keys = new HashSet<string>(StringComparer.OrdinalIgnoreCase); var direct = Json.Text(row, "media_id"); if (direct.Length > 0) keys.Add(direct);
            foreach (var (source, aliases) in new[] { ("tmdb", new[] { "tmdbid", "tmdb_id" }), ("douban", new[] { "doubanid", "douban_id" }), ("bangumi", new[] { "bangumiid", "bangumi_id" }) }) if (Json.First(row, aliases) is { Length: > 0 } value) keys.Add(source + ":" + value);
            return keys;
        }
        var ids = Keys(media); return subscriptions.Any(x => IsMovie(x) == IsMovie(media) && Json.Number(x, "season", 1) == Json.Number(media, "season", 1) && Keys(x).Overlaps(ids));
    }
    public static JsonObject NewSubscription(JsonElement media)
    {
        var raw = new JsonObject { ["name"] = Json.Title(media), ["title"] = Json.Title(media), ["type"] = IsMovie(media) ? "电影" : "电视剧", ["year"] = Json.Text(media, "year"), ["state"] = "R" };
        SetText(raw, Json.Text(media, "media_id"), false, "media_id"); SetText(raw, Json.Text(media, "media_source"), false, "media_source");
        SetText(raw, Json.First(media, "tmdbid", "tmdb_id"), true, "tmdbid", "tmdb_id");
        SetText(raw, Json.First(media, "doubanid", "douban_id"), false, "doubanid", "douban_id");
        SetText(raw, Json.First(media, "bangumiid", "bangumi_id"), true, "bangumiid", "bangumi_id");
        SetText(raw, Json.First(media, "poster", "poster_path"), false, "poster", "poster_path");
        SetText(raw, Json.First(media, "overview", "description"), false, "overview", "description");
        if (!IsMovie(media)) raw["season"] = (int)Json.Number(media, "season", 1);
        return raw;
    }
    public static void SetText(JsonObject raw, string value, bool numeric, params string[] keys)
    {
        value = value.Trim();
        if (value.Length == 0) { foreach (var key in keys) raw.Remove(key); return; }
        if (numeric && (!long.TryParse(value, out var id) || id <= 0)) throw new ArgumentException(keys[0] + " 必须是正整数。");
        foreach (var key in keys) raw[key] = numeric ? JsonValue.Create(long.Parse(value)) : JsonValue.Create(value);
    }
}

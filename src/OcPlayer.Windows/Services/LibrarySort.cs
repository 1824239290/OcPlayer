using System.Text.Json;
using OcPlayer.Windows.Preview;

namespace OcPlayer.Windows.Services;

public sealed record LibrarySortSettings(string Field = "name", bool Ascending = true, string WatchState = "all");

internal static class LibrarySort
{
    public static string[] Options(string collectionType) => collectionType.ToLowerInvariant() switch
    {
        "movies" or "boxsets" => ["name", "dateAdded", "year", "rating", "runtime", "random"],
        "tvshows" => ["name", "dateAdded", "year", "rating", "random"],
        _ => ["name", "dateAdded", "random"]
    };

    public static string Label(string field) => field switch
    {
        "name" => "名称", "dateAdded" => "最近添加", "year" => "年份",
        "rating" => "评分", "runtime" => "时长", "random" => "随机", _ => "名称"
    };

    public static string WatchLabel(string state) => state switch
    {
        "watched" => "看过", "unwatched" => "没看过", _ => "全部"
    };

    public static LibrarySortSettings Resolve(LibrarySortSettings saved, string collectionType) => saved with
    {
        Field = Options(collectionType).Contains(saved.Field) ? saved.Field : "name",
        WatchState = saved.WatchState is "all" or "watched" or "unwatched" ? saved.WatchState : "all"
    };

    // Only local/demo catalogs are sorted here. Server pages already arrive in
    // their complete ordering, including the server's name-ascending tie break.
    public static IEnumerable<DemoMedia> Apply(IEnumerable<DemoMedia> items, LibrarySortSettings settings)
    {
        items = settings.WatchState switch
        {
            "watched" => items.Where(x => x.IsPlayed),
            "unwatched" => items.Where(x => !x.IsPlayed),
            _ => items
        };
        if (settings.Field == "random") return items.OrderBy(_ => Random.Shared.Next());
        if (settings.Field == "dateAdded") return settings.Ascending ? items.Reverse() : items;
        var ordered = settings.Field switch
        {
            "year" => Order(x => int.TryParse(x.Year, out var year) ? year : 0),
            "rating" => Order(x => x.CommunityRating ?? 0),
            "runtime" => Order(x => x.DurationSeconds),
            _ => Order(x => x.Title)
        };
        return settings.Field == "name" ? ordered : ordered.ThenBy(x => x.Title);

        IOrderedEnumerable<DemoMedia> Order<T>(Func<DemoMedia, T> key) => settings.Ascending
            ? items.OrderBy(key) : items.OrderByDescending(key);
    }
}

internal sealed class LibrarySortPreferences(string path)
{
    private readonly Dictionary<string, LibrarySortSettings> _values = Load(path);

    public LibrarySortSettings Get(string key, string collectionType) =>
        LibrarySort.Resolve(_values.GetValueOrDefault(key) ?? new LibrarySortSettings(), collectionType);

    public void Set(string key, LibrarySortSettings settings)
    {
        _values[key] = settings;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(_values));
        File.Move(temporary, path, true);
    }

    private static Dictionary<string, LibrarySortSettings> Load(string path)
    {
        try { return File.Exists(path) ? JsonSerializer.Deserialize<Dictionary<string, LibrarySortSettings>>(File.ReadAllText(path)) ?? [] : []; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { return []; }
    }
}

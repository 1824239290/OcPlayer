namespace OcPlayer.Windows.Services;

internal static class ViewingAnalytics
{
    public static (string Name, double Seconds)[] Genres(IEnumerable<ViewingRecord> records) => records.SelectMany(record =>
    {
        var names = record.Media.Category.Split(" / ", StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Distinct().ToArray();
        if (names.Length == 0) names = ["未分类"];
        return names.Select(name => (Name: name, Seconds: record.Seconds / names.Length));
    }).GroupBy(x => x.Name).Select(x => (Name: x.Key, Seconds: x.Sum(y => y.Seconds))).OrderByDescending(x => x.Seconds).ToArray();
    public static (string Title, double Seconds)[] Top(IEnumerable<ViewingRecord> records) => records.GroupBy(x => x.Source + "/" + (x.Media.SeriesId ?? x.Media.Id))
        .Select(x => (Title: x.First().Media.SeriesTitle ?? x.First().Media.Title, Seconds: x.Sum(y => y.Seconds))).OrderByDescending(x => x.Seconds).Take(3).ToArray();
    public static string Category(ViewingRecord row) => row.Source == "local" ? "本地 / 直连" : row.Media.Kind is "episode" or "series" ? "剧集" : "电影";
}

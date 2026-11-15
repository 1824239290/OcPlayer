namespace OcPlayer.Windows.Preview;

public sealed record DemoMedia(string Id, string Title, string OriginalTitle, string Year,
    string Category, string Artwork, string Description, double Progress = 0,
    string? EpisodeLabel = null, int? RemainingMinutes = null, string Kind = "movie", string StillArtwork = "",
    string BackdropArtwork = "", string LogoArtwork = "", double DurationSeconds = 10140, DemoEpisode[]? Episodes = null, string DetailArtwork = "", DemoPerson[]? Cast = null,
    string? SourceUri = null, DemoSeason[]? Seasons = null, string? SelectedSeasonId = null,
    string? SeriesId = null, string? SeasonId = null, int? SeasonNumber = null, int? EpisodeNumber = null, bool? Played = null)
{
    public bool IsPlayed => Played ?? Progress >= 100;

    public bool SelectedIsPlayed(int selectedNumber) => Kind == "series"
        ? Episodes?.FirstOrDefault(x => x.Available && x.Number == selectedNumber)?.IsPlayed == true
        : IsPlayed;

    public double PlaybackProgress(int selectedNumber, bool demoMode = false)
    {
        var episode = Kind == "series" ? Episodes?.FirstOrDefault(x => x.Number == selectedNumber) : null;
        var progress = episode is null ? Progress : episode.Available ? episode.Progress : 0;
        if (demoMode && episode is { Available: true } && EpisodeLabel == $"S{episode.SeasonNumber}E{episode.Number}") progress = Progress;
        return double.IsFinite(progress) ? Math.Clamp(progress, 0, 100) : 0;
    }

    public double PlaybackPositionSeconds(int selectedNumber, bool demoMode = false)
    {
        var progress = PlaybackProgress(selectedNumber, demoMode);
        if (progress is <= 0 or >= 100) return 0;
        var episode = Kind == "series" ? Episodes?.FirstOrDefault(x => x.Number == selectedNumber) : null;
        var duration = episode is { DurationSeconds: > 0 } ? episode.DurationSeconds : DurationSeconds;
        return double.IsFinite(duration) && duration > 0 ? duration * progress / 100 : 0;
    }

    public string PlaybackButtonLabel(int selectedNumber, bool demoMode = false)
    {
        if (PlaybackProgress(selectedNumber, demoMode) is <= 0 or >= 100) return "播放";
        var seconds = Math.Floor(PlaybackPositionSeconds(selectedNumber, demoMode));
        return $"继续 {Math.Floor(seconds / 3600):00}:{Math.Floor(seconds / 60) % 60:00}:{seconds % 60:00}";
    }

    public int InitialEpisodeNumber
    {
        get
        {
            var number = EpisodeNumber;
            if (number is null && EpisodeLabel is { } label && label.LastIndexOf('E') is var separator && separator >= 0
                && int.TryParse(label[(separator + 1)..], out var parsed)) number = parsed;
            return Episodes?.FirstOrDefault(x => x.Available && x.Number == number)?.Number
                ?? Episodes?.FirstOrDefault(x => x.Available)?.Number ?? 1;
        }
    }
    public static string AssetPath(string value) => value.Length == 0 || Uri.IsWellFormedUriString(value, UriKind.Absolute) || Path.IsPathRooted(value)
        ? value : Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", value);
    public string PosterPath => AssetPath(Artwork);
    public string Subtitle => $"{Year}  ·  {Category}";
    public string Backdrop => AssetPath(BackdropArtwork.Length > 0 ? BackdropArtwork : Artwork);
    public string DetailBackdrop => AssetPath(DetailArtwork.Length > 0 ? DetailArtwork : BackdropArtwork.Length > 0 ? BackdropArtwork : Artwork);
    public string LogoPath => AssetPath(LogoArtwork);
    public string StillPath => AssetPath(StillArtwork.Length > 0 ? StillArtwork : Id switch
    {
        "interstellar" => "interstellar-backdrop.jpg", "dune" => "dune-still.jpg", _ => Artwork
    });
}

public sealed record DemoPerson(string Name, string Role, string Artwork);

public sealed record DemoEpisode(int Number, string Title, string Artwork, bool Available = true, string? MediaId = null, int SeasonNumber = 1,
    double Progress = 0, double DurationSeconds = 0, bool? Played = null)
{
    public bool IsPlayed => Played ?? Progress >= 100;
    public string WatchStatus => !Available ? "未入库" : IsPlayed ? "已观看" : Progress > 0 ? "观看中" : "未观看";
}
public sealed record DemoSeason(string Id, string Title, int? Number = null);

public static class DemoCatalog
{
    public static IReadOnlyList<DemoMedia> All { get; } = System.Text.Json.JsonSerializer.Deserialize<DemoMedia[]>(
        File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", "catalog.json")))!;
    public static IReadOnlyList<DemoMedia> ResumeItems { get; } = All.Where(x => x.Progress > 0).Reverse().ToArray();
    public static IReadOnlyList<DemoMedia> LatestItems { get; } = All.Take(7).ToArray();
    public static IReadOnlyList<DemoMedia> NextItems { get; } = new[] { "我的朋友很少", "阿松", "药屋少女的呢喃", "冰之城墙" }.Select(title => All.First(x => x.Title == title) with { EpisodeLabel = "S1E1", RemainingMinutes = 24 }).ToArray();
    public static IReadOnlyList<DemoMedia> Movies { get; } =
    [
        new("interstellar", "星际穿越", "INTERSTELLAR", "2014", "科幻 / 冒险", "interstellar.jpg",
            "当地球的未来渐渐失去希望，一支探险队穿越虫洞，前往遥远星系寻找新的家园。在浩瀚宇宙之间，时间、爱与选择交织成一段旅程。", 42),
        new("dune", "沙丘", "DUNE", "2021", "科幻 / 剧情", "dune.jpg",
            "少年保罗随家族来到厄拉科斯。在沙漠、香料与命运的交汇处，一场改变宇宙的旅程开始了。", 18),
        new("spirited", "千与千寻", "SPIRITED AWAY", "2001", "动画 / 奇幻", "spirited-away.jpg",
            "千寻误入神灵的世界，在陌生的汤屋里学会勇气与成长，也寻找回到家人身边的道路。"),
        new("arrival", "降临", "ARRIVAL", "2016", "科幻 / 悬疑", "arrival.jpg",
            "神秘飞船降落地球。语言学家路易斯尝试理解访客的语言，并发现时间与生命有着不同的形状。"),
        new("blade", "银翼杀手 2049", "BLADE RUNNER 2049", "2017", "科幻 / 悬疑", "blade-runner.jpg",
            "银翼杀手 K 发现一个被深埋的秘密，踏上寻找真相的旅程，追问记忆与人性的意义。")
    ];

    public static string BackdropPath => Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", "interstellar-backdrop.jpg");
}

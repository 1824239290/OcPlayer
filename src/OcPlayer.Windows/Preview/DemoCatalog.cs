namespace OcPlayer.Windows.Preview;

public sealed record DemoMedia(string Id, string Title, string OriginalTitle, string Year,
    string Category, string Artwork, string Description, double Progress = 0,
    string? EpisodeLabel = null, int? RemainingMinutes = null)
{
    public string PosterPath => Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", Artwork);
    public string Subtitle => $"{Year}  ·  {Category}";
    public string StillPath => Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", Id switch
    {
        "interstellar" => "interstellar-backdrop.jpg", "dune" => "dune-still.jpg", _ => Artwork
    });
}

public static class DemoCatalog
{
    // Artwork-only crops from the user's macOS reference. Cards and chrome remain native WinUI controls.
    public static IReadOnlyList<DemoMedia> ResumeItems { get; } =
    [
        new("fanren", "凡人修仙传 · 慕兰之战 24", "凡人修仙传", "2026", "动画", "fanren.jpg",
            "凡人修仙传。", 1, "S1E200", 19),
        new("kurumi", "FX 战士久留美 · 我不要被强制平仓啊……", "FX 战士久留美", "2026", "动画", "kurumi.jpg",
            "FX 战士久留美。", 1, "S1E7", 23)
    ];
    public static IReadOnlyList<DemoMedia> LatestItems { get; } =
    [
        new("after-rain", "水饺皇后", "水饺皇后", "2025", "剧情", "after-the-rain.jpg", "水饺皇后。"),
        new("ice-castle", "冰之城墙", "冰之城墙", "2026", "剧情", "ice-castle.jpg", "冰之城墙。"),
        new("ranma", "乱马 1/2", "乱马 1/2", "2024", "动作", "ranma.jpg", "乱马 1/2。"),
        new("student-council", "学生会也有洞！", "学生会也有洞！", "2026", "动画", "student-council.jpg", "学生会也有洞！")
    ];
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

using System.ComponentModel;
using System.Runtime.CompilerServices;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows.ViewModels;

// Shared presentation state for the explicit preview and the Core-backed catalogs.
public sealed class DemoViewModel : INotifyPropertyChanged
{
    private readonly string _layoutPath = Path.Combine(AppPaths.DataDirectory, "browser-preferences.json");
    public DemoViewModel()
    {
        try
        {
            var saved = System.Text.Json.JsonSerializer.Deserialize<BrowserPreferences>(File.ReadAllText(_layoutPath));
            if (saved is null) return;
            HomeSections.Clear(); HomeSections.AddRange(saved.Sections.Where(x => new[] { "继续观看", "最近添加", "媒体库", "接下来看" }.Contains(x)).Distinct());
            foreach (var name in new[] { "继续观看", "最近添加", "媒体库", "接下来看" }) if (!HomeSections.Contains(name)) HomeSections.Add(name);
            HiddenSections.UnionWith(saved.Hidden); _themeMode = saved.Theme; EpisodesDescending = saved.Descending;
        }
        catch (Exception ex) when (ex is IOException or System.Text.Json.JsonException) { }
    }
    private sealed record BrowserPreferences(string[] Sections, string[] Hidden, string Theme, bool Descending);
    public void SaveHomeSections()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_layoutPath)!);
        File.WriteAllText(_layoutPath + ".tmp", System.Text.Json.JsonSerializer.Serialize(new BrowserPreferences(HomeSections.ToArray(), HiddenSections.ToArray(), ThemeMode, EpisodesDescending)));
        File.Move(_layoutPath + ".tmp", _layoutPath, true);
    }
    private string _themeMode = "system";
    public string ThemeMode { get => _themeMode; set { _themeMode = value is "light" or "dark" ? value : "system"; SaveHomeSections(); } }
    public bool EpisodesDescending { get; set; }
    public Dictionary<string, int> SeasonSelection { get; } = [];
    public bool HomeLoading { get; set; }
    public bool LibraryLoading { get; set; }
    public string? LibraryError { get; set; }
    public string? LibraryCacheNotice { get; set; }
    public int? LibraryTotalCount { get; set; }
    public int LibraryNextIndex { get; set; }
    public bool LibraryHasMore { get; set; }
    public string? EpisodeError { get; set; }
    public bool EpisodesLoading { get; set; }
    public string? PendingSeasonId { get; set; }
    private string _query = "";
    private string _category = "全部";
    private readonly LibrarySortPreferences _librarySort = new(Path.Combine(AppPaths.DataDirectory, "library-sort.json"));
    private bool _darkTheme = true;
    public List<string> HomeSections { get; } = ["继续观看", "最近添加", "媒体库", "接下来看"];
    public HashSet<string> HiddenSections { get; } = [];
    public Dictionary<string, object> Preferences { get; } = [];
    public HashSet<string> Watched { get; } = [];
    public bool DemoMode => App.DemoMode;
    public IReadOnlyList<DemoMedia>? ServerItems { get; set; }
    public string? LibraryId { get; set; }
    public IReadOnlyList<DemoMedia> Catalog => DemoMode ? DemoCatalog.All : ServerItems ?? (IReadOnlyList<DemoMedia>?)App.Core?.LocalMedia ?? Array.Empty<DemoMedia>();
    public IEnumerable<DemoMedia> ResumeItems => DemoMode ? DemoCatalog.ResumeItems : App.Core?.Server?.Resume ?? Catalog.Where(x => x.Progress > 0 && x.Progress < 100);
    public IEnumerable<DemoMedia> LatestItems => DemoMode ? DemoCatalog.LatestItems : App.Core?.Server?.Latest ?? Catalog.Take(24);
    public IEnumerable<DemoMedia> NextItems => DemoMode ? DemoCatalog.NextItems : App.Core?.Server?.NextUp ?? (IEnumerable<DemoMedia>)Array.Empty<DemoMedia>();
    public int SelectedEpisode { get; set; } = 1;
    public string Route { get; set; } = "home";
    public string LibraryName { get; set; } = "全部媒体库";
    public DemoMedia SelectedMedia { get; set; } = DemoCatalog.All[4];
    private bool _bangumiEnabled = true, _moviePilotEnabled = true;
    public bool BangumiEnabled { get => DemoMode ? _bangumiEnabled : App.Core?.Integrations.Bangumi is { Enabled: true }; set => _bangumiEnabled = value; }
    public bool MoviePilotEnabled { get => DemoMode ? _moviePilotEnabled : App.Core?.Integrations.MoviePilot is { Enabled: true }; set => _moviePilotEnabled = value; }
    public string Query { get => _query; set => Set(ref _query, value); }
    public string Category { get => _category; set => Set(ref _category, value); }
    public string LibraryCollectionType => DemoMode ? LibraryName switch
    {
        "电视剧" => "tvshows", "电影" => "movies", "合集" => "boxsets", _ => ""
    } : App.Core?.Server?.Libraries.FirstOrDefault(x => x.Id == LibraryId)?.CollectionType ?? "";
    private string LibrarySortKey => $"{(DemoMode ? "demo" : App.Core?.Server?.Profile.Id ?? "local")}:{LibraryId ?? LibraryName}:{Category}";
    public LibrarySortSettings LibrarySort
    {
        get => _librarySort.Get(LibrarySortKey, LibraryCollectionType);
        set { _librarySort.Set(LibrarySortKey, value); PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(LibrarySort))); }
    }
    public bool DarkTheme { get => _darkTheme; set => Set(ref _darkTheme, value); }

    public IEnumerable<DemoMedia> FilteredMovies
    {
        get
        {
            var catalog = LibraryName switch
            {
                "电视剧" => Catalog.Where(x => x.Kind == "series"),
                "电影" => Catalog.Where(x => x.Kind == "movie"),
                _ => Catalog
            };
            if (!DemoMode && App.Core?.Server is not null) return catalog;
            var items = catalog.Where(m =>
                (string.IsNullOrWhiteSpace(Query) || m.Title.Contains(Query, StringComparison.OrdinalIgnoreCase)
                    || m.OriginalTitle.Contains(Query, StringComparison.OrdinalIgnoreCase))
                && (Category == "全部" || m.Category.Contains(Category)));
            return !DemoMode && App.Core?.Server is not null ? items : Services.LibrarySort.Apply(items, LibrarySort);
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}

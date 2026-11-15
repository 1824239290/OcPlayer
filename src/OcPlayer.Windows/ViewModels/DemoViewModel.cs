using System.ComponentModel;
using System.Runtime.CompilerServices;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows.ViewModels;

// Shared presentation state for the explicit preview and the Core-backed catalogs.
public sealed class DemoViewModel : INotifyPropertyChanged
{
    private string _query = "";
    private string _category = "全部";
    private readonly LibrarySortPreferences _librarySort = new(Path.Combine(
        Environment.GetEnvironmentVariable("OCP_DATA_DIRECTORY") ??
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OcPlayer", "Windows"),
        "library-sort.json"));
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
    public bool BangumiEnabled { get; set; } = App.DemoMode;
    public bool MoviePilotEnabled { get; set; } = App.DemoMode;
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

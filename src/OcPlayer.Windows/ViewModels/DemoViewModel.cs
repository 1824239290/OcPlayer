using System.ComponentModel;
using System.Runtime.CompilerServices;
using OcPlayer.Windows.Preview;

namespace OcPlayer.Windows.ViewModels;

// Preview-only presentation state. Production clients can replace the catalog without changing card views.
public sealed class DemoViewModel : INotifyPropertyChanged
{
    private string _query = "";
    private string _category = "全部";
    private string _sort = "推荐顺序";
    private string _watchState = "全部状态";
    private bool _darkTheme = true;
    public string Route { get; set; } = "home";
    public string LibraryName { get; set; } = "全部媒体库";
    public DemoMedia SelectedMedia { get; set; } = DemoCatalog.Movies[0];
    public bool BangumiEnabled { get; set; } = true;
    public bool MoviePilotEnabled { get; set; } = true;
    public string Query { get => _query; set => Set(ref _query, value); }
    public string Category { get => _category; set => Set(ref _category, value); }
    public string Sort { get => _sort; set => Set(ref _sort, value); }
    public string WatchState { get => _watchState; set => Set(ref _watchState, value); }
    public bool DarkTheme { get => _darkTheme; set => Set(ref _darkTheme, value); }

    public IEnumerable<DemoMedia> FilteredMovies
    {
        get
        {
            var catalog = LibraryName switch
            {
                "电视剧" => DemoCatalog.ResumeItems.Concat(DemoCatalog.LatestItems.Skip(1)),
                "电影" => DemoCatalog.Movies.Concat(DemoCatalog.LatestItems.Take(1)),
                _ => DemoCatalog.ResumeItems.Concat(DemoCatalog.LatestItems).Concat(DemoCatalog.Movies)
            };
            var items = catalog.Where(m =>
                (string.IsNullOrWhiteSpace(Query) || m.Title.Contains(Query, StringComparison.OrdinalIgnoreCase)
                    || m.OriginalTitle.Contains(Query, StringComparison.OrdinalIgnoreCase))
                && (Category == "全部" || m.Category.Contains(Category))
                && (WatchState == "全部状态" || (WatchState == "继续观看" ? m.Progress > 0 : m.Progress == 0)));
            return Sort switch { "名称" => items.OrderBy(m => m.Title), "年份" => items.OrderByDescending(m => m.Year), _ => items };
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

using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Controls;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;
using OcPlayer.Windows.ViewModels;
using Windows.UI;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed partial class DemoPages(DemoViewModel model, PageLayout pageLayout, Action<string> navigate, Action<DemoMedia> open,
    Action<DemoMedia> play, Action<bool> themeChanged, Action<DemoMedia, bool>? markWatched = null,
    Action<DemoMedia, DemoEpisode, bool>? markEpisodeWatched = null, Action? loadMore = null, Action? retryLibrary = null,
    Action? refreshHome = null, Action? configureHome = null, Action? retrySeason = null)
{
    public UIElement Home()
    {
        if (!model.DemoMode && App.Core?.Server is null && model.Catalog.Count == 0) return Welcome();
        var page = Stack(48);
        if (model.HomeLoading) page.Children.Add(new ProgressBar { IsIndeterminate = true, Height = 3 });
        if (App.Core?.Server?.HomeWarning is { } warning)
        { var status = Stack(8); status.Children.Add(Muted(warning)); status.Children.Add(Button("重试刷新", () => refreshHome?.Invoke())); page.Children.Add(status); }
        if (model.HomeSections.All(model.HiddenSections.Contains))
        { page.Children.Add(Text("首页栏目都已关闭", 20, true)); page.Children.Add(Button("去设置", () => configureHome?.Invoke())); }
        foreach (var title in model.HomeSections.Where(x => !model.HiddenSections.Contains(x)))
        {
            if (title == "继续观看" && model.ResumeItems.Any()) page.Children.Add(StillSection(title, model.ResumeItems, true));
            else if (title == "最近添加" && model.LatestItems.Any()) page.Children.Add(StillSection(title, model.LatestItems, false));
            else if (title == "接下来看" && model.NextItems.Any()) page.Children.Add(StillSection(title, model.NextItems, true, showProgress: false));
            else if (title == "媒体库" && (model.DemoMode || App.Core?.Server is null || App.Core.Server.Libraries.Count > 0)) page.Children.Add(Libraries());
        }
        if (model.HomeLoading && !model.LatestItems.Any())
        { var placeholders = Row(20); for (var i = 0; i < 4; i++) placeholders.Children.Add(new Border { Width = 200, Height = 130, CornerRadius = new CornerRadius(8), Background = Resource("CardBackgroundFillColorDefaultBrush") }); page.Children.Add(placeholders); }
        if (!model.DemoMode && !model.HomeLoading && App.Core?.Server is { Libraries.Count: 0 })
        { page.Children.Add(Muted("服务器没有可见的媒体内容，请检查媒体库和账号权限。")); page.Children.Add(Button("重试", () => refreshHome?.Invoke())); }
        return pageLayout.Scroll(page, new Thickness(52, 56, 0, 36));
    }
    private UIElement Libraries()
    {
        var librarySection = Stack(26);
        librarySection.Children.Add(Text("媒体库", 14, true));
        var libraries = Row(22);
        var entries = model.DemoMode ? new[] {
            new MediaLibrary("", "电视剧", DemoCatalog.All[4].Backdrop, "tvshows"),
            new MediaLibrary("", "电影", DemoCatalog.All[1].Backdrop, "movies"),
            new MediaLibrary("", "合集", "", "boxsets", DemoCatalog.All.Take(4).Select(x => x.PosterPath).ToArray()) }
            : App.Core?.Server is { } server ? server.Libraries.ToArray() : new[] { new MediaLibrary("", "本地媒体", "") };
        foreach (var library in entries)
        {
            libraries.Children.Add(new LibraryCard(library, () => {
                model.Query = ""; model.Category = "全部"; model.LibraryName = library.Name;
                model.LibraryId = string.IsNullOrEmpty(library.Id) ? null : library.Id; navigate("library");
            }));
        }
        librarySection.Children.Add(new HorizontalMediaRail(libraries, "媒体库")); return librarySection;
    }

    public UIElement Library()
    {
        var layout = new Grid();
        var items = model.FilteredMovies.ToArray();
        var grid = new MediaLibraryGrid(items, open);
        // Container padding supplies half the gap at the edges of the poster grid.
        pageLayout.ApplyInset(grid, Control.PaddingProperty, new Thickness(40, 8, 40, 24));
        var empty = Muted(model.LibraryLoading ? "正在加载媒体库…" : model.LibraryError ?? (model.Query.Length is > 0 and < 2 ? "没有匹配的作品，请输入至少两个字再试。" : model.Query.Length > 0 ? "没有匹配的作品。搜索范围为电影和剧集，不包含单集标题。" : "媒体库暂无内容")); empty.HorizontalAlignment=HorizontalAlignment.Center;empty.VerticalAlignment=VerticalAlignment.Center;
        layout.Children.Add(grid); layout.Children.Add(empty);
        empty.Visibility=items.Length==0?Visibility.Visible:Visibility.Collapsed;
        var footer = Stack(10); footer.Margin = new Thickness(12, 20, 12, 30);
        footer.Children.Add(Muted($"已加载 {items.Length}" + (model.LibraryTotalCount is { } total ? $" / {total}" : "")));
        if (model.LibraryCacheNotice is { } cache) footer.Children.Add(Muted(cache));
        if (model.LibraryLoading) footer.Children.Add(new ProgressBar { IsIndeterminate = true });
        else if (model.LibraryError is { } error) { footer.Children.Add(Muted(error)); footer.Children.Add(Button("重试", () => { if (items.Length > 0 && model.LibraryHasMore) loadMore?.Invoke(); else retryLibrary?.Invoke(); })); }
        else if (model.LibraryHasMore) footer.Children.Add(Button("加载更多", () => loadMore?.Invoke()));
        grid.Footer = footer;
        if (loadMore is not null) grid.Loaded += (_, _) =>
        {
            if (FindChild<ScrollViewer>(grid) is { } scroll) scroll.ViewChanged += (_, _) =>
            { if (scroll.ScrollableHeight > 0 && scroll.VerticalOffset >= scroll.ScrollableHeight - 500 && model.LibraryHasMore && !model.LibraryLoading && model.LibraryError is null) loadMore(); };
        };
        return layout;
    }
    public UIElement Detail()
    {
        var media=model.SelectedMedia;
        var layout=new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        DetailPageWheelNavigation.Attach(layout, () => navigate("detail-info"));
        var body=new Grid{Margin=new Thickness(52,8,40,12),RowSpacing=10};
        pageLayout.ApplyInset(body, FrameworkElement.MarginProperty, new Thickness(52,8,40,12));
        body.RowDefinitions.Add(new RowDefinition{Height=new GridLength(1,GridUnitType.Star)});body.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});
        var content=Stack(10);content.Width=430;content.HorizontalAlignment=HorizontalAlignment.Left;
        if(media.LogoArtwork.Length>0){var logo=Image(media.LogoPath,Stretch.Uniform);logo.MaxWidth=220;logo.MaxHeight=72;logo.HorizontalAlignment=HorizontalAlignment.Left;content.Children.Add(logo);}else content.Children.Add(Text(media.Title,26,true));
        if(!string.IsNullOrWhiteSpace(media.OriginalTitle) && media.OriginalTitle != media.Title) content.Children.Add(Muted(media.OriginalTitle,12));
        content.Children.Add(Muted($"{media.Year}   ·   {media.Category}   ·   {(int)(media.DurationSeconds/60)} 分钟"+(media.Kind=="series"?$"   ·   {media.Seasons?.Length ?? 1} 季":""),11));
        var tags = Row(6);
        foreach (var genre in media.Category.Split(" / ", StringSplitOptions.RemoveEmptyEntries))
        {
            var tag = new Button { Content = genre, Padding = new Thickness(10, 3, 10, 3), FontSize = 12 };
            tag.Click += (_, _) => navigate("genre:" + genre);
            tags.Children.Add(tag);
        }
        if (media.CommunityRating is { } rating) tags.Children.Add(Muted($"★ {rating:0.0}", 12));
        if (!string.IsNullOrEmpty(media.OfficialRating)) tags.Children.Add(Muted(media.OfficialRating, 12));
        content.Children.Add(tags);
        content.Children.Add(ExpandableSynopsis(string.IsNullOrWhiteSpace(media.SeasonOverview) ? media.Description : media.SeasonOverview, 2));
        if (media.DetailWarning is { } detailWarning) { content.Children.Add(Muted(detailWarning)); content.Children.Add(Button("重试", () => navigate("detail:retry"))); }
        var actions = Row(10);
        var playButton = new PlaybackProgressButton(() => play(media));
        playButton.SetProgress(media, model.SelectedEpisode, model.DemoMode);
        actions.Children.Add(playButton);
        playButton.IsEnabled = media.Kind != "boxSet" && (media.Kind != "series" || media.Episodes?.Any(x => x.Available) == true);
        var watched = new ToggleButton { Height = 36 };
        var updatingWatched = false;
        UpdateWatched();
        watched.Click += (_, _) =>
        {
            var episode = media.Kind == "series" ? media.Episodes?.FirstOrDefault(x => x.Available && x.Number == model.SelectedEpisode) : null;
            var isWatched = watched.IsChecked == true;
            if (media.Kind == "series")
            {
                if (episode is null) { UpdateWatched(); return; }
                if (!model.DemoMode && markEpisodeWatched is not null)
                {
                    updatingWatched = true; watched.IsEnabled = false;
                    markEpisodeWatched(media, episode, isWatched);
                    return;
                }
                model.SelectedMedia = media with { Episodes = media.Episodes?.Select(x =>
                    x.Number == episode.Number ? x with { Progress = isWatched ? 100 : 0, Played = isWatched } : x).ToArray() };
                navigate("detail");
                return;
            }
            if (!model.DemoMode && markWatched is not null)
            {
                updatingWatched = true; watched.IsEnabled = false;
                markWatched(media, isWatched);
                return;
            }
            if (isWatched) model.Watched.Add(media.Id); else model.Watched.Remove(media.Id);
            model.SelectedMedia = media with { Progress = isWatched ? 100 : 0, Played = isWatched };
            navigate("detail");
        };

        void UpdateWatched()
        {
            var episode = media.Kind == "series" ? media.Episodes?.FirstOrDefault(x => x.Available && x.Number == model.SelectedEpisode) : null;
            var isPlayed = media.SelectedIsPlayed(model.SelectedEpisode);
            watched.IsChecked = isPlayed;
            watched.Content = isPlayed ? "已观看" : "未观看";
            watched.IsEnabled = !updatingWatched && (media.Kind != "series" || episode is not null);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(watched, episode is null
                ? (string)watched.Content : $"第 {episode.Number} 集，{watched.Content}");
            ToolTipService.SetToolTip(watched, (isPlayed ? "标记为未观看" : "标记为已观看")
                + (episode is null ? "" : $" · 第 {episode.Number} 集"));
        }
        actions.Children.Add(watched);
        content.Children.Add(actions);
        Grid.SetRow(content, 0);
        body.Children.Add(content);
        var lower=Stack(10);Grid.SetRow(lower,1);
        if(media.Kind=="series")
        {
            lower.Children.Add(CreateEpisodePicker(media, false, () =>
            {
                playButton.SetProgress(media, model.SelectedEpisode, model.DemoMode);
                UpdateWatched();
            }));
        }
        else if (media.Kind == "boxSet") lower.Children.Add(Button($"合集内容 · {media.MemberCount ?? media.Members?.Length ?? 0} 项", () => navigate("detail-info")));
        else
        {
            var movieCard = new ListViewItem { Content = Image(media.StillPath), Width = 190, Height = 108, IsSelected = true };
            ToolTipService.SetToolTip(movieCard, "正片 · " + media.Title + "（双击播放）");
            movieCard.DoubleTapped += (_, args) => { play(media); args.Handled = true; };
            var film = Stack(5); film.Children.Add(movieCard); film.Children.Add(Text("正片 · " + media.Title, 12)); lower.Children.Add(film);
        }
        body.Children.Add(lower);layout.Children.Add(body);return layout;
    }
    public UIElement DetailInformation()
    {
        var media=model.SelectedMedia;var page=Stack(26);
        var synopsis = new ContentControl();
        void UpdateSynopsis() => synopsis.Content = ExpandableSynopsis(media.Episodes?.FirstOrDefault(x => x.Number == model.SelectedEpisode)?.Overview is { Length: > 0 } overview ? overview : media.SeasonOverview is { Length: > 0 } seasonOverview ? seasonOverview : media.Description, 4);
        UpdateSynopsis(); page.Children.Add(synopsis);
        var fileInfo = new ContentControl();
        if(media.Kind=="series")
        {
            page.Children.Add(CreateEpisodePicker(media, true, () => { UpdateSynopsis(); fileInfo.Content = MediaInformation(media); }));
        }
        if(!model.DemoMode && model.BangumiEnabled && media.Kind=="series")
            page.Children.Add(new IntegrationPages(pageLayout, navigate, open).MediaAssociation(media));
        if(model.DemoMode&&model.BangumiEnabled&&media.Kind=="series")
        {
            page.Children.Add(Text("Bangumi   "+media.Title,16,true));var chapters=Row(6);
            for(var i=1;i<=12;i++){var n=i;var text=Stack(2);text.Children.Add(Text(n.ToString("00"),12,true));text.Children.Add(Muted(n<=6?"看过":"未看",10));var button=Button("",()=>{model.SelectedEpisode=n;navigate("detail-info");});button.Content=text;button.Padding=new Thickness(12,6,12,6);button.IsEnabled=n<8;chapters.Children.Add(button);}page.Children.Add(new HorizontalMediaRail(chapters, "Bangumi 章节", 0));
            page.Children.Add(Muted("其他",12));var extras=Row(6);foreach(var label in new[]{"OP 01","ED 01","ED 02"})extras.Children.Add(Button(label+"\n未看",()=>{}));page.Children.Add(extras);
        }
        if(model.MoviePilotEnabled){page.Children.Add(Text("MoviePilot",16,true));var stack=Stack(5);stack.Children.Add(Text("搜索站点资源并下载",13,true));stack.Children.Add(Muted("按标题搜、可选站点；下载完成后 MoviePilot 自动整理入库，稍后出现在媒体库",11));var action=Button("",()=>navigate(model.DemoMode ? "settings:MoviePilot" : "viewing:resources:" + Uri.EscapeDataString(media.Title)));action.Content=stack;action.HorizontalAlignment=HorizontalAlignment.Stretch;action.HorizontalContentAlignment=HorizontalAlignment.Stretch;page.Children.Add(action);}
        if(media.Cast is {Length:>0})
        {
            page.Children.Add(Text("演员",16,true));var cast=Row(22);
            foreach (var person in media.Cast)
            {
                var tile = Stack(6); tile.Width = 110;
                var portrait = new Grid { Background = new SolidColorBrush(Color.FromArgb(30, 255, 255, 255)) };
                if (person.Artwork.Length > 0) portrait.Children.Add(Image(DemoMedia.AssetPath(person.Artwork)));
                tile.Children.Add(new Border
                {
                    Child = portrait, Width = 100, Height = 100, CornerRadius = new CornerRadius(50),
                    HorizontalAlignment = HorizontalAlignment.Left
                });
                tile.Children.Add(Text(person.Name, 12, true));
                var role = Muted(person.Role, 10); role.MaxLines = 2; tile.Children.Add(role);
                cast.Children.Add(tile);
            }
            page.Children.Add(new HorizontalMediaRail(cast, "演员"));
        }
        page.Children.Add(Text("媒体信息",16,true));
        if (model.DemoMode) foreach(var (heading,fields) in new[]{("视频",new[]{"分辨率          1920 × 1080 · 16:9","编码              H264 · High","码率              1.7 Mbps","帧率              23.976 fps","动态范围      SDR","位深              8 bit"}),("音频",new[]{"音轨              日语 · AAC · stereo (2ch) · 48 kHz"}),("文件",new[]{"容器              MP4","大小              364.8 MB",$"时长              {(int)(media.DurationSeconds/60)} 分钟"})}){var block=Stack(10);block.Children.Add(Text(heading,13,true));foreach(var field in fields)block.Children.Add(Muted(field,12));page.Children.Add(Panel(block,new Thickness(18)));}
        else { fileInfo.Content = MediaInformation(media); page.Children.Add(fileInfo); }
        if (media.Kind == "boxSet") page.Children.Add(CollectionMembers(media));
        var recommendations = model.DemoMode ? model.Catalog.Where(x=>x.Id!=media.Id).Take(8) : media.Similar ?? [];
        if (recommendations.Any()) { page.Children.Add(Text("类似推荐",16,true));var similar=Row(16);foreach(var item in recommendations)similar.Children.Add(MediaCard(item,open,150));page.Children.Add(new HorizontalMediaRail(similar, "类似推荐")); }
        var scroll=pageLayout.Scroll(page, new Thickness(52,20,52,48));
        var layout = new Grid { Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        layout.Children.Add(scroll);
        DetailPageWheelNavigation.Attach(layout, () => navigate("detail"), scroll);
        return layout;
    }
    public UIElement Viewing()
    {
        if (!model.DemoMode)
        {
            var local = Stack(26); local.Margin = new Thickness(52,20,52,32);
            local.Children.Add(Text("观看记录", 20, true));
            foreach (var media in model.Catalog) local.Children.Add(ViewingRow(media));
            if (model.Catalog.Count == 0) local.Children.Add(Muted("打开本地文件或直连链接后，观看记录会显示在这里。"));
            return pageLayout.Scroll(local);
        }
        var page=Stack(26);page.MaxWidth=1000;page.HorizontalAlignment=HorizontalAlignment.Center;
        var profile=Row(14);var avatar=Image(Path.Combine(AppContext.BaseDirectory,"Assets","Demo","avatar.jpg"));avatar.Width=44;avatar.Height=44;profile.Children.Add(new Border{Child=avatar,CornerRadius=new CornerRadius(22)});var identity=Stack(4);identity.Children.Add(Text("橘木苏",20,true));identity.Children.Add(Muted("jumusu · Jellyfin 12.1.0 · 片单与追更",11));profile.Children.Add(identity);page.Children.Add(profile);
        if(model.BangumiEnabled)
        {
            var calendar=Stack(12);calendar.Children.Add(Text("番剧放送",14,true));calendar.Children.Add(Muted("在看 · 媒体库已有 · 按更新时间排序",11));
            var days=new Grid{ColumnSpacing=4};for(var i=0;i<7;i++){days.ColumnDefinitions.Add(new ColumnDefinition());var day=Button(new[]{"一","二","三","四","五","六","日"}[i],()=>{});day.HorizontalAlignment=HorizontalAlignment.Stretch;Grid.SetColumn(day,i);days.Children.Add(day);}calendar.Children.Add(days);calendar.Children.Add(Muted("这一天没有在看且媒体库已有的更新番剧",12));calendar.Children.Add(Muted("预计放送时间 · 本地时区 · bangumi-data",10));page.Children.Add(calendar);
        }
        page.Children.Add(Text("观看记录",14,true));
        var history=new Grid{ColumnSpacing=20};history.ColumnDefinitions.Add(new ColumnDefinition());history.ColumnDefinitions.Add(new ColumnDefinition());
        var today=Stack(12);today.Children.Add(Muted("今天                                        11月15日",11));today.Children.Add(Text("0.4 分钟",30,true));today.Children.Add(Muted("App 实播 0.4 分钟",11));today.Children.Add(Muted("已看 0 部电影 · 已看 0 集剧",11));today.Children.Add(Muted("另有 1 条 App 播放片段",11));history.Children.Add(Panel(today));
        var activity=Stack(12);activity.Children.Add(Text("观看活跃度                                      近 15 周",12));var cells=new Grid{ColumnSpacing=3,RowSpacing=3};for(var c=0;c<15;c++)cells.ColumnDefinitions.Add(new ColumnDefinition());for(var r=0;r<7;r++)cells.RowDefinitions.Add(new RowDefinition());for(var c=0;c<15;c++)for(var r=0;r<7;r++){var cell=new Border{Height=12,CornerRadius=new CornerRadius(2),Background=new SolidColorBrush(c<10?Color.FromArgb(25,150,150,150):Color.FromArgb((byte)(55+(c*11+r*23)%150),236,166,70))};Grid.SetColumn(cell,c);Grid.SetRow(cell,r);cells.Children.Add(cell);}activity.Children.Add(cells);activity.Children.Add(Muted("点击日期查看当天统计                    少 ▪ ▪ ▪ 多",10));var panel=Panel(activity);Grid.SetColumn(panel,1);history.Children.Add(panel);page.Children.Add(history);
        if(model.BangumiEnabled){var tiles=Row(16);tiles.Children.Add(Panel(Text("20   待看",22,true)));tiles.Children.Add(Panel(Text("8   在看",22,true)));page.Children.Add(tiles);}
        var month=Stack(14);month.Children.Add(Text("本月观看                       ‹  2026年11月  ›",14,true));month.Children.Add(Text("5.8 小时",26,true));month.Children.Add(Muted("已看 0 部电影 · 15 集剧 · 11 条播放片段",11));var bars=Row(8);for(var i=0;i<30;i++)bars.Children.Add(new Border{Width=14,Height=i<15?8+(i*29%100):3,VerticalAlignment=VerticalAlignment.Bottom,Background=Accent});month.Children.Add(bars);page.Children.Add(Panel(month));
        var recent=Stack(14);recent.Children.Add(Text("最近观看",14,true));foreach(var media in DemoCatalog.ResumeItems)recent.Children.Add(ViewingRow(media));page.Children.Add(Panel(recent));
        var counts=Row(16);if(model.BangumiEnabled)counts.Children.Add(Panel(Text("看过动画     421",16,true)));if(model.MoviePilotEnabled)counts.Children.Add(Panel(Text("资源订阅     6",16,true)));page.Children.Add(counts);
        var resume=Stack(14);resume.Children.Add(Text("继续观看",14,true));foreach(var media in DemoCatalog.ResumeItems)resume.Children.Add(ViewingRow(media));page.Children.Add(Panel(resume));
        if(model.MoviePilotEnabled){var downloads=Row(22);var subscriptions=Stack(14);subscriptions.Width=440;subscriptions.Children.Add(Text("订阅追更",14,true));subscriptions.Children.Add(Muted("6 部订阅                                        已知缺 52 集",11));foreach(var media in DemoCatalog.ResumeItems)subscriptions.Children.Add(ViewingRow(media));downloads.Children.Add(Panel(subscriptions));var tasks=Stack(12);tasks.Children.Add(Text("下载任务",14,true));tasks.Children.Add(Text("乱马½                                    0%",12));tasks.Children.Add(Muted("downloading · 0 B/s",11));downloads.Children.Add(Panel(tasks));page.Children.Add(Horizontal(downloads));}
        return pageLayout.Scroll(page);
    }
    private UIElement ViewingRow(DemoMedia media)
    {
        var row=Row(12);var poster=Image(media.PosterPath);poster.Width=46;poster.Height=64;row.Children.Add(poster);var labels=Stack(5);labels.Children.Add(Text(media.OriginalTitle,13,true));labels.Children.Add(Muted(media.EpisodeLabel??media.Subtitle,11));labels.Children.Add(new ProgressBar{Value=media.Progress,Width=120,Height=2});row.Children.Add(labels);var button=Button("",()=>open(media));button.Content=row;button.Background=new SolidColorBrush(Microsoft.UI.Colors.Transparent);button.BorderThickness=new Thickness(0);return button;
    }
    public UIElement Settings()=>new DemoSettings(model,pageLayout,navigate,themeChanged).Hub();
    public UIElement SettingsSubpage(string name)=>new DemoSettings(model,pageLayout,navigate,themeChanged).Subpage(name);

    private UIElement CreateEpisodePicker(DemoMedia media, bool expanded, Action? changed = null)
    {
        var episodes = media.Episodes ?? [];
        if (model.DemoMode && episodes.Length > 0 && episodes.Min(x => x.Number) == 1 && episodes.Max(x => x.Number) <= 12)
            episodes = Enumerable.Range(1, 12).Select(n => episodes.FirstOrDefault(x => x.Number == n)
                ?? new DemoEpisode(n, "未入库", "", false)).ToArray();
        if (episodes.Length == 0)
        {
            var empty = Stack(12); empty.Children.Add(SeasonSelector(media));
            if (model.EpisodesLoading) empty.Children.Add(new ProgressBar { IsIndeterminate = true });
            empty.Children.Add(Muted(model.EpisodeError ?? "本季暂无已入库分集"));
            if (model.EpisodeError is not null) empty.Children.Add(Button("重试加载分集", () => retrySeason?.Invoke())); return empty;
        }
        var block = Stack(10);
        if (model.EpisodesLoading) block.Children.Add(new ProgressBar { IsIndeterminate = true });
        if (model.EpisodeError is { } failure) { block.Children.Add(Muted(failure)); block.Children.Add(Button("重试加载分集", () => retrySeason?.Invoke())); }
        var controls = Row(8); controls.Children.Add(SeasonSelector(media));
        var orderLabel = model.EpisodesDescending ? "倒序" : "正序";
        var orderContent = Row(6);
        var orderText = Text(orderLabel, 13); orderText.TextWrapping = TextWrapping.NoWrap; orderText.VerticalAlignment = VerticalAlignment.Center;
        orderContent.Children.Add(orderText);
        orderContent.Children.Add(new FontIcon { Glyph = model.EpisodesDescending ? "\uE70D" : "\uE70E", FontSize = 10, VerticalAlignment = VerticalAlignment.Center });
        var orderButton = Button("", () => { model.EpisodesDescending = !model.EpisodesDescending; model.SaveHomeSections(); navigate(model.Route); });
        orderButton.Content = orderContent;
        orderButton.Height = orderButton.MinHeight = EpisodePicker.SelectorHeight;
        orderButton.Padding = new Thickness(12, 0, 12, 0);
        orderButton.VerticalAlignment = VerticalAlignment.Top;
        orderButton.HorizontalContentAlignment = HorizontalAlignment.Center;
        orderButton.VerticalContentAlignment = VerticalAlignment.Center;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(orderButton, "分集排序：" + orderLabel);
        ToolTipService.SetToolTip(orderButton, model.EpisodesDescending ? "切换为正序" : "切换为倒序");
        controls.Children.Add(orderButton);
        var ordered = (model.EpisodesDescending ? episodes.OrderByDescending(x => x.Number) : episodes.OrderBy(x => x.Number)).ToArray();
        var host = new ContentControl();
        var chunkIndex = Math.Max(0, Array.FindIndex(ordered, x => x.Number == model.SelectedEpisode)) / 30;
        void RenderChunk(int index)
        {
        host.Content = new EpisodePicker(controls, ordered.Skip(index * 30).Take(30).ToArray(), model.SelectedEpisode,
            episode => { model.SelectedEpisode = episode.Number; changed?.Invoke(); },
            episode => { model.SelectedEpisode = episode.Number; play(media); },
            (episode, watched) =>
            {
                if (!model.DemoMode && markEpisodeWatched is not null) { markEpisodeWatched(media, episode, watched); return; }
                model.SelectedMedia = model.SelectedMedia with { Episodes = model.SelectedMedia.Episodes?.Select(x =>
                    x.Number == episode.Number ? x with { Progress = watched ? 100 : 0, Played = watched } : x).ToArray() };
                navigate(model.Route);
            }, expanded);
        }
        if (ordered.Length > 30)
        {
            var ranges = ordered.Chunk(30).Select(x => $"{x[0].Number}–{x[^1].Number}").ToArray();
            var chunks = new ComboBox { Header = "分集范围", ItemsSource = ranges, SelectedIndex = chunkIndex, MinWidth = 140 };
            chunks.SelectionChanged += (_, _) => { if (host.Content is EpisodePicker previous) previous.DetachSeasonSelector(controls); RenderChunk(chunks.SelectedIndex); };
            block.Children.Add(chunks);
        }
        RenderChunk(chunkIndex); block.Children.Add(host); return block;
    }

    private UIElement SeasonSelector(DemoMedia media)
    {
        var seasons = media.Seasons is { Length: > 0 } choices ? choices : new[] { new DemoSeason("demo-season-1", "第 1 季", 1) };
        var combo = new ComboBox
        {
            ItemsSource = seasons, DisplayMemberPath = "Title",
            SelectedItem = seasons.FirstOrDefault(x => x.Id == media.SelectedSeasonId) ?? seasons[0], MinWidth = 110,
            Height = EpisodePicker.SelectorHeight, MinHeight = EpisodePicker.SelectorHeight,
            VerticalAlignment = VerticalAlignment.Top, VerticalContentAlignment = VerticalAlignment.Center
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(combo, "选择季");
        if (model.DemoMode || media.Seasons is not { Length: > 0 }) return combo;
        combo.SelectionChanged += (_, _) => { if (combo.SelectedItem is DemoSeason selected && selected.Id != media.SelectedSeasonId) navigate("season:" + selected.Id); };
        return combo;
    }

    private static Grid Header(string title)
    {
        var grid = new Grid { ColumnSpacing = 20 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var text = Stack(7);
        text.Children.Add(Text(title, 22, true));
        grid.Children.Add(text); return grid;
    }
    private static void AddHeaderAction(Grid header, FrameworkElement action)
    {
        Grid.SetColumn(action, 1); action.VerticalAlignment = VerticalAlignment.Center; header.Children.Add(action);
    }
    private UIElement Section(string title, string subtitle, IEnumerable<DemoMedia> items)
    {
        var section = Stack(14); var heading = Row(14);
        heading.Children.Add(Text(title, 22, true)); var caption = Muted(subtitle); caption.VerticalAlignment = VerticalAlignment.Center; heading.Children.Add(caption);
        section.Children.Add(heading);
        var cards = Row(18); foreach (var media in items) cards.Children.Add(MediaCard(media, open));
        section.Children.Add(Horizontal(cards)); return section;
    }
    private UIElement StillSection(string title, IEnumerable<DemoMedia> items, bool resume, bool showProgress = true)
    {
        var section = Stack(28); section.Children.Add(Text(title, 14, true));
        var cards = Row(22);
        foreach (var media in items) cards.Children.Add(StillCard(media, open, play, resume, showProgress));
        section.Children.Add(new HorizontalMediaRail(cards, title)); return section;
    }
    private Border Integration(string title, string subtitle, string description, string action)
    {
        var stack = Stack(10); stack.Children.Add(Text(title + "  /  " + subtitle, 20, true)); stack.Children.Add(Muted(description));
        stack.Children.Add(Button(action, () => navigate("settings"))); return Panel(stack);
    }
    private static Border SettingsRow(string title, string description, UIElement control)
    {
        var grid = new Grid { ColumnSpacing = 24 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var labels = Stack(5); labels.Children.Add(Text(title, 16, true)); labels.Children.Add(Muted(description));
        grid.Children.Add(labels); Grid.SetColumn((FrameworkElement)control, 1); ((FrameworkElement)control).VerticalAlignment = VerticalAlignment.Center;
        grid.Children.Add(control); return Panel(grid, new Thickness(22, 18, 22, 18));
    }
    private static ComboBox Combo(string[] options, string selected) => new() { ItemsSource = options, SelectedItem = selected, MinWidth = 120 };
    private static ScrollViewer Horizontal(UIElement content) => new() { Content = content, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Enabled, VerticalScrollMode = ScrollMode.Disabled };
}

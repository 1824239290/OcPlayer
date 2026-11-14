using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.ViewModels;
using Windows.UI;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Features;

internal sealed class DemoPages(DemoViewModel model, Action<string> navigate, Action<DemoMedia> open,
    Action<DemoMedia> play, Action<bool> themeChanged, Action<string> notify)
{
    public UIElement Home()
    {
        var page = Stack(48);
        page.Children.Add(StillSection("继续观看", DemoCatalog.ResumeItems, true));
        page.Children.Add(StillSection("最近添加", DemoCatalog.LatestItems, false));
        var librarySection = Stack(26);
        librarySection.Children.Add(Text("媒体库", 14, true));
        var libraries = Row(22);
        foreach (var (name, artwork) in new[] { ("电视剧", DemoCatalog.LatestItems[3].StillPath), ("电影", DemoCatalog.LatestItems[0].StillPath), ("合集", "") })
        {
            var content = new Grid { Width = 328, Height = 184.5, Background = new SolidColorBrush(Color.FromArgb(25, 255, 255, 255)) };
            if (artwork.Length > 0) content.Children.Add(Image(artwork));
            content.Children.Add(new Border { Background = new SolidColorBrush(Color.FromArgb(75, 0, 0, 0)) });
            var title = Text(name, 30, true); title.HorizontalAlignment = HorizontalAlignment.Center;
            title.VerticalAlignment = VerticalAlignment.Center; title.Foreground = new SolidColorBrush(Colors.White);
            content.Children.Add(title);
            var button = new Button { Content = new Border { Child = content, CornerRadius = new CornerRadius(10) }, Padding = new Thickness(0),
                Background = new SolidColorBrush(Colors.Transparent), BorderThickness = new Thickness(0) };
            button.Click += (_, _) => { model.Query = ""; model.Category = "全部"; model.LibraryName = name; navigate("library"); };
            var card = Stack(7); card.Children.Add(button); card.Children.Add(Text(name, 13, true)); card.Children.Add(Muted(name, 12));
            libraries.Children.Add(card);
        }
        librarySection.Children.Add(Horizontal(libraries)); page.Children.Add(librarySection);
        var scroll = Scroll(page); scroll.Padding = new Thickness(52, 20, 0, 36); return scroll;
    }

    public UIElement Library()
    {
        var layout = new Grid { Padding = new Thickness(36, 24, 36, 24), RowSpacing = 22 };
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var heading = Header(model.LibraryName);
        AddHeaderAction(heading, Button("← 首页", () => navigate("home")));
        layout.Children.Add(heading);
        var tools = new Grid { ColumnSpacing = 12 };
        tools.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var i = 0; i < 3; i++) tools.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var search = new TextBox { PlaceholderText = "搜索本库", Text = model.Query, MinWidth = 160 };
        tools.Children.Add(search);
        var category = Combo(["全部", "科幻", "动画"], model.Category);
        var sort = Combo(["推荐顺序", "名称", "年份"], model.Sort);
        var watched = Combo(["全部状态", "继续观看", "未观看"], model.WatchState);
        Grid.SetColumn(category, 1); Grid.SetColumn(sort, 2); Grid.SetColumn(watched, 3);
        tools.Children.Add(category); tools.Children.Add(sort); tools.Children.Add(watched);
        Grid.SetRow(tools, 1); layout.Children.Add(tools);
        var results = new Grid(); Grid.SetRow(results, 2); layout.Children.Add(results);
        // GridView owns scrolling so virtualization remains enabled.
        var grid = new GridView { SelectionMode = ListViewSelectionMode.None, HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var empty = Text("没有找到匹配的作品。试试其他关键词或筛选条件。", 18);
        empty.HorizontalAlignment = HorizontalAlignment.Center; empty.VerticalAlignment = VerticalAlignment.Center;
        results.Children.Add(grid); results.Children.Add(empty);
        void Refresh()
        {
            var items = model.FilteredMovies.ToArray();
            grid.Items.Clear();
            foreach (var media in items) grid.Items.Add(MediaCard(media, open, 186));
            empty.Visibility = items.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        }
        search.TextChanged += (_, _) => { model.Query = search.Text; Refresh(); };
        category.SelectionChanged += (_, _) => { model.Category = (string)category.SelectedItem; Refresh(); };
        sort.SelectionChanged += (_, _) => { model.Sort = (string)sort.SelectedItem; Refresh(); };
        watched.SelectionChanged += (_, _) => { model.WatchState = (string)watched.SelectedItem; Refresh(); };
        Refresh();
        return layout;
    }

    public UIElement Detail()
    {
        var media = model.SelectedMedia;
        var page = Stack(26);
        page.Children.Add(Button("← 返回媒体库", () => navigate("library")));
        page.Children.Add(Hero(media, true));
        var metadata = Row(8);
        foreach (var label in new[] { media.Year, media.Category, "示例 · 2 小时 49 分", "4K", "HDR" })
            metadata.Children.Add(Panel(Text(label, 12), new Thickness(12, 6, 12, 6)));
        page.Children.Add(Horizontal(metadata));
        var actions = Row();
        actions.Children.Add(Button(media.Progress > 0 ? "▶  继续观看" : "▶  播放", () => play(media), true));
        actions.Children.Add(Button("从头播放", () => play(media with { Progress = 0 })));
        actions.Children.Add(Button("＋ 加入待看", () => notify($"已将《{media.Title}》加入演示待看列表。")));
        page.Children.Add(actions);
        page.Children.Add(Text("剧情简介", 22, true));
        var overview = Text(media.Description, 16); overview.MaxWidth = 820; overview.LineHeight = 28;
        overview.HorizontalAlignment = HorizontalAlignment.Left; page.Children.Add(overview);
        var info = Stack(12); info.Children.Add(Text("媒体信息", 21, true));
        info.Children.Add(Muted("以下为界面示例字段，真实内容将由 Core 提供。"));
        foreach (var row in new[] { "视频     3840 × 2160  ·  HEVC  ·  HDR10", "音频     English  ·  DTS-HD MA 5.1", "字幕     简体中文  ·  English", "来源     家庭影院 / 电影" }) info.Children.Add(Text(row));
        page.Children.Add(Panel(info));
        return Scroll(page);
    }

    public UIElement Viewing()
    {
        var page = Stack(28);
        page.Children.Add(Header("观影空间"));
        var summary = Row(16);
        foreach (var (value, label) in new[] { ("12", "本月观看 · 示例"), ("28 h", "观影时长 · 示例"), ("5", "待看作品 · 示例") })
        {
            var content = Stack(8); content.Children.Add(Muted(label)); content.Children.Add(Text(value, 32, true));
            var panel = Panel(content); panel.MinWidth = 220; summary.Children.Add(panel);
        }
        page.Children.Add(Horizontal(summary));
        page.Children.Add(Section("观看记录", "", DemoCatalog.Movies.Take(3)));
        if (model.BangumiEnabled) page.Children.Add(Integration("Bangumi", "追番与每日放送", "登录后，在这里查看待看、在看和每周放送。", "连接 Bangumi"));
        if (model.MoviePilotEnabled) page.Children.Add(Integration("MoviePilot", "发现、订阅与下载", "你的下载任务与订阅更新，将在这里汇总。", "连接 MoviePilot"));
        return Scroll(page);
    }

    public UIElement Settings()
    {
        var page = Stack(24);
        page.MaxWidth = 960; page.HorizontalAlignment = HorizontalAlignment.Center;
        page.Children.Add(Header("设置"));
        page.Children.Add(Text("服务", 21, true));
        page.Children.Add(SettingsRow("媒体服务器", "管理 Jellyfin / Emby 与服务器地址", Button("连接服务器", () => notify("Demo 使用离线片库。下一阶段接入 Core 的服务器登录与会话。"))));
        var bgm = new ToggleSwitch { IsOn = model.BangumiEnabled }; bgm.Toggled += (_, _) => model.BangumiEnabled = bgm.IsOn;
        page.Children.Add(SettingsRow("Bangumi", "在观影空间显示追番入口", bgm));
        var mp = new ToggleSwitch { IsOn = model.MoviePilotEnabled }; mp.Toggled += (_, _) => model.MoviePilotEnabled = mp.IsOn;
        page.Children.Add(SettingsRow("MoviePilot", "在观影空间显示订阅与下载入口", mp));
        page.Children.Add(Text("播放与界面", 21, true));
        var theme = new ToggleSwitch { IsOn = model.DarkTheme, OnContent = "深色", OffContent = "浅色" };
        theme.Toggled += (_, _) => { model.DarkTheme = theme.IsOn; themeChanged(theme.IsOn); };
        page.Children.Add(SettingsRow("外观", "切换窗口的浅色与深色主题", theme));
        page.Children.Add(SettingsRow("默认播放速度", "演示设置 · 当前会话有效", Combo(["1.0×", "1.25×", "1.5×", "2.0×"], "1.0×")));
        page.Children.Add(Text("应用", 21, true));
        page.Children.Add(SettingsRow("OcPlayer Windows", "WinUI 3 前端 Demo · 本地示例数据", Text("0.1 PREVIEW", 12, true)));
        page.Children.Add(Muted("图片：TMDB 电影海报与背景。仅作为界面设计演示。播放器时钟为模拟状态，不执行真实解码。", 12));
        return Scroll(page);
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
    private Border Hero(DemoMedia media, bool detail)
    {
        var grid = new Grid { Height = detail ? 310 : 290, Background = new SolidColorBrush(Color.FromArgb(255, 25, 29, 38)) };
        grid.Children.Add(Image(media.Id == "interstellar" ? DemoCatalog.BackdropPath : media.PosterPath));
        grid.Children.Add(new Border { Background = new LinearGradientBrush { StartPoint = new global::Windows.Foundation.Point(0, .5), EndPoint = new global::Windows.Foundation.Point(1, .5),
            GradientStops = { new GradientStop { Color = Color.FromArgb(248, 12, 16, 24), Offset = 0 },
                new GradientStop { Color = Color.FromArgb(210, 12, 16, 24), Offset = .45 }, new GradientStop { Color = Color.FromArgb(10, 12, 16, 24), Offset = 1 } } } });
        var content = Stack(10); content.Margin = new Thickness(32); content.MaxWidth = 500;
        content.HorizontalAlignment = HorizontalAlignment.Left; content.VerticalAlignment = VerticalAlignment.Center;
        var badge = Text(detail ? media.OriginalTitle : "继续你的宇宙之旅", 12, true); badge.Foreground = Accent; badge.CharacterSpacing = 120;
        content.Children.Add(badge);
        content.Children.Add(new TextBlock { Text = media.Title, FontSize = 42, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Foreground = new SolidColorBrush(Colors.White) });
        content.Children.Add(new TextBlock { Text = media.Subtitle, Foreground = new SolidColorBrush(Color.FromArgb(255, 210, 210, 218)) });
        if (!detail)
        {
            content.Children.Add(new TextBlock { Text = "越过星辰与时间，寻找家的方向。", Foreground = new SolidColorBrush(Color.FromArgb(255, 210, 210, 218)), Margin = new Thickness(0, 4, 0, 6) });
            content.Children.Add(Button("▶  继续观看", () => play(media), true));
        }
        grid.Children.Add(content);
        return new Border { CornerRadius = new CornerRadius(16), Child = grid };
    }
    private UIElement Section(string title, string subtitle, IEnumerable<DemoMedia> items)
    {
        var section = Stack(14); var heading = Row(14);
        heading.Children.Add(Text(title, 22, true)); var caption = Muted(subtitle); caption.VerticalAlignment = VerticalAlignment.Center; heading.Children.Add(caption);
        section.Children.Add(heading);
        var cards = Row(18); foreach (var media in items) cards.Children.Add(MediaCard(media, open));
        section.Children.Add(Horizontal(cards)); return section;
    }
    private UIElement StillSection(string title, IEnumerable<DemoMedia> items, bool resume)
    {
        var section = Stack(28); section.Children.Add(Text(title, 14, true));
        var cards = Row(22);
        foreach (var media in items) cards.Children.Add(StillCard(media, open, play, resume));
        section.Children.Add(Horizontal(cards)); return section;
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

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics;

namespace OcPlayer.Windows.Features;

// A standalone comparison of stock WinUI controls. The working header is unchanged.
internal sealed class HeaderActionsPreviewWindow : Window
{
    private readonly Grid _root = new();
    private static readonly string[] Media = ["凡人修仙传", "JOJO的奇妙冒险", "冰之城墙", "乱马1/2", "水饺皇后"];

    public HeaderActionsPreviewWindow()
    {
        Title = "OcPlayer · WinUI 原生搜索与操作候选";
        AppWindow.ResizeClient(new SizeInt32(1000, 920));
        Content = _root;
        var light = Environment.GetCommandLineArgs().Contains("--preview-theme=light");
        SetTheme(!light);
        var page = new StackPanel { Spacing = 14, Margin = new Thickness(26, 20, 26, 20) };
        var heading = new Grid { ColumnSpacing = 18, Margin = new Thickness(0, 0, 0, 4) };
        heading.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var introduction = new StackPanel { Spacing = 5 };
        introduction.Children.Add(Text("WinUI 3 原生搜索与操作", 22, true));
        introduction.Children.Add(Text("对比首页的打开媒体、刷新和搜索。输入片名、点击按钮，查看原生交互。", 12, muted: true));
        heading.Children.Add(introduction);
        var theme = new ToggleSwitch { Header = "深色外观", IsOn = !light, OnContent = "", OffContent = "", VerticalAlignment = VerticalAlignment.Center };
        theme.Toggled += (_, _) => SetTheme(theme.IsOn);
        Grid.SetColumn(theme, 1);
        heading.Children.Add(theme);
        page.Children.Add(heading);

        AddSample(page, "A · 标准图标", "DropDownButton + Button + AutoSuggestBox · 系统默认外观，打开菜单自带下拉箭头。", (status, search) =>
            Actions(OpenDropDown(status, false), Refresh(status), search));
        AddSample(page, "B · 低强调图标", "SubtleButtonStyle · 按钮平时透明，悬停时出现底色；搜索框保持默认外观。", (status, search) =>
            Actions(OpenSubtle(status), Refresh(status, subtle: true), search));
        AddSample(page, "C · 图标与文字", "DropDownButton + Button · 直接显示「打开媒体」「刷新」，操作含义更清楚。", (status, search) =>
            Actions(OpenDropDown(status, true), Refresh(status, label: true), search));
        AddSample(page, "D · 圆角图标", "默认模板 + CornerRadius · 延续首页的圆润轮廓，悬停、焦点和搜索反馈仍由 WinUI 提供。", (status, search) =>
        {
            var open = OpenDropDown(status, false);
            var refresh = Refresh(status);
            open.CornerRadius = refresh.CornerRadius = search.CornerRadius = new CornerRadius(18);
            return Actions(open, refresh, search);
        });
        AddSample(page, "E · 分离式打开", "SplitButton · 左侧直接打开本地文件，右侧展开链接／服务器菜单。", (status, search) =>
        {
            var open = new SplitButton { Content = IconAndText(Symbol.OpenFile, "打开文件"), Flyout = OpenMenu(status) };
            Name(open, "打开本地文件或展开其他打开方式");
            open.Click += (_, _) => status.Text = "已触发：打开本地文件（样式演示）";
            return Actions(open, Refresh(status), search);
        });
        AddSample(page, "F · 原生命令栏", "CommandBar + AppBarButton · 图标旁显示标签，窗口变窄时可自动收进更多菜单。", (status, search) =>
        {
            var open = new AppBarButton { Icon = new SymbolIcon(Symbol.OpenFile), Label = "打开媒体", Flyout = OpenMenu(status) };
            Name(open, "打开媒体");
            var refresh = new AppBarButton { Icon = new SymbolIcon(Symbol.Refresh), Label = "刷新" };
            Name(refresh, "刷新");
            refresh.Click += (_, _) => status.Text = "已触发：刷新媒体库（样式演示）";
            var commands = new CommandBar
            {
                DefaultLabelPosition = CommandBarDefaultLabelPosition.Right,
                IsOpen = false,
                IsDynamicOverflowEnabled = true,
                OverflowButtonVisibility = CommandBarOverflowButtonVisibility.Auto,
                HorizontalAlignment = HorizontalAlignment.Stretch,
                VerticalAlignment = VerticalAlignment.Center
            };
            commands.PrimaryCommands.Add(open);
            commands.PrimaryCommands.Add(refresh);
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new() { Width = new GridLength(320) });
            row.Children.Add(commands);
            Grid.SetColumn(search, 1);
            row.Children.Add(search);
            return row;
        });
        page.Children.Add(Text("搜索框均为 AutoSuggestBox：原生搜索图标、清空按钮和建议列表。刷新用标准按钮承载系统图标；打开文件用原生下拉或分离按钮。", 12, muted: true, wrap: true));
        _root.Children.Add(new ScrollViewer { Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
    }

    private void SetTheme(bool dark)
    {
        _root.RequestedTheme = dark ? ElementTheme.Dark : ElementTheme.Light;
        _root.Background = new SolidColorBrush(dark
            ? global::Windows.UI.Color.FromArgb(255, 39, 41, 39)
            : global::Windows.UI.Color.FromArgb(255, 238, 237, 233));
    }

    private static void AddSample(StackPanel page, string title, string detail, Func<TextBlock, AutoSuggestBox, FrameworkElement> build)
    {
        var section = new StackPanel { Spacing = 5 };
        section.Children.Add(Text(title, 15, true));
        section.Children.Add(Text(detail, 12, muted: true, wrap: true));
        var status = Text("可试用：打开菜单 · 刷新 · 输入片名并按 Enter", 11, muted: true);
        AutomationProperties.SetLiveSetting(status, AutomationLiveSetting.Polite);
        var search = Search(status);
        var chrome = new Grid { Padding = new Thickness(14, 8, 14, 8), ColumnSpacing = 20, MinHeight = 52 };
        chrome.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        chrome.ColumnDefinitions.Add(new() { Width = new GridLength(620) });
        var account = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        account.Children.Add(Text("首页", 13, true));
        account.Children.Add(Text("jumusu · Jellyfin", 11, muted: true));
        chrome.Children.Add(account);
        var actions = build(status, search);
        Grid.SetColumn(actions, 1);
        chrome.Children.Add(actions);
        var surface = (Border)Microsoft.UI.Xaml.Markup.XamlReader.Load(
            "<Border xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Background=\"{ThemeResource CardBackgroundFillColorDefaultBrush}\" CornerRadius=\"8\" />");
        surface.Child = chrome;
        section.Children.Add(surface);
        section.Children.Add(status);
        page.Children.Add(section);
    }

    private static AutoSuggestBox Search(TextBlock status)
    {
        var search = new AutoSuggestBox
        {
            PlaceholderText = "搜索全部媒体库",
            QueryIcon = new SymbolIcon(Symbol.Find),
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            MaxSuggestionListHeight = 180
        };
        Name(search, "搜索全部媒体库");
        search.TextChanged += (sender, args) =>
        {
            if (args.Reason != AutoSuggestionBoxTextChangeReason.UserInput) return;
            var query = sender.Text.Trim();
            var matches = query.Length == 0 ? [] : Media.Where(name => name.Contains(query, StringComparison.OrdinalIgnoreCase)).ToArray();
            sender.ItemsSource = matches;
            status.Text = query.Length == 0 ? "可试用：打开菜单 · 刷新 · 输入片名并按 Enter" : $"示例建议：{matches.Length} 项匹配「{query}」";
        };
        search.SuggestionChosen += (sender, args) => sender.Text = (string)args.SelectedItem;
        search.QuerySubmitted += (sender, args) => status.Text = string.IsNullOrWhiteSpace(args.QueryText)
            ? "输入片名后按 Enter 或点击搜索图标"
            : $"已提交搜索：{args.QueryText}（样式演示）";
        return search;
    }

    private static Grid Actions(FrameworkElement open, FrameworkElement refresh, AutoSuggestBox search)
    {
        var row = new Grid { ColumnSpacing = 10, HorizontalAlignment = HorizontalAlignment.Right };
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new() { Width = new GridLength(320) });
        row.Children.Add(open);
        Grid.SetColumn(refresh, 1);
        row.Children.Add(refresh);
        Grid.SetColumn(search, 2);
        row.Children.Add(search);
        return row;
    }

    private static DropDownButton OpenDropDown(TextBlock status, bool label)
    {
        var button = new DropDownButton
        {
            Content = label ? IconAndText(Symbol.OpenFile, "打开媒体") : Icon(Symbol.OpenFile),
            Flyout = OpenMenu(status),
            VerticalAlignment = VerticalAlignment.Center
        };
        Name(button, "打开媒体");
        return button;
    }

    private static Button OpenSubtle(TextBlock status)
    {
        var button = new Button { Content = Icon(Symbol.OpenFile), Flyout = OpenMenu(status), Style = (Style)Application.Current.Resources["SubtleButtonStyle"], VerticalAlignment = VerticalAlignment.Center };
        Name(button, "打开媒体");
        return button;
    }

    private static Button Refresh(TextBlock status, bool subtle = false, bool label = false)
    {
        var button = new Button { Content = label ? IconAndText(Symbol.Refresh, "刷新") : Icon(Symbol.Refresh), VerticalAlignment = VerticalAlignment.Center };
        if (subtle) button.Style = (Style)Application.Current.Resources["SubtleButtonStyle"];
        Name(button, "刷新");
        button.Click += (_, _) => status.Text = "已触发：刷新媒体库（样式演示）";
        return button;
    }

    private static MenuFlyout OpenMenu(TextBlock status)
    {
        var menu = new MenuFlyout();
        void Add(string label, Symbol symbol)
        {
            var item = new MenuFlyoutItem { Text = label + "…", Icon = new SymbolIcon(symbol) };
            item.Click += (_, _) => status.Text = $"已触发：{label}（样式演示）";
            menu.Items.Add(item);
        }
        Add("打开本地文件", Symbol.OpenFile);
        Add("打开直连链接", Symbol.Link);
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("连接媒体服务器", Symbol.World);
        return menu;
    }

    private static FontIcon Icon(Symbol symbol) => new() { Glyph = char.ConvertFromUtf32((int)symbol), FontSize = 16 };
    private static StackPanel IconAndText(Symbol symbol, string label)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        content.Children.Add(Icon(symbol));
        content.Children.Add(Text(label, 14));
        return content;
    }

    private static void Name(DependencyObject element, string name)
    {
        AutomationProperties.SetName(element, name);
        ToolTipService.SetToolTip(element, name);
    }

    private static TextBlock Text(string text, double size, bool bold = false, bool muted = false, bool wrap = false) => new()
    {
        Text = text,
        FontSize = size,
        FontWeight = bold ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
        Opacity = muted ? .65 : 1,
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        VerticalAlignment = VerticalAlignment.Center
    };
}

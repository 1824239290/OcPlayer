using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;

namespace OcPlayer.Windows.Features;

// Compare built-in WinUI selectors without changing the working app's navigation.
// No control templates, drawing code, or custom pointer/keyboard handling.
internal sealed class NavigationPreviewWindow : Window
{
    private readonly Grid _root = new() { RequestedTheme = ElementTheme.Dark };
    private static readonly string[] Names = ["首页", "观影", "设置"];
    private static Uri AvatarUri => new(Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", "avatar.jpg"));

    public NavigationPreviewWindow()
    {
        Title = "OcPlayer · WinUI 原生导航候选";
        AppWindow.ResizeClient(new SizeInt32(820, 710));
        Content = _root;
        _root.Background = Brush(255, 39, 41, 39);
        var page = new StackPanel { Spacing = 24, Margin = new Thickness(28, 22, 28, 28) };
        var heading = new Grid();
        heading.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        heading.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        var introduction = new StackPanel { Spacing = 6 };
        introduction.Children.Add(new TextBlock { Text = "WinUI 3 原生导航", FontSize = 22, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        introduction.Children.Add(new TextBlock { Text = "点击各组图标，比较选中反馈与键盘操作。", Opacity = .7 });
        heading.Children.Add(introduction);
        var theme = new ToggleSwitch { Header = "深色外观", IsOn = true, OnContent = "", OffContent = "", VerticalAlignment = VerticalAlignment.Center };
        theme.Toggled += (_, _) =>
        {
            _root.RequestedTheme = theme.IsOn ? ElementTheme.Dark : ElementTheme.Light;
            _root.Background = theme.IsOn ? Brush(255, 39, 41, 39) : Brush(255, 238, 237, 233);
        };
        Grid.SetColumn(theme, 1); heading.Children.Add(theme); page.Children.Add(heading);

        var selectorStatus = Status();
        var selector = new SelectorBar { HorizontalAlignment = HorizontalAlignment.Left };
        foreach (var index in Enumerable.Range(0, 3))
        {
            var item = new SelectorBarItem { Icon = Icon(index) };
            AutomationProperties.SetName(item, Names[index]);
            ToolTipService.SetToolTip(item, Names[index]);
            selector.Items.Add(item);
        }
        selector.SelectedItem = selector.Items[0];
        selector.SelectionChanged += (_, _) => SetStatus(selectorStatus, selector.SelectedItem is { } item ? selector.Items.IndexOf(item) : 0);
        var pill = Surface("SubtleFillColorSecondaryBrush", 22);
        pill.Padding = new Thickness(3); pill.HorizontalAlignment = HorizontalAlignment.Left; pill.Child = selector;
        page.Children.Add(Sample("SelectorBar · 推荐", "原生单选导航；保留图标排列，外层只加圆角容器。", pill, selectorStatus));

        var navigationStatus = Status();
        var navigation = new NavigationView
        {
            PaneDisplayMode = NavigationViewPaneDisplayMode.Top,
            IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed,
            IsPaneToggleButtonVisible = false,
            IsSettingsVisible = false,
            IsTitleBarAutoPaddingEnabled = false,
            SelectionFollowsFocus = NavigationViewSelectionFollowsFocus.Enabled,
            HorizontalAlignment = HorizontalAlignment.Stretch
        };
        foreach (var index in Enumerable.Range(0, 3))
        {
            var item = new NavigationViewItem { Icon = Icon(index), Tag = index };
            AutomationProperties.SetName(item, Names[index]);
            ToolTipService.SetToolTip(item, Names[index]);
            navigation.MenuItems.Add(item);
        }
        navigation.SelectedItem = navigation.MenuItems[0];
        navigation.SelectionChanged += (_, args) => SetStatus(navigationStatus, args.SelectedItem is NavigationViewItem { Tag: int index } ? index : 0);
        page.Children.Add(Sample("NavigationView · 顶部模式", "原生应用导航；自带选中指示与窄窗口溢出菜单，占位较大。", navigation, navigationStatus));

        var tabsStatus = Status();
        var tabs = new TabView
        {
            TabWidthMode = TabViewWidthMode.Compact,
            IsAddTabButtonVisible = false,
            CanDragTabs = false,
            CanReorderTabs = false,
            HorizontalAlignment = HorizontalAlignment.Left
        };
        foreach (var index in Enumerable.Range(0, 3))
            tabs.TabItems.Add(new TabViewItem { Header = Names[index], IsClosable = false,
                IconSource = index == 0 ? new BitmapIconSource { UriSource = AvatarUri, ShowAsMonochrome = false }
                    : new SymbolIconSource { Symbol = index == 1 ? Symbol.Video : Symbol.Setting } });
        tabs.SelectedIndex = 0;
        tabs.SelectionChanged += (_, _) => SetStatus(tabsStatus, tabs.SelectedIndex);
        page.Children.Add(Sample("TabView · 紧凑模式", "原生标签页；当前项显示文字，其余收成图标，形状是标签页。", tabs, tabsStatus));
        page.Children.Add(new TextBlock
        {
            Text = "以上使用系统控件默认模板。这里只比较候选，主窗口的媒体库和服务器连接继续沿用现有实现。",
            Opacity = .65, TextWrapping = TextWrapping.Wrap, FontSize = 12
        });
        _root.Children.Add(new ScrollViewer { Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
    }

    private static UIElement Sample(string title, string detail, UIElement control, TextBlock status)
    {
        var section = new StackPanel { Spacing = 8 };
        section.Children.Add(new TextBlock { Text = title, FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        section.Children.Add(new TextBlock { Text = detail, Opacity = .7, FontSize = 12, TextWrapping = TextWrapping.Wrap });
        var chrome = new Grid { Padding = new Thickness(14, 10, 14, 10), MinHeight = 74, ColumnSpacing = 16 };
        chrome.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
        chrome.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        if (control is FrameworkElement element) element.VerticalAlignment = VerticalAlignment.Center;
        chrome.Children.Add(control);
        var account = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        account.Children.Add(status);
        account.Children.Add(new TextBlock { Text = "jumusu · Jellyfin", FontSize = 11, Opacity = .6 });
        Grid.SetColumn(account, 1); chrome.Children.Add(account);
        var surface = Surface("CardBackgroundFillColorDefaultBrush", 10); surface.Child = chrome;
        section.Children.Add(surface);
        return section;
    }

    private static TextBlock Status() => new() { Text = "首页", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
    private static void SetStatus(TextBlock status, int index) => status.Text = Names[Math.Clamp(index, 0, Names.Length - 1)];
    private static IconElement Icon(int index) => index == 0
        ? new ImageIcon { Source = new BitmapImage(AvatarUri) }
        : new SymbolIcon { Symbol = index == 1 ? Symbol.Video : Symbol.Setting };
    private static SolidColorBrush Brush(byte alpha, byte red, byte green, byte blue) => new(global::Windows.UI.Color.FromArgb(alpha, red, green, blue));
    private static Border Surface(string themeBrush, int radius) => (Border)Microsoft.UI.Xaml.Markup.XamlReader.Load(
        $"<Border xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Background=\"{{ThemeResource {themeBrush}}}\" CornerRadius=\"{radius}\" />");
}

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics;

namespace OcPlayer.Windows.Features;

// Stock controls for choosing detail-page presentation; actions stay in this preview.
internal sealed class DetailControlsPreviewWindow : Window
{
    public DetailControlsPreviewWindow()
    {
        Title = "OcPlayer · 详情页 WinUI 3 控件候选";
        AppWindow.ResizeClient(new SizeInt32(1060, 840));
        var root = new Grid { RequestedTheme = ElementTheme.Dark };
        Content = root;
        root.Children.Add(new Image
        {
            Source = new BitmapImage(new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Demo", "mac-6-backdrop.jpg"))),
            Stretch = Stretch.UniformToFill
        });
        root.Children.Add(new Border { Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(225, 25, 27, 26)) });
        var page = new StackPanel { Spacing = 20, Margin = new Thickness(28, 22, 28, 26) };
        page.Children.Add(Text("详情页 · WinUI 3 原生控件候选", 24, true));
        page.Children.Add(Text("分别挑选类型、播放和观看状态的样式。按钮可点击，勾选可切换，下拉菜单可展开。", 13, muted: true));

        var genres = Section(page, "类型标签", "WinUI 3 没有通用 Chip 控件。仅展示类型用文字；需要点击筛选时用链接或按钮。");
        Sample(genres, 0, "T1 · TextBlock", "纯信息展示，无点击或选中状态。", status =>
        {
            status.Text = "动画 · 喜剧";
            return Text("动画   ·   喜剧", 14);
        });
        Sample(genres, 1, "T2 · HyperlinkButton", "原生链接，适合点击类型后筛选作品。", status =>
        {
            var row = Row();
            foreach (var genre in new[] { "动画", "喜剧" })
            {
                var link = new HyperlinkButton { Content = genre };
                link.Click += (_, _) => status.Text = $"预览：按「{genre}」筛选";
                row.Children.Add(link);
            }
            return row;
        });
        Sample(genres, 2, "T3 · 紧凑 Button", "默认按钮模板，带边框和悬停反馈。", status =>
        {
            var row = Row();
            foreach (var genre in new[] { "动画", "喜剧" })
            {
                var button = new Button { Content = genre, Padding = new Thickness(12, 4, 12, 4) };
                button.Click += (_, _) => status.Text = $"预览：按「{genre}」筛选";
                row.Children.Add(button);
            }
            return row;
        });

        var playback = Section(page, "播放操作", "标准按钮可放播放图标；强调色用于主要操作；分离按钮可承载额外播放方式。");
        Sample(playback, 0, "P1 · Button", "系统默认按钮，低强调。", status =>
        {
            var button = PlayButton();
            button.Click += (_, _) => status.Text = "预览：播放当前选中的集";
            return button;
        });
        Sample(playback, 1, "P2 · 强调色 Button", "AccentButtonStyle，突出主要操作。", status =>
        {
            var button = PlayButton();
            button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
            button.Click += (_, _) => status.Text = "预览：播放当前选中的集";
            return button;
        });
        Sample(playback, 2, "P3 · SplitButton", "主区域播放，右侧打开播放方式菜单。", status =>
        {
            var menu = new MenuFlyout();
            foreach (var option in new[] { "从头播放", "选择播放版本…" })
            {
                var item = new MenuFlyoutItem { Text = option };
                item.Click += (_, _) => status.Text = $"预览：{option}";
                menu.Items.Add(item);
            }
            var button = new SplitButton { Content = PlayContent(), Width = 220, Flyout = menu };
            button.Click += (_, _) => status.Text = "预览：播放当前选中的集";
            return button;
        });

        var watching = Section(page, "已观看状态", "二态按钮和勾选框可直接切换；下拉按钮提供明确的「标记已观看／未观看」选项。");
        Sample(watching, 0, "W1 · ToggleButton", "原生按下状态，适合紧凑操作区。", status =>
        {
            var button = new Microsoft.UI.Xaml.Controls.Primitives.ToggleButton { Content = "已观看" };
            status.Text = "当前：未观看";
            button.Checked += (_, _) => status.Text = "当前：已观看";
            button.Unchecked += (_, _) => status.Text = "当前：未观看";
            return button;
        });
        Sample(watching, 1, "W2 · CheckBox", "勾选状态清楚，文字直接说明含义。", status =>
        {
            var box = new CheckBox { Content = "已观看", IsThreeState = false };
            status.Text = "当前：未观看";
            box.Checked += (_, _) => status.Text = "当前：已观看";
            box.Unchecked += (_, _) => status.Text = "当前：未观看";
            return box;
        });
        Sample(watching, 2, "W3 · DropDownButton", "按钮显示当前状态，菜单修改状态。", status =>
        {
            var menu = new MenuFlyout();
            var button = new DropDownButton { Content = "未观看", Flyout = menu };
            status.Text = "当前：未观看";
            foreach (var watched in new[] { true, false })
            {
                var item = new MenuFlyoutItem { Text = watched ? "标记为已观看" : "标记为未观看" };
                item.Click += (_, _) =>
                {
                    button.Content = watched ? "已观看" : "未观看";
                    status.Text = $"当前：{button.Content}";
                };
                menu.Items.Add(item);
            }
            return button;
        });
        page.Children.Add(Text("可混合选择，例如 T1 + P2 + W1。这里的操作仅演示组件反馈。", 13, muted: true));
        root.Children.Add(new ScrollViewer
        {
            Content = page, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled
        });
    }

    private static Grid Section(StackPanel page, string title, string description)
    {
        var section = new StackPanel { Spacing = 9 };
        section.Children.Add(Text(title, 18, true));
        section.Children.Add(Text(description, 12, muted: true));
        var grid = new Grid { ColumnSpacing = 12 };
        for (var i = 0; i < 3; i++) grid.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
        section.Children.Add(grid);
        page.Children.Add(section);
        return grid;
    }

    private static void Sample(Grid grid, int column, string title, string description, Func<TextBlock, FrameworkElement> build)
    {
        var panel = new StackPanel { Spacing = 9 };
        panel.Children.Add(Text(title, 14, true));
        panel.Children.Add(Text(description, 12, muted: true));
        var status = Text("可点击查看原生反馈", 11, muted: true);
        var control = build(status);
        AutomationProperties.SetName(control, title);
        panel.Children.Add(new Grid { Height = 46, Children = { control } });
        control.HorizontalAlignment = HorizontalAlignment.Left;
        control.VerticalAlignment = VerticalAlignment.Center;
        panel.Children.Add(status);
        var card = new Border
        {
            Child = panel, Padding = new Thickness(16, 12, 16, 12), CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(global::Windows.UI.Color.FromArgb(155, 36, 38, 37)),
            BorderBrush = new SolidColorBrush(global::Windows.UI.Color.FromArgb(50, 255, 255, 255)), BorderThickness = new Thickness(1)
        };
        Grid.SetColumn(card, column);
        grid.Children.Add(card);
    }

    private static Button PlayButton() => new() { Content = PlayContent(), Width = 220 };
    private static StackPanel PlayContent()
    {
        var content = Row();
        content.Children.Add(new SymbolIcon(Symbol.Play));
        content.Children.Add(Text("播放", 14));
        return content;
    }
    private static StackPanel Row() => new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private static TextBlock Text(string text, double size, bool bold = false, bool muted = false) => new()
    {
        Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap,
        FontWeight = bold ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
        Opacity = muted ? .7 : 1, VerticalAlignment = VerticalAlignment.Center
    };
}

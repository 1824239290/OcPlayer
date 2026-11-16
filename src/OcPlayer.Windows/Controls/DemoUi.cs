using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using OcPlayer.Windows.Preview;
using Windows.UI;

namespace OcPlayer.Windows.Controls;

internal static class DemoUi
{
    public static Brush Accent => new SolidColorBrush(Color.FromArgb(255, 236, 166, 107));
    public static Brush Resource(string key) => (Brush)Application.Current.Resources[key];
    public static TextBlock Text(string text, double size = 14, bool strong = false) => new()
    {
        Text = text, FontSize = size, FontWeight = strong ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
        TextWrapping = TextWrapping.Wrap
    };
    public static TextBlock Muted(string text, double size = 13)
    {
        var block = Text(text, size);
        block.Foreground = Resource("TextFillColorSecondaryBrush");
        return block;
    }
    public static Button Button(string label, Action action, bool primary = false)
    {
        var button = new Button { Content = label, Padding = new Thickness(18, 10, 18, 10), CornerRadius = new CornerRadius(8) };
        if (primary) { button.Background = Accent; button.Foreground = new SolidColorBrush(Colors.Black); }
        button.Click += (_, _) => action();
        return button;
    }
    public static Image Image(string path, Stretch stretch = Stretch.UniformToFill)
    {
        var image = new Image { Stretch = stretch };
        if (string.IsNullOrEmpty(path)) return image;
        if (!Uri.TryCreate(path, UriKind.Absolute, out var uri)) return image;
        if (uri.Scheme is not ("http" or "https")) { image.Source = new BitmapImage(uri); return image; }
        CancellationTokenSource? load = null;
        image.Loaded += async (_, _) =>
        {
            load?.Cancel(); load?.Dispose(); load = new CancellationTokenSource(); var token = load.Token;
            try { var cached = await Services.ImageDiskCache.Resolve(path, token); if (!token.IsCancellationRequested) image.Source = new BitmapImage(new Uri(cached)); }
            catch (OperationCanceledException) { }
            catch (Exception) { if (!token.IsCancellationRequested) image.Source = new BitmapImage(uri); }
        };
        image.Unloaded += (_, _) => load?.Cancel(); return image;
    }
    public static StackPanel Stack(double spacing = 12) => new() { Spacing = spacing };
    public static StackPanel Row(double spacing = 12) => new() { Orientation = Orientation.Horizontal, Spacing = spacing };
    public static Border Panel(UIElement child, Thickness? padding = null)
    {
        var border = new Border { Child = child, Padding = padding ?? new Thickness(24), CornerRadius = new CornerRadius(16), BorderThickness = new Thickness(1) };
        border.Background = Resource("CardBackgroundFillColorDefaultBrush");
        border.BorderBrush = Resource("CardStrokeColorDefaultBrush");
        return border;
    }
    public static Border Poster(DemoMedia media, double height = 238)
    {
        var grid = new Grid { Height = height, Background = new SolidColorBrush(Color.FromArgb(25,128,128,128)) };
        grid.Children.Add(Image(media.PosterPath));
        return new Border { CornerRadius = new CornerRadius(10), Child = grid };
    }
    public static Button MediaCard(DemoMedia media, Action<DemoMedia> open, double width = 174)
    {
        var stack = Stack(8);
        stack.Children.Add(Poster(media, width * 1.5));
        var title = Text(media.Title, 15, true);
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        title.MaxLines = 1;
        stack.Children.Add(title);
        stack.Children.Add(Muted(media.Subtitle, 12));
        var button = new Button { Content = stack, Width = width, Padding = new Thickness(0), Background = new SolidColorBrush(Colors.Transparent),
            BorderThickness = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(button, $"{media.Title}，{media.Subtitle}，查看详情");
        button.Click += (_, _) => open(media);
        return button;
    }
    public static UIElement StillCard(DemoMedia media, Action<DemoMedia> open, Action<DemoMedia> play, bool resume, bool showProgress = true)
    {
        var width = resume ? 328d : 230d;
        var stack = Stack(7);
        var image = new Grid { Width = width, Height = width * 9 / 16 };
        image.Children.Add(Image(media.StillPath));
        var artwork = new Button { Content = new Border { Child = image, CornerRadius = new CornerRadius(10) },
            Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = new SolidColorBrush(Colors.Transparent),
            HorizontalContentAlignment = HorizontalAlignment.Stretch };
        AutomationProperties.SetName(artwork, $"{media.Title}，查看详情");
        artwork.Click += (_, _) => open(media);
        stack.Children.Add(artwork);
        if (resume && showProgress)
        {
            var progress = new Grid { Height = 3, Width = width };
            progress.Children.Add(new Border { Height = 3, Width = Math.Max(4, width * media.Progress / 100), HorizontalAlignment = HorizontalAlignment.Left,
                Background = new SolidColorBrush(Colors.LightGray), CornerRadius = new CornerRadius(1.5) });
            stack.Children.Add(progress);
        }
        var displayTitle = media.Kind == "episode" && !string.IsNullOrWhiteSpace(media.SeriesTitle) ? media.SeriesTitle + " · " + media.Title : media.Title;
        var title = Text(displayTitle, 13, true); title.MaxLines = 1; title.TextTrimming = TextTrimming.CharacterEllipsis;
        stack.Children.Add(title);
        var remaining = media.RemainingMinutes is > 0 and var minutes ? "还剩 " + (minutes >= 60 ? $"{minutes / 60}小时{minutes % 60}分" : $"{minutes}分") : null;
        var subtitle = Muted(resume ? string.Join(" · ", new[] { media.EpisodeLabel, remaining }.Where(x => !string.IsNullOrWhiteSpace(x))) is { Length: > 0 } summary ? summary : media.SeriesTitle ?? media.Category
            : string.Join(" · ", new[] { media.Year, media.Category.Split(" / ")[0] }.Where(x => !string.IsNullOrEmpty(x))), 12);
        subtitle.Opacity = .75; stack.Children.Add(subtitle);
        var menu = new MenuFlyout();
        var watch = new MenuFlyoutItem { Text = resume ? "继续观看" : "播放" }; watch.Click += (_, _) => play(media); menu.Items.Add(watch);
        artwork.ContextFlyout = menu;
        stack.Width = width;
        return stack;
    }
    public static ScrollViewer Scroll(UIElement content, Thickness? padding = null) => new()
    {
        Content = new Grid { Children = { content }, Padding = padding ?? new Thickness(36, 24, 36, 32) },
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Padding = new Thickness(0)
    };
}

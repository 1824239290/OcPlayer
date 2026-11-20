using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Services;
using Windows.UI;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Controls;

internal sealed class LibraryCard : Button
{
    private const double CoverWidth = 328;
    private const double CoverHeight = CoverWidth * 9 / 16;

    public LibraryCard(MediaLibrary library, Action onOpen)
    {
        Width = CoverWidth;
        Padding = new Thickness(0);
        Background = new SolidColorBrush(Colors.Transparent);
        BorderThickness = new Thickness(0);
        HorizontalContentAlignment = HorizontalAlignment.Stretch;

        var content = Stack(0);
        content.Children.Add(Cover(library));
        var labels = Stack(3);
        labels.Margin = new Thickness(0, 10, 0, 0);
        var title = Text(library.Name, 13, true);
        title.MaxLines = 1;
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        var subtitle = Muted(library.DisplayType, 12);
        subtitle.MaxLines = 1;
        subtitle.TextTrimming = TextTrimming.CharacterEllipsis;
        labels.Children.Add(title);
        labels.Children.Add(subtitle);
        content.Children.Add(labels);
        Content = content;
        AutomationProperties.SetName(this, $"打开媒体库 {library.Name}");
        Click += (_, _) => onOpen();
    }

    private static UIElement Cover(MediaLibrary library)
    {
        var grid = new Grid { Width = CoverWidth, Height = CoverHeight,
            Background = new SolidColorBrush(Color.FromArgb(25, 128, 128, 128)) };
        var posters = (library.CoverPosters ?? []).Where(x => x.Length > 0).Take(4).ToArray();
        if (library.Artwork.Length > 0) AddImage(library.Artwork, 0, 0, CoverWidth, CoverHeight);
        else if (posters.Length > 0)
        {
            if (posters.Length >= 2)
            {
                grid.ColumnDefinitions.Add(new ColumnDefinition());
                grid.ColumnDefinitions.Add(new ColumnDefinition());
            }
            if (posters.Length >= 3)
            {
                grid.RowDefinitions.Add(new RowDefinition());
                grid.RowDefinitions.Add(new RowDefinition());
            }
            for (var index = 0; index < posters.Length; index++)
            {
                var span = posters.Length == 3 && index == 2 ? 2 : 1;
                var cell = AddImage(posters[index], index / 2, index % 2,
                    posters.Length == 1 || span == 2 ? CoverWidth : CoverWidth / 2,
                    posters.Length < 3 ? CoverHeight : CoverHeight / 2);
                Grid.SetColumnSpan(cell, span);
            }
        }
        else grid.Children.Add(new FontIcon { Glyph = library.CollectionType.Equals("boxsets", StringComparison.OrdinalIgnoreCase) ? "\uE7FD" : "\uEB9F",
            FontSize = 32, Style = (Style)Application.Current.Resources["MutedIconStyle"] });

        return new Border { Child = grid, CornerRadius = new CornerRadius(10) };

        FrameworkElement AddImage(string source, int row, int column, double width, double height)
        {
            // Explicit cell bounds keep UniformToFill cropped to each tile.
            var image = Image(source);
            image.Width = width;
            image.Height = height;
            Grid.SetRow(image, row);
            Grid.SetColumn(image, column);
            grid.Children.Add(image);
            return image;
        }
    }
}

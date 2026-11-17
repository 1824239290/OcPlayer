using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using OcPlayer.Windows.Preview;

namespace OcPlayer.Windows.Controls;

internal sealed class MediaLibraryGrid : GridView
{
    private const double PreferredItemWidth = 200;
    private const double HorizontalGap = 24;
    private const double VerticalGap = 24;
    private const double LabelHeight = 50;

    public MediaLibraryGrid(IReadOnlyList<DemoMedia> media, Action<DemoMedia> open)
    {
        SelectionMode = ListViewSelectionMode.None;
        IsItemClickEnabled = true;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        ItemsPanel = (ItemsPanelTemplate)XamlReader.Load("""
            <ItemsPanelTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
                <ItemsWrapGrid Orientation="Horizontal" />
            </ItemsPanelTemplate>
            """);
        ItemContainerStyle = new Style(typeof(GridViewItem))
        {
            Setters =
            {
                new Setter(Control.PaddingProperty, new Thickness(12, 8, 12, 16)),
                new Setter(FrameworkElement.MarginProperty, new Thickness(0)),
                new Setter(Control.HorizontalContentAlignmentProperty, HorizontalAlignment.Stretch),
                new Setter(Control.VerticalContentAlignmentProperty, VerticalAlignment.Stretch),
                new Setter(Control.CornerRadiusProperty, new CornerRadius(8))
            }
        };
        ItemTemplate = (DataTemplate)XamlReader.Load("""
            <DataTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="30" />
                        <RowDefinition Height="20" />
                    </Grid.RowDefinitions>
                    <ToolTipService.ToolTip>
                        <ToolTip>
                            <StackPanel Spacing="4">
                                <TextBlock Text="{Binding Title}" FontWeight="SemiBold" />
                                <TextBlock Text="{Binding Subtitle}" />
                            </StackPanel>
                        </ToolTip>
                    </ToolTipService.ToolTip>
                    <Border CornerRadius="8" Background="{ThemeResource CardBackgroundFillColorDefaultBrush}">
                        <Image Tag="{Binding PosterPath}" Stretch="UniformToFill" />
                    </Border>
                    <TextBlock Grid.Row="1" Text="{Binding Title}" Margin="0,10,0,0"
                               FontSize="14" FontWeight="SemiBold" TextWrapping="NoWrap"
                               MaxLines="1" TextTrimming="CharacterEllipsis" />
                    <TextBlock Grid.Row="2" Text="{Binding Subtitle}" Margin="0,4,0,0"
                               FontSize="12" Foreground="{ThemeResource TextFillColorSecondaryBrush}"
                               TextWrapping="NoWrap" MaxLines="1" TextTrimming="CharacterEllipsis" />
                </Grid>
            </DataTemplate>
            """);
        ItemsSource = media;
        ScrollViewer.SetHorizontalScrollBarVisibility(this, ScrollBarVisibility.Disabled);
        ScrollViewer.SetVerticalScrollBarVisibility(this, ScrollBarVisibility.Auto);
        ItemClick += (_, args) => open((DemoMedia)args.ClickedItem);
        ContainerContentChanging += PopulateImage;
        Loaded += (_, _) => UpdateItemSize();
        SizeChanged += (_, _) => UpdateItemSize();
        RegisterPropertyChangedCallback(PaddingProperty, (_, _) => UpdateItemSize());
    }
    private void PopulateImage(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.Item is not DemoMedia item) return;
        AutomationProperties.SetName(args.ItemContainer, $"{item.Title}，{item.Subtitle}，查看详情");
        if (args.Phase == 0) { args.RegisterUpdateCallback(1, PopulateImage); return; }
        var image = FindImage(args.ItemContainer); if (image is null) return;
        image.Source = null; var identity = new object(); image.Tag = identity;
        _ = Load();
        async Task Load()
        {
            try
            {
                var source = item;
                if (item.Kind == "boxSet" && !App.DemoMode && App.Core is { Server: { } server } core)
                    source = await core.Tmdb.Enrich(item, server.Profile.Id, CancellationToken.None);
                var path = await Services.ImageDiskCache.Resolve(source.PosterPath);
                if (ReferenceEquals(image.Tag, identity) && path.Length > 0) image.Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(path));
            }
            catch (Exception) { if (ReferenceEquals(image.Tag, identity) && item.PosterPath.Length > 0) image.Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(item.PosterPath)); }
        }
    }
    private static Image? FindImage(DependencyObject parent)
    {
        if (parent is Image image) return image;
        for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
            if (FindImage(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, i)) is { } child) return child;
        return null;
    }

    private void UpdateItemSize()
    {
        if (ItemsPanelRoot is not ItemsWrapGrid panel) return;
        // Reserve the native scrollbar gutter so it never displaces the last column.
        var availableWidth = ActualWidth - Padding.Left - Padding.Right - 16;
        if (availableWidth <= HorizontalGap) return;
        var columns = Math.Max(1, (int)(availableWidth / PreferredItemWidth));
        var itemWidth = availableWidth / columns;
        panel.ItemWidth = itemWidth;
        panel.ItemHeight = (itemWidth - HorizontalGap) * 1.5 + LabelHeight + VerticalGap;
    }
}

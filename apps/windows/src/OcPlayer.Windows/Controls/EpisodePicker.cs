using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using OcPlayer.Windows.Preview;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Controls;

// Native single-selection lists share one selection without rebuilding the page.
internal sealed class EpisodePicker : StackPanel
{
    internal const double SelectorHeight = 36;
    private readonly ListView _numbers = CreateList("集号");
    private readonly ListView _cards = CreateList("分集");
    private readonly StackPanel _captions = Row(0);
    private readonly HorizontalMediaRail _numberRail;
    private readonly HorizontalMediaRail _cardRail;
    private bool _selecting;

    public EpisodePicker(UIElement seasonSelector, DemoEpisode[] episodes, int selectedNumber,
        Action<DemoEpisode> select, Action<DemoEpisode> play, Action<DemoEpisode, bool> markWatched, bool expanded = false)
    {
        Spacing = expanded ? 16 : 10;
        var header = new Grid { ColumnSpacing = 6, Height = SelectorHeight };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        header.Children.Add(seasonSelector);
        _numbers.Height = SelectorHeight;
        _numbers.MinHeight = SelectorHeight;
        _numbers.VerticalAlignment = VerticalAlignment.Top;
        _numberRail = new HorizontalMediaRail(_numbers, "集号", 0);
        _numberRail.Height = SelectorHeight;
        _numberRail.VerticalAlignment = VerticalAlignment.Top;
        Grid.SetColumn(_numberRail, 1);
        header.Children.Add(_numberRail);
        Children.Add(header);
        var cardRows = new Grid { RowSpacing = expanded ? 7 : 4 };
        cardRows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        cardRows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        cardRows.Children.Add(_cards);
        Grid.SetRow(_captions, 1);
        cardRows.Children.Add(_captions);
        _cardRail = new HorizontalMediaRail(cardRows, "分集", expanded ? 48 : 24);
        Children.Add(_cardRail);

        var width = expanded ? 210d : 160d;
        foreach (var episode in episodes)
        {
            var label = Text(episode.Number.ToString(), 13);
            label.TextWrapping = TextWrapping.NoWrap;
            label.TextAlignment = TextAlignment.Center;
            label.HorizontalAlignment = HorizontalAlignment.Center;
            label.VerticalAlignment = VerticalAlignment.Center;
            if (episode.IsPlayed) label.Foreground = Resource("TextFillColorSecondaryBrush");
            var numberWidth = Math.Max(32, episode.Number.ToString().Length * 8 + 20);
            var numberContent = new Grid { MinWidth = numberWidth, Height = SelectorHeight };
            numberContent.Children.Add(new Border
            {
                Child = label, Padding = new Thickness(6, 0, 6, 0), CornerRadius = new CornerRadius(6),
                Background = Resource("CardBackgroundFillColorDefaultBrush"),
                BorderBrush = Resource("CardStrokeColorDefaultBrush"), BorderThickness = new Thickness(1)
            });
            if (episode.IsPlayed)
            {
                numberContent.Children.Add(new FontIcon
                {
                    Glyph = "\uE73E", FontSize = 8, Foreground = Resource("TextFillColorSecondaryBrush"),
                    HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
                    Margin = new Thickness(0, 3, 3, 0), IsHitTestVisible = false
                });
            }
            var number = new ListViewItem
            {
                Content = numberContent, Tag = episode,
                MinWidth = 32, MinHeight = SelectorHeight, Height = SelectorHeight, Padding = new Thickness(0),
                BorderThickness = new Thickness(0),
                Margin = new Thickness(0, 0, 6, 0), CornerRadius = new CornerRadius(6),
                IsEnabled = episode.Available, HorizontalContentAlignment = HorizontalAlignment.Center,
                VerticalContentAlignment = VerticalAlignment.Stretch
            };
            AutomationProperties.SetName(number, $"第 {episode.Number} 集，{episode.WatchStatus}");
            ToolTipService.SetToolTip(number, $"第 {episode.Number} 集 · {episode.WatchStatus}");
            var watchedMenu = new MenuFlyout();
            var watchedAction = new MenuFlyoutItem
            {
                Text = episode.IsPlayed ? "标记为未观看" : "标记为已观看",
                Icon = new FontIcon { Glyph = episode.IsPlayed ? "\uE711" : "\uE73E" },
                IsEnabled = episode.Available
            };
            watchedAction.Click += (_, _) => markWatched(episode, !episode.IsPlayed);
            watchedMenu.Items.Add(watchedAction);
            number.ContextFlyout = watchedMenu;
            _numbers.Items.Add(number);

            var frame = new Grid { Height = width * 9 / 16, Background = Resource("CardBackgroundFillColorDefaultBrush") };
            if (episode.Artwork.Length > 0)
            {
                var image = Image(DemoMedia.AssetPath(episode.Artwork));
                image.Opacity = episode.IsPlayed ? .55 : 1;
                frame.Children.Add(image);
            }
            if (episode.IsPlayed)
            {
                var watched = new Border
                {
                    Child = new FontIcon { Glyph = "\uE73E", FontSize = 12, Foreground = Resource("TextFillColorPrimaryBrush") },
                    Padding = new Thickness(5), CornerRadius = new CornerRadius(5), Margin = new Thickness(6),
                    HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
                    Background = Resource("SolidBackgroundFillColorBaseBrush")
                };
                frame.Children.Add(watched);
            }
            else if (episode.Progress > 0) frame.Children.Add(Progress(episode.Progress, width));
            var card = new ListViewItem
            {
                Content = new Border { Child = frame, CornerRadius = new CornerRadius(8) },
                Tag = episode, Width = width + 8, Padding = new Thickness(4),
                Margin = new Thickness(0, 0, 6, 0), CornerRadius = new CornerRadius(10),
                IsEnabled = episode.Available, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Foreground = Resource(episode.IsPlayed ? "TextFillColorSecondaryBrush" : "TextFillColorPrimaryBrush")
            };
            AutomationProperties.SetName(card, $"第 {episode.Number} 集，{episode.Title}，{episode.WatchStatus}");
            ToolTipService.SetToolTip(card, $"第 {episode.Number} 集 · {episode.Title} · {episode.WatchStatus}\n{episode.Overview}");
            card.DoubleTapped += (_, args) => { if (episode.Available) { Choose(episode); play(episode); args.Handled = true; } };
            _cards.Items.Add(card);

            // The image and caption share the same rail but only the image is
            // inside the native list item, keeping its indicator in that row.
            var caption = Text($"第 {episode.Number} 集 {episode.Title}", 11);
            caption.MaxLines = expanded ? 2 : 1;
            caption.TextTrimming = TextTrimming.CharacterEllipsis;
            caption.Foreground = card.Foreground;
            var captionBox = new Border
            {
                Child = caption, Width = width + 8, Padding = new Thickness(4, 0, 4, 0),
                Margin = new Thickness(0, 0, 6, 0), Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent),
                Opacity = episode.Available ? 1 : .36
            };
            captionBox.Tapped += (_, _) => { if (episode.Available) Choose(episode); };
            captionBox.DoubleTapped += (_, args) => { if (episode.Available) { Choose(episode); play(episode); args.Handled = true; } };
            ToolTipService.SetToolTip(captionBox, $"第 {episode.Number} 集 · {episode.Title} · {episode.WatchStatus}");
            _captions.Children.Add(captionBox);
        }

        _numbers.SelectionChanged += (_, _) => SelectionChanged(_numbers);
        _cards.SelectionChanged += (_, _) => SelectionChanged(_cards);
        var initial = episodes.FirstOrDefault(x => x.Available && x.Number == selectedNumber)
            ?? episodes.FirstOrDefault(x => x.Available);
        if (initial is not null) Choose(initial);
        Loaded += (_, _) => DispatcherQueue.TryEnqueue(RevealSelection);

        void SelectionChanged(ListView list)
        {
            if (!_selecting && list.SelectedItem is ListViewItem { Tag: DemoEpisode episode }) Choose(episode);
        }

        void Choose(DemoEpisode episode)
        {
            _selecting = true;
            _numbers.SelectedItem = _numbers.Items.Cast<ListViewItem>().First(x => ReferenceEquals(x.Tag, episode));
            _cards.SelectedItem = _cards.Items.Cast<ListViewItem>().First(x => ReferenceEquals(x.Tag, episode));
            _selecting = false;
            select(episode);
            RevealSelection();
        }
    }

    private void RevealSelection()
    {
        if (_numbers.SelectedItem is ListViewItem number) _numberRail.Reveal(number);
        if (_cards.SelectedItem is ListViewItem card) _cardRail.Reveal(card);
    }
    public void DetachSeasonSelector(UIElement selector)
    {
        if (selector is FrameworkElement { Parent: Panel parent }) parent.Children.Remove(selector);
    }

    private static ProgressBar Progress(double value, double width) => new()
    {
        Value = value, Width = width, Height = 4, MinHeight = 4, VerticalAlignment = VerticalAlignment.Bottom,
        Foreground = Resource("AccentFillColorDefaultBrush"), Background = Resource("SolidBackgroundFillColorBaseBrush"),
        IsHitTestVisible = false
    };

    private static ListView CreateList(string label)
    {
        var list = new ListView
        {
            SelectionMode = ListViewSelectionMode.Single,
            ItemsPanel = (ItemsPanelTemplate)XamlReader.Load("""
                <ItemsPanelTemplate xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
                    <StackPanel Orientation="Horizontal" />
                </ItemsPanelTemplate>
                """),
            Padding = new Thickness(0), BorderThickness = new Thickness(0),
            HorizontalAlignment = HorizontalAlignment.Left
        };
        ScrollViewer.SetHorizontalScrollMode(list, ScrollMode.Disabled);
        ScrollViewer.SetVerticalScrollMode(list, ScrollMode.Disabled);
        ScrollViewer.SetHorizontalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
        ScrollViewer.SetVerticalScrollBarVisibility(list, ScrollBarVisibility.Disabled);
        AutomationProperties.SetName(list, label);
        return list;
    }
}

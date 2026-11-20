using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Windows.UI.Core;

namespace OcPlayer.Windows.Controls;

// Ignore the default wheel handling so vertical input bubbles to the page unchanged.
// Touch panning, keyboard navigation and explicitly horizontal wheel input remain available.
internal sealed class HorizontalMediaRail : Grid
{
    private const double EdgeTolerance = 1;
    private readonly ScrollView _scroll;
    private readonly Button _previous;
    private readonly Button _next;
    private bool _hovering;
    private bool _keyboardFocus;
    private double _targetOffset;
    private int _scrollCorrelationId = -1;

    public HorizontalMediaRail(UIElement content, string title, double arrowBottomMargin = 44)
    {
        Background = new SolidColorBrush(Colors.Transparent);
        _scroll = new ScrollView
        {
            Content = content,
            ContentOrientation = ScrollingContentOrientation.Horizontal,
            HorizontalScrollBarVisibility = ScrollingScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = ScrollingScrollBarVisibility.Hidden,
            HorizontalScrollMode = ScrollingScrollMode.Enabled,
            VerticalScrollMode = ScrollingScrollMode.Disabled,
            ZoomMode = ScrollingZoomMode.Disabled,
            IgnoredInputKinds = ScrollingInputKinds.MouseWheel
        };
        Children.Add(_scroll);
        _previous = CreateArrow("\uE76B", $"{title}，向前翻页", HorizontalAlignment.Left, -1, arrowBottomMargin);
        _next = CreateArrow("\uE76C", $"{title}，向后翻页", HorizontalAlignment.Right, 1, arrowBottomMargin);
        Children.Add(_previous);
        Children.Add(_next);

        PointerEntered += (_, _) => { _hovering = true; UpdateArrows(); };
        PointerExited += (_, _) => { _hovering = false; UpdateArrows(); };
        PointerWheelChanged += OnWheelChanged;
        GotFocus += (_, args) =>
        {
            if (args.OriginalSource is Control { FocusState: FocusState.Keyboard })
            {
                _keyboardFocus = true;
                UpdateArrows();
            }
        };
        LostFocus += (_, _) =>
        {
            var focused = FocusManager.GetFocusedElement(XamlRoot) as DependencyObject;
            while (focused is not null && focused != this) focused = VisualTreeHelper.GetParent(focused);
            _keyboardFocus &= focused == this;
            UpdateArrows();
        };
        Loaded += (_, _) => UpdateArrows();
        SizeChanged += (_, _) => UpdateArrows();
        _scroll.ExtentChanged += (_, _) => UpdateArrows();
        _scroll.ViewChanged += (_, _) => UpdateArrows();
        _scroll.ScrollCompleted += (_, args) =>
        {
            if (args.CorrelationId != _scrollCorrelationId) return;
            _scrollCorrelationId = -1;
            _targetOffset = _scroll.HorizontalOffset;
        };
        UpdateArrows();
    }

    public void Reveal(FrameworkElement item)
    {
        if (item.ActualWidth <= 0 || _scroll.ViewportWidth <= 0) return;
        var left = item.TransformToVisual(_scroll).TransformPoint(new global::Windows.Foundation.Point()).X;
        var right = left + item.ActualWidth;
        if (left < 0) ScrollBy(left, ScrollingAnimationMode.Disabled);
        else if (right > _scroll.ViewportWidth) ScrollBy(right - _scroll.ViewportWidth, ScrollingAnimationMode.Disabled);
    }

    private Button CreateArrow(string glyph, string label, HorizontalAlignment alignment, int direction, double bottomMargin)
    {
        var button = new Button
        {
            Content = new FontIcon { Glyph = glyph, FontSize = 14 },
            Width = 36,
            Height = 36,
            Padding = new Thickness(0),
            CornerRadius = new CornerRadius(8),
            Background = ArrowBackground("SolidBackgroundFillColorBaseBrush"),
            BorderThickness = new Thickness(0),
            HorizontalAlignment = alignment,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(12, 0, 12, bottomMargin)
        };
        button.Resources["ButtonBackgroundPointerOver"] = ArrowBackground("SolidBackgroundFillColorSecondaryBrush");
        button.Resources["ButtonBackgroundPressed"] = ArrowBackground("SolidBackgroundFillColorTertiaryBrush");
        AutomationProperties.SetName(button, label);
        ToolTipService.SetToolTip(button, label);
        button.Click += (_, _) => ScrollBy(direction * Math.Max(1, _scroll.ViewportWidth * .85));
        return button;
    }

    private static SolidColorBrush ArrowBackground(string resource) =>
        new(((SolidColorBrush)DemoUi.Resource(resource)).Color) { Opacity = .5 };

    private void OnWheelChanged(object sender, PointerRoutedEventArgs args)
    {
        var properties = args.GetCurrentPoint(this).Properties;
        var shift = (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift) & CoreVirtualKeyStates.Down) != 0;
        if (!properties.IsHorizontalMouseWheel && !shift) return;

        // WM_MOUSEHWHEEL uses the opposite sign to the vertical wheel.
        var delta = properties.MouseWheelDelta * (properties.IsHorizontalMouseWheel ? 1 : -1);
        ScrollBy(delta, ScrollingAnimationMode.Disabled);
        args.Handled = true;
    }

    private void ScrollBy(double delta, ScrollingAnimationMode animation = ScrollingAnimationMode.Auto)
    {
        var start = _scrollCorrelationId >= 0 ? _targetOffset : _scroll.HorizontalOffset;
        _targetOffset = Math.Clamp(start + delta, 0, _scroll.ScrollableWidth);
        _scrollCorrelationId = _scroll.ScrollTo(_targetOffset, 0, new ScrollingScrollOptions(animation));
    }

    private void UpdateArrows()
    {
        UpdateArrow(_previous, _scroll.HorizontalOffset > EdgeTolerance);
        UpdateArrow(_next, _scroll.ScrollableWidth - _scroll.HorizontalOffset > EdgeTolerance);
    }

    private void UpdateArrow(Button button, bool canScroll)
    {
        var visible = canScroll && (_hovering || _keyboardFocus);
        button.IsEnabled = canScroll;
        button.Opacity = visible ? 1 : 0;
        button.IsHitTestVisible = visible;
    }
}

using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;

namespace OcPlayer.Windows.Controls;

// Keep the title-bar clearance in the scroll extent, so it scrolls away while
// the viewport continues underneath the chrome and down to the window edge.
internal sealed class PageLayout : DependencyObject
{
    public static readonly DependencyProperty HeaderHeightProperty = DependencyProperty.Register(
        nameof(HeaderHeight), typeof(double), typeof(PageLayout), new PropertyMetadata(48d));

    public double HeaderHeight
    {
        get => (double)GetValue(HeaderHeightProperty);
        set => SetValue(HeaderHeightProperty, value);
    }

    public ScrollViewer Scroll(UIElement content, Thickness? padding = null)
    {
        var scroll = DemoUi.Scroll(content, new Thickness(0));
        ApplyInset((Grid)scroll.Content, Grid.PaddingProperty, padding ?? new Thickness(36, 24, 36, 32));
        return scroll;
    }

    public void ApplyInset(FrameworkElement target, DependencyProperty property, Thickness spacing) =>
        target.SetBinding(property, new Binding
        {
            Source = this,
            Path = new PropertyPath(nameof(HeaderHeight)),
            Mode = BindingMode.OneWay,
            Converter = new HeaderInsetConverter(spacing)
        });

    private sealed class HeaderInsetConverter(Thickness spacing) : IValueConverter
    {
        public object Convert(object value, Type targetType, object parameter, string language) =>
            new Thickness(spacing.Left, spacing.Top + (double)value, spacing.Right, spacing.Bottom);

        public object ConvertBack(object value, Type targetType, object parameter, string language) =>
            throw new NotSupportedException();
    }
}

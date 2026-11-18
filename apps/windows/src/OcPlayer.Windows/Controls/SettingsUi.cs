using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using static OcPlayer.Windows.Controls.DemoUi;

namespace OcPlayer.Windows.Controls;

// Shared settings geometry and live theme resources for all settings pages.
internal static class SettingsUi
{
    public static TextBlock Caption(string text, double size = 12) => new()
    {
        Text = text, FontSize = size, IsTextSelectionEnabled = true,
        Style = (Style)Application.Current.Resources["SettingsCaptionStyle"]
    };

    public static TextBlock Value(string text) => new()
    {
        Text = text, FontSize = 13, TextAlignment = TextAlignment.Right,
        TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true
    };

    public static Border Card(UIElement content) => new()
    {
        Child = content, Style = (Style)Application.Current.Resources["SettingsCardStyle"]
    };

    public static Border Divider() => new() { Style = (Style)Application.Current.Resources["SettingsDividerStyle"] };

    public static StackPanel Section(StackPanel page, string title, bool collapsed = false)
    {
        var rows = Stack(0);
        if (collapsed)
        {
            page.Children.Add(new Expander
            {
                Header = title, Content = rows, HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Stretch, CornerRadius = new CornerRadius(16)
            });
        }
        else
        {
            var section = Stack(8);
            if (title.Length > 0) section.Children.Add(Caption(title, 13));
            section.Children.Add(Card(rows)); page.Children.Add(section);
        }
        return rows;
    }

    public static void Add(Panel rows, UIElement item)
    {
        if (rows.Children.Count > 0 && item is not TextBlock)
        {
            var divider = Divider();
            if (item is FrameworkElement element)
            {
                divider.Visibility = element.Visibility;
                element.RegisterPropertyChangedCallback(UIElement.VisibilityProperty, (_, _) => divider.Visibility = element.Visibility);
            }
            rows.Children.Add(divider);
        }
        if (item is TextBlock note) note.Margin = new Thickness(0, 3, 0, 10);
        rows.Children.Add(item);
    }

    public static Grid Row(string title, FrameworkElement value, bool field = false)
    {
        if (AutomationProperties.GetName(value).Length == 0) AutomationProperties.SetName(value, title);
        // The visible label belongs to the row, so controls retain no second header.
        switch (value)
        {
            case TextBox box: box.Header = null; break;
            case PasswordBox box: box.Header = null; break;
            case ComboBox box: box.Header = null; break;
            case NumberBox box: box.Header = null; break;
            case ToggleSwitch box: box.Header = null; box.OnContent = box.OffContent = ""; box.MinWidth = 0; break;
        }
        var row = new Grid { MinHeight = 42, ColumnSpacing = 10, Padding = new Thickness(0, 4, 0, 4) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var label = Text(title, 13); label.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(label);
        value.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(value, 1); row.Children.Add(value);
        if (field)
        {
            var width = double.IsNaN(value.Width) ? 240 : Math.Min(240, value.Width);
            value.MinWidth = 0; value.Width = width;
            value.HorizontalAlignment = HorizontalAlignment.Stretch;
            row.SizeChanged += (_, _) => value.Width = Math.Min(width, Math.Max(100, row.ActualWidth * .48));
        }
        else if (value is TextBlock text)
        {
            text.TextAlignment = TextAlignment.Right;
            row.SizeChanged += (_, _) => text.MaxWidth = Math.Max(100, row.ActualWidth * .65);
        }
        return row;
    }

    public static Button Action(Button button, bool destructive = false)
    {
        // Existing page actions originate from DemoUi.Button; its local values
        // must be cleared so the shared settings style can set row geometry.
        button.ClearValue(Control.PaddingProperty);
        button.ClearValue(Control.BackgroundProperty);
        button.ClearValue(Control.BorderThicknessProperty);
        button.ClearValue(Control.HorizontalContentAlignmentProperty);
        button.ClearValue(FrameworkElement.HorizontalAlignmentProperty);
        button.ClearValue(FrameworkElement.MinHeightProperty);
        button.ClearValue(Control.FontSizeProperty);
        button.ClearValue(Control.ForegroundProperty);
        button.Style = (Style)Application.Current.Resources[destructive ? "SettingsDestructiveActionStyle" : "SettingsActionStyle"];
        return button;
    }

    public static void Status(TextBlock status)
    {
        status.Style = (Style)Application.Current.Resources["SettingsCaptionStyle"];
        status.Visibility = status.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        status.RegisterPropertyChangedCallback(TextBlock.TextProperty, (_, _) =>
            status.Visibility = status.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible);
    }
}

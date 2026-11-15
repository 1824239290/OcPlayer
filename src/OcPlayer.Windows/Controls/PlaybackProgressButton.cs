using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using OcPlayer.Windows.Preview;
using Windows.UI;

namespace OcPlayer.Windows.Controls;

// Keep the default Button template and native input states; only its background
// is split into a progress tint and the ordinary button fill.
internal sealed class PlaybackProgressButton : Button
{
    private double _progress;

    public PlaybackProgressButton(Action play)
    {
        Width = 228;
        Height = 36;
        Content = "播放";
        Click += (_, _) => play();
        Loaded += (_, _) => UpdateBackgrounds();
        ActualThemeChanged += (_, _) => UpdateBackgrounds();
    }

    public void SetProgress(DemoMedia media, int selectedNumber, bool demoMode = false)
    {
        var percentage = media.PlaybackProgress(selectedNumber, demoMode);
        _progress = double.IsFinite(percentage) && percentage > 0 && percentage < 100 ? percentage / 100 : 0;
        Content = media.PlaybackButtonLabel(selectedNumber, demoMode);
        AutomationProperties.SetName(this, (string)Content);
        AutomationProperties.SetHelpText(this, _progress > 0 ? $"已播放 {percentage:0.#}%" : "播放当前选中的媒体");
        if (IsLoaded) UpdateBackgrounds();
    }

    private void UpdateBackgrounds()
    {
        // Resolve ThemeResource through a theme-specific element so the native
        // fills follow the page theme even when it differs from the app theme.
        var colors = (StackPanel)XamlReader.Load("""
            <StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
                <Border Background="{ThemeResource ControlFillColorDefaultBrush}" />
                <Border Background="{ThemeResource ControlFillColorSecondaryBrush}" />
                <Border Background="{ThemeResource ControlFillColorTertiaryBrush}" />
                <Border Background="{ThemeResource AccentFillColorDefaultBrush}" />
            </StackPanel>
            """);
        colors.RequestedTheme = ActualTheme;
        Color ColorAt(int index) => ((SolidColorBrush)((Border)colors.Children[index]).Background).Color;
        var accent = ColorAt(3);
        Brush Fill(Color normal)
        {
            if (_progress == 0) return new SolidColorBrush(normal);
            // A translucent accent keeps the default text legible on both
            // sides while leaving the artwork visible through the button.
            var tint = Color.FromArgb(102, accent.R, accent.G, accent.B);
            return new LinearGradientBrush
            {
                StartPoint = new(0, .5), EndPoint = new(1, .5),
                GradientStops =
                {
                    new GradientStop { Color = tint, Offset = 0 },
                    new GradientStop { Color = tint, Offset = _progress },
                    new GradientStop { Color = normal, Offset = _progress },
                    new GradientStop { Color = normal, Offset = 1 }
                }
            };
        }
        Background = Fill(ColorAt(0));
        Resources["ButtonBackgroundPointerOver"] = Fill(ColorAt(1));
        Resources["ButtonBackgroundPressed"] = Fill(ColorAt(2));
    }
}

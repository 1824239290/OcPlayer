using System.Globalization;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Services;

namespace OcPlayer.Windows;

public sealed partial class PlayerView
{
    private void ApplySubtitleStyle(RuntimePreferences preferences)
    {
        static uint Color(string? value, uint fallback) => value is { Length: 9 } && uint.TryParse(value.AsSpan(1), NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var rgba) ? rgba : fallback;
        uint mask = 0;
        if (preferences.OverrideSubtitleStyles)
        {
            if (preferences.SubtitleColor is not null || preferences.SubtitleOutlineColor is not null) mask |= 1 << 4;
            if (preferences.SubtitleBold is not null) mask |= 1 << 5;
            if (preferences.SubtitleOutlineWidth > 0) mask |= 1 << 6;
            if (preferences.SubtitlePosition != "unset") mask |= 1 << 7;
            if (preferences.SubtitleMargin > 0) mask |= 1 << 8;
        }
        _session?.SetSubtitleStyle(new ErikaPresenter.SubtitleStyle
        {
            PrimaryColorRgba = Color(preferences.SubtitleColor, 0xffffffff), OutlineColorRgba = Color(preferences.SubtitleOutlineColor, 0x0000007f),
            FontSize = 48, OutlineWidth = preferences.SubtitleOutlineWidth > 0 ? preferences.SubtitleOutlineWidth : 2,
            Bold = preferences.SubtitleBold ?? false, ScaleXPercent = 100, ScaleYPercent = 100, BorderStyle = 1,
            Alignment = preferences.SubtitlePosition switch { "bottom-left" => 1, "bottom-right" => 3, "top-center" => 8, _ => 2 },
            MarginLeft = 48, MarginRight = 48, MarginVertical = preferences.SubtitleMargin > 0 ? preferences.SubtitleMargin : 54, OverrideMask = mask
        });
    }
}

using System.Text.Json;

namespace OcPlayer.Windows.Services;

internal sealed record PlaybackPreferences(double SubtitleScale = 1, double Rate = 1, double Volume = .4, bool Muted = false)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    public PlaybackPreferences Validated() => this with
    {
        SubtitleScale = double.IsFinite(SubtitleScale) ? Math.Clamp(SubtitleScale, .5, 3) : 1,
        Rate = double.IsFinite(Rate) ? Math.Clamp(Rate, .5, 2) : 1,
        Volume = double.IsFinite(Volume) ? Math.Clamp(Volume, 0, 1) : .4
    };

    public static PlaybackPreferences Load(string directory)
    {
        var path = Path.Combine(directory, "playback-preferences.json");
        try
        {
            return File.Exists(path)
                ? (JsonSerializer.Deserialize<PlaybackPreferences>(File.ReadAllText(path), JsonOptions) ?? new()).Validated()
                : new();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            // Keep an unreadable preference file untouched; playback can still use defaults.
            return new();
        }
    }

    public void Save(string directory)
    {
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "playback-preferences.json");
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(Validated(), JsonOptions));
        File.Move(temporary, path, true);
    }
}

using System.Text.Json;

namespace OcPlayer.Windows.Services;

internal sealed record WindowPreferences(
    int? Width = null,
    int? Height = null,
    int? X = null,
    int? Y = null,
    bool IsMaximized = false)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true
    };

    public static WindowPreferences Load(string directory)
    {
        var path = Path.Combine(directory, "window-preferences.json");
        try
        {
            return File.Exists(path)
                ? (JsonSerializer.Deserialize<WindowPreferences>(File.ReadAllText(path), JsonOptions) ?? new())
                : new();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            return new();
        }
    }

    public void Save(string directory)
    {
        try
        {
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, "window-preferences.json");
            var temporary = path + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(this, JsonOptions));
            File.Move(temporary, path, true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Best effort persistence; failure to save should not disrupt application runtime or shutdown.
        }
    }
}

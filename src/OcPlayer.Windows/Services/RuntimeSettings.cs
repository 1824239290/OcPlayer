using System.Text.Json;
using System.Text.RegularExpressions;

namespace OcPlayer.Windows.Services;

/// Settings are read at request/open time. The event also updates an already open player.
internal sealed record RuntimePreferences(
    int NetworkBufferMiB = 2, int BackBufferMiB = 16,
    bool SkipIntro = true, bool SkipOutro = true, int OutroRetainSeconds = 10,
    string SubtitleLanguage = "zh-Hans", string SubtitlePosition = "unset", int SubtitleMargin = 0,
    string? SubtitleColor = null, string? SubtitleOutlineColor = null, int SubtitleOutlineWidth = 0,
    bool? SubtitleBold = null, bool OverrideSubtitleStyles = false, string QualityEnhancement = "off",
    string UserAgent = "", bool DetailedLogging = false, bool DanmakuDiagnostics = false)
{
    public string EffectiveUserAgent => string.IsNullOrWhiteSpace(UserAgent) ? "OcPlayer/0.3.0 (Windows)" : UserAgent;
    public RuntimePreferences Validated()
    {
        if (!new[] { 2, 8, 16, 32 }.Contains(NetworkBufferMiB) || !new[] { 16, 32, 64, 128 }.Contains(BackBufferMiB)
            || !new[] { 0, 5, 10, 15, 20, 30 }.Contains(OutroRetainSeconds)) throw new ArgumentException("缓冲或片尾保留档位无效。");
        if (!new[] { "zh-Hans", "zh-Hant", "default", "off" }.Contains(SubtitleLanguage)
            || !new[] { "unset", "bottom-center", "bottom-left", "bottom-right", "top-center" }.Contains(SubtitlePosition)
            || SubtitleMargin is < 0 or > 200 || SubtitleMargin % 10 != 0 || SubtitleOutlineWidth is < 0 or > 32
            || !new[] { "off", "artcnn-f16", "artcnn-f32", "artcnn-f16-denoise" }.Contains(QualityEnhancement))
            throw new ArgumentException("播放或字幕设置无效。");
        static string? Color(string? raw) => string.IsNullOrWhiteSpace(raw) ? null : Regex.IsMatch(raw, "^#[0-9a-fA-F]{8}$")
            ? raw.ToUpperInvariant() : throw new ArgumentException("颜色请输入 #RRGGBBAA（含透明度）。");
        return this with { UserAgent = new string((UserAgent ?? "").Where(c => !char.IsControl(c)).ToArray()).Trim(),
            SubtitleColor = Color(SubtitleColor), SubtitleOutlineColor = Color(SubtitleOutlineColor) };
    }
}

internal static class RuntimeSettings
{
    private static string PathName => Path.Combine(Environment.GetEnvironmentVariable("OCP_DATA_DIRECTORY") ??
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OcPlayer", "Windows"), "runtime-settings.json");
    public static RuntimePreferences Current { get; private set; } = Read();
    public static event Action<RuntimePreferences>? Changed;
    public static string? LoadWarning { get; private set; }
    private static RuntimePreferences Read()
    {
        try { return File.Exists(PathName) ? (JsonSerializer.Deserialize<RuntimePreferences>(File.ReadAllText(PathName)) ?? new()).Validated() : new(); }
        catch (Exception ex) when (ex is IOException or JsonException or ArgumentException or UnauthorizedAccessException)
        { LoadWarning = "播放设置文件不可读，已使用默认值；原文件保留。"; return new(); }
    }
    public static void Save(RuntimePreferences value)
    {
        value = value.Validated(); Directory.CreateDirectory(Path.GetDirectoryName(PathName)!);
        var temporary = PathName + ".tmp"; File.WriteAllText(temporary, JsonSerializer.Serialize(value)); File.Move(temporary, PathName, true);
        Current = value; LoadWarning = null; Changed?.Invoke(value);
    }
}

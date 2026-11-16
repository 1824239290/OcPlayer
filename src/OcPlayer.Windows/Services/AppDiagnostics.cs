using System.Text.Json;
using System.Text.RegularExpressions;

namespace OcPlayer.Windows.Services;

internal sealed record DiagnosticRecord(DateTimeOffset Time, string Level, string Message, int Suppressed = 0);
internal static class AppDiagnostics
{
    private static readonly object Gate = new();
    public static string DirectoryPath => Path.Combine(Environment.GetEnvironmentVariable("OCP_DATA_DIRECTORY") ??
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OcPlayer", "Windows"), "Logs");
    public static string FilePath => Path.Combine(DirectoryPath, "diagnostics.jsonl");
    public static string[] NativeTracePaths => new[] { "erika-playback.log", "erika-capi.log", "erika-danmaku.log" }.Select(x => Path.Combine(DirectoryPath, x)).ToArray();
    public static long NativeTraceBytes => NativeTracePaths.Where(File.Exists).Sum(x => new FileInfo(x).Length);
    static AppDiagnostics() { RuntimeSettings.Changed += ConfigureDanmakuTrace; ConfigureDanmakuTrace(RuntimeSettings.Current); }
    private static void ConfigureDanmakuTrace(RuntimePreferences settings)
    {
        try { Directory.CreateDirectory(DirectoryPath); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return; }
        Environment.SetEnvironmentVariable("ERIKA_DANMAKU_TRACE_FILE", NativeTracePaths[2]);
        Environment.SetEnvironmentVariable("ERIKA_DANMAKU_TRACE", settings.DanmakuDiagnostics ? "1" : "0");
    }
    /// Called immediately before opening a source. Only detailed native trace waits for the next playback.
    public static void ConfigureNativeTrace()
    {
        var settings = RuntimeSettings.Current;
        try { Directory.CreateDirectory(DirectoryPath); foreach (var path in NativeTracePaths) if (File.Exists(path) && new FileInfo(path).Length > 8 * 1024 * 1024) File.Move(path, path + ".previous", true); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Write("warning", "无法创建或轮转内核诊断日志：" + ex.Message); }
        Environment.SetEnvironmentVariable("ERIKA_PLAYBACK_TRACE_FILE", NativeTracePaths[0]);
        Environment.SetEnvironmentVariable("ERIKA_CAPI_TRACE_FILE", NativeTracePaths[1]);
        Environment.SetEnvironmentVariable("ERIKA_PLAYBACK_TRACE", settings.DetailedLogging ? "1" : "0");
        Environment.SetEnvironmentVariable("ERIKA_CAPI_TRACE", settings.DetailedLogging ? "1" : "0");
        Environment.SetEnvironmentVariable("ERIKA_CLOCK_TRACE", settings.DetailedLogging ? "1" : "0");
        ConfigureDanmakuTrace(settings);
    }
    public static void Write(string level, string message, bool danmaku = false)
    {
        if (danmaku ? !RuntimeSettings.Current.DanmakuDiagnostics : level is "debug" or "trace" && !RuntimeSettings.Current.DetailedLogging) return;
        // Never persist signed URLs, bearer values or server credentials in diagnostics.
        message = Regex.Replace(message, @"https?://[^\s]+", "<URL>", RegexOptions.IgnoreCase);
        message = Regex.Replace(message, @"(?i)(token|api[_-]?key|password|authorization)\s*[:=]\s*[^\s,;]+", "$1=<redacted>");
        lock (Gate)
        {
            try { Directory.CreateDirectory(DirectoryPath);
                if (File.Exists(FilePath) && new FileInfo(FilePath).Length > 4 * 1024 * 1024) File.Move(FilePath, Path.Combine(DirectoryPath, "diagnostics-previous.jsonl"), true);
                File.AppendAllText(FilePath, JsonSerializer.Serialize(new DiagnosticRecord(DateTimeOffset.Now, level, message)) + Environment.NewLine); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { /* Logging must not interrupt playback. */ }
        }
    }
    public static Task<(long Count, long Bytes, DiagnosticRecord[] Recent)> Read() => Task.Run(() =>
    {
        lock (Gate)
        {
            long count = 0, bytes = 0; var recent = new Queue<DiagnosticRecord>();
            if (Directory.Exists(DirectoryPath)) foreach (var path in Directory.EnumerateFiles(DirectoryPath, "diagnostics*.jsonl").OrderBy(File.GetLastWriteTimeUtc))
            {
                bytes += new FileInfo(path).Length;
                foreach (var line in File.ReadLines(path)) { if (line.Length == 0) continue; count++;
                    try { if (JsonSerializer.Deserialize<DiagnosticRecord>(line) is { } record) { recent.Enqueue(record); if (recent.Count > 100) recent.Dequeue(); } } catch (JsonException) { } }
            }
            return (count, bytes, recent.ToArray());
        }
    });
    public static void Clear()
    {
        lock (Gate)
        {
            if (Directory.Exists(DirectoryPath)) foreach (var path in Directory.EnumerateFiles(DirectoryPath, "diagnostics*.jsonl")) File.Delete(path);
            foreach (var path in NativeTracePaths.SelectMany(x => new[] { x, x + ".previous" }).Where(File.Exists)) File.Delete(path);
        }
    }
}

using System.Collections.Concurrent;

namespace OcPlayer.Windows.Services;

/// Disk policies apply only to disposable files; mappings and preferences are excluded.
internal static class CacheFiles
{
    internal sealed class State { public readonly object Gate = new(); public long Generation; public DateTimeOffset LastPruneUtc = DateTimeOffset.MinValue; }
    private static readonly ConcurrentDictionary<string, State> States = new(StringComparer.OrdinalIgnoreCase);
    public static State For(string directory) => States.GetOrAdd(Path.GetFullPath(directory), _ => new());
    public static long UsedBytes(string directory, Func<FileInfo, bool> include) => Enumerate(directory).Where(include).Sum(x => Size(x));
    private static long Size(FileInfo file) { try { return file.Length; } catch (IOException) { return 0; } }

    public static void Prune(string directory, long capacity, Func<FileInfo, bool> include, TimeSpan? age = null, string? protect = null, bool force = false)
    {
        var state = For(directory);
        lock (state.Gate)
        {
            // 写入路径会频繁触发维护，同一目录 60 秒内只做一次全量枚举；显式维护用 force 绕过。
            if (!force && DateTimeOffset.UtcNow - state.LastPruneUtc < TimeSpan.FromSeconds(60)) return;
            state.LastPruneUtc = DateTimeOffset.UtcNow;
            try { PruneCore(directory, capacity, include, age, protect); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { System.Diagnostics.Debug.WriteLine("Cache maintenance: " + ex.Message); }
        }
    }

    private static void PruneCore(string directory, long capacity, Func<FileInfo, bool> include, TimeSpan? age, string? protect)
    {
        var files = Enumerate(directory).Where(include).OrderBy(x => x.LastWriteTimeUtc).ToArray();
        var bytes = files.Sum(Size); var cutoff = age is null ? DateTime.MinValue : DateTime.UtcNow - age.Value;
        foreach (var file in files)
        {
            if (file.FullName.Equals(protect, StringComparison.OrdinalIgnoreCase) && Size(file) <= capacity) continue;
            if (bytes <= capacity && (age is null || file.LastWriteTimeUtc >= cutoff)) continue;
            try { var size = file.Length; file.Delete(); bytes -= size; }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
        foreach (var temp in Enumerate(directory).Where(x => x.Name.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase) && x.LastWriteTimeUtc < DateTime.UtcNow.AddDays(-1)))
            try { temp.Delete(); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    public static void Clear(string directory, Func<FileInfo, bool> include)
    {
        // Clear failures are surfaced to the settings page, never reported as success.
        lock (For(directory).Gate) foreach (var file in Enumerate(directory).Where(include)) file.Delete();
    }

    public static IEnumerable<FileInfo> Enumerate(string directory)
    {
        if (!Directory.Exists(directory)) yield break;
        AppPaths.RejectReparsePoints(directory, AppPaths.IsWithin(directory, AppPaths.DataDirectory) ? AppPaths.DataDirectory : directory);
        foreach (var file in new DirectoryInfo(directory).EnumerateFiles())
            if ((file.Attributes & FileAttributes.ReparsePoint) == 0) yield return file;
        foreach (var child in new DirectoryInfo(directory).EnumerateDirectories())
            if ((child.Attributes & FileAttributes.ReparsePoint) == 0)
                foreach (var file in Enumerate(child.FullName)) yield return file;
    }

    public static bool HashedJson(FileInfo file) => file.Extension == ".json" && file.Name.Length == 69
        && Path.GetFileNameWithoutExtension(file.Name).All(Uri.IsHexDigit);
}

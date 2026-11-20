using System.Security.Cryptography;
using System.Text;
using Microsoft.Data.Sqlite;

namespace OcPlayer.Windows.Services;

internal static class AppDataMigration
{
    public const string Argument = "--migrate-data=";
    private static readonly string[] Files = ["browser-preferences.json", "library-sort.json", "playback-preferences.json",
        "runtime-settings.json", "recent-media.json", "servers.json", "ignored-release.txt", "bangumi-data.json", "window-preferences.json"];
    private static readonly string[] Directories = ["ViewingHistory", "Integrations", "Tmdb", "Danmaku"];

    /// Import missing durable data once. Existing destination data always wins;
    /// SQLite backup takes a consistent snapshot even when the source uses WAL.
    public static int Import(string source, string destination)
    {
        source = AppPaths.ResolveDataDirectory(source); destination = AppPaths.ResolveDataDirectory(destination);
        if (!Directory.Exists(source) || source.Equals(destination, StringComparison.OrdinalIgnoreCase)) return 0;
        if (AppPaths.IsWithin(source, destination) || AppPaths.IsWithin(destination, source))
            throw new IOException("旧数据目录与新数据目录不能互相包含。");
        AppPaths.RejectReparsePoints(source, source); AppPaths.RejectReparsePoints(destination, destination);
        Directory.CreateDirectory(destination);
        using var migrationLock = new FileStream(Path.Combine(destination, ".migration.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        var identity = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(source.ToUpperInvariant())));
        var marker = Path.Combine(destination, ".migrated-" + identity);
        if (File.Exists(marker)) return 0;
        var staging = Path.Combine(destination, ".migration-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(staging);
        var copied = new List<string>();
        try
        {
            foreach (var name in Files) Stage(name);
            foreach (var directory in Directories)
            {
                var path = Path.Combine(source, directory);
                if (!Directory.Exists(path)) continue;
                foreach (var file in Enumerate(path))
                {
                    var name = Path.GetFileName(file);
                    if (name.EndsWith(".tmp", StringComparison.OrdinalIgnoreCase)
                        || directory == "Danmaku" && name.StartsWith("comments-", StringComparison.Ordinal)) continue;
                    Stage(Path.GetRelativePath(source, file));
                }
            }
            foreach (var name in new[] { "Media.sqlite", "Bangumi.sqlite" })
            {
                var input = Path.Combine(source, name); var target = Path.Combine(destination, name);
                if (!File.Exists(input) || File.Exists(target)) continue;
                AppPaths.RejectReparsePoints(input, source); AppPaths.RejectReparsePoints(target, destination);
                using var from = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = input, Mode = SqliteOpenMode.ReadOnly, Pooling = false }.ToString());
                using var to = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = Path.Combine(staging, name), Pooling = false }.ToString());
                from.Open(); to.Open(); from.BackupDatabase(to); copied.Add(name);
            }
            // Staging completes before any destination file is made visible.
            // The marker is written last, so an interrupted import can resume.
            foreach (var relative in copied)
            {
                var target = Path.Combine(destination, relative);
                AppPaths.RejectReparsePoints(target, destination);
                Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                if (!File.Exists(target)) File.Move(Path.Combine(staging, relative), target);
            }
            File.WriteAllText(marker, "1");
            return copied.Count;
        }
        finally
        {
            // Only this invocation's validated staging directory is removed.
            AppPaths.RejectReparsePoints(staging, destination);
            Directory.Delete(staging, true);
        }

        void Stage(string relative)
        {
            var input = Path.Combine(source, relative); var target = Path.Combine(destination, relative);
            if (!File.Exists(input) || File.Exists(target)) return;
            AppPaths.RejectReparsePoints(input, source); AppPaths.RejectReparsePoints(target, destination);
            var staged = Path.Combine(staging, relative); Directory.CreateDirectory(Path.GetDirectoryName(staged)!);
            using var stream = new FileStream(input, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var output = new FileStream(staged, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            stream.CopyTo(output); copied.Add(relative);
        }

        IEnumerable<string> Enumerate(string directory)
        {
            AppPaths.RejectReparsePoints(directory, source);
            foreach (var file in Directory.EnumerateFiles(directory)) yield return file;
            foreach (var child in Directory.EnumerateDirectories(directory))
                foreach (var file in Enumerate(child)) yield return file;
        }
    }
}

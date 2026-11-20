using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;

internal static partial class Program
{
    private static async Task VerifyStorage(OcpCoreClient core, string data)
    {
        Assert(AppPaths.ResolveDataDirectory("  ") == AppPaths.DefaultDataDirectory, "empty path override resolves to the normal per-user data directory");
        foreach (var invalid in new[] { "relative-data", Path.GetPathRoot(data)!, AppContext.BaseDirectory })
        {
            try { AppPaths.ResolveDataDirectory(invalid); throw new Exception("Unsafe data directory accepted"); }
            catch (InvalidOperationException) { Assert(true, "data paths reject relative, drive-root and install-directory storage"); }
        }
        Assert(!AppPaths.IsWithin(data + "-other", data), "workspace boundary checks reject sibling paths sharing the same prefix");
        var source = Path.Combine(data, "legacy"); var destination = Path.Combine(data, "migrated");
        Directory.CreateDirectory(source); Directory.CreateDirectory(destination);
        File.WriteAllText(Path.Combine(source, "runtime-settings.json"), "legacy-settings");
        File.WriteAllText(Path.Combine(source, "library-sort.json"), "old-sort");
        File.WriteAllText(Path.Combine(destination, "library-sort.json"), "current-sort");
        Directory.CreateDirectory(Path.Combine(source, "Danmaku"));
        File.WriteAllText(Path.Combine(source, "Danmaku", "mapping.json"), "manual-match");
        File.WriteAllText(Path.Combine(source, "Danmaku", "comments-1.json"), "disposable");
        Directory.CreateDirectory(Path.Combine(source, "Images")); File.WriteAllText(Path.Combine(source, "Images", "old.image"), "disposable");
        using (var database = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = Path.Combine(source, "Media.sqlite"), Pooling = false }.ToString()))
        {
            database.Open(); using var command = database.CreateCommand();
            command.CommandText = "PRAGMA journal_mode=WAL; CREATE TABLE snapshot(value INTEGER); INSERT INTO snapshot VALUES(42);"; command.ExecuteNonQuery();
            Assert(File.Exists(Path.Combine(source, "Media.sqlite-wal")), "migration fixture has committed data in a live SQLite WAL");
            Assert(AppDataMigration.Import(source, destination) == 3, "migration imports missing durable settings, manual matches and a consistent database snapshot");
            using var copied = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = Path.Combine(destination, "Media.sqlite"), Pooling = false }.ToString()); copied.Open();
            using var check = copied.CreateCommand(); check.CommandText = "SELECT value FROM snapshot";
            Assert(Convert.ToInt64(check.ExecuteScalar()) == 42, "database migration includes committed WAL rows while the old database is open");
        }
        Assert(File.ReadAllText(Path.Combine(destination, "library-sort.json")) == "current-sort" && File.ReadAllText(Path.Combine(source, "runtime-settings.json")) == "legacy-settings",
            "migration preserves existing destination preferences and the complete source store");
        Assert(!Directory.Exists(Path.Combine(destination, "Images")) && !File.Exists(Path.Combine(destination, "Danmaku", "comments-1.json")), "migration excludes downloaded images and disposable comments");
        File.Delete(Path.Combine(destination, "runtime-settings.json"));
        Assert(AppDataMigration.Import(source, destination) == 0 && !File.Exists(Path.Combine(destination, "runtime-settings.json")), "completed migration never resurrects subsequently deleted settings");

        var windowPrefsDir = Path.Combine(data, "window-prefs");
        var emptyWindowPrefs = WindowPreferences.Load(windowPrefsDir);
        Assert(emptyWindowPrefs.Width is null && emptyWindowPrefs.Height is null && !emptyWindowPrefs.IsMaximized,
            "window preferences default to unset when file is absent");
        var customWindowPrefs = new WindowPreferences(1400, 900, 100, 150, true);
        customWindowPrefs.Save(windowPrefsDir);
        var loadedWindowPrefs = WindowPreferences.Load(windowPrefsDir);
        Assert(loadedWindowPrefs == customWindowPrefs, "window preferences persist and reload dimensions, position and maximized state");
        File.WriteAllText(Path.Combine(windowPrefsDir, "window-preferences.json"), "{ invalid json");
        Assert(WindowPreferences.Load(windowPrefsDir) == new WindowPreferences(), "damaged window preferences safely fall back to default");

        var quota = Path.Combine(data, "quota"); Directory.CreateDirectory(quota);
        var older = Path.Combine(quota, "old.cache"); var newer = Path.Combine(quota, "new.cache");
        File.WriteAllBytes(older, new byte[12]); File.SetLastWriteTimeUtc(older, DateTime.UtcNow.AddDays(-2)); File.WriteAllBytes(newer, new byte[12]);
        File.WriteAllText(Path.Combine(quota, "mapping.json"), "preserve");
        CacheFiles.Prune(quota, 12, x => x.Extension == ".cache");
        Assert(!File.Exists(older) && File.Exists(newer) && File.Exists(Path.Combine(quota, "mapping.json")), "disk eviction removes oldest disposable files while retaining durable mappings");
        var partial = Path.Combine(quota, "old.tmp"); File.WriteAllText(partial, "partial"); File.SetLastWriteTimeUtc(partial, DateTime.UtcNow.AddDays(-2));
        CacheFiles.Prune(quota, 12, x => x.Extension == ".cache", force: true); Assert(!File.Exists(partial), "maintenance removes abandoned partial downloads");

        var a = new BrowserCache(new ServerProfile("storage-a", "jellyfin", "http://localhost", "user-1"));
        var a2 = new BrowserCache(new ServerProfile("storage-a", "jellyfin", "http://localhost", "user-2"));
        var b = new BrowserCache(new ServerProfile("storage-b", "jellyfin", "http://localhost", "user-1"));
        var payload = new Dictionary<string, string> { ["name"] = "fixture" }; var stale = a.Revision;
        a.Save("home", payload); a2.Save("home", payload); b.Save("home", payload);
        BrowserCache.ClearServer("storage-a"); a.Save("delayed", payload, stale);
        Assert(a.Read<Dictionary<string, string>>("home") is null && a2.Read<Dictionary<string, string>>("home") is null
            && b.Read<Dictionary<string, string>>("home") is not null, "clearing a server removes all its users' browser files while preserving other servers");
        Assert(a.Read<Dictionary<string, string>>("delayed") is null, "requests started before cache clear cannot repopulate browser metadata");
        foreach (var tenant in new[] { "storage-a", "storage-a:user-1", "storage-b:user-1" })
            PlaybackSession.Require(core.Call("cache.saveItems", new { tenantId = tenant, items = new[] { new { id = "item", name = "Fixture", kind = "movie" } }, now = 10, requestStartedAt = 9 }));
        CoreRuntime.ClearServerMetadata(core, new ServerProfile("storage-a", "jellyfin", "http://localhost", "user-1"));
        Assert(!PlaybackSession.Require(core.Call("cache.hasContent", new { tenantId = "storage-a" })).GetBoolean()
            && !PlaybackSession.Require(core.Call("cache.hasContent", new { tenantId = "storage-a:user-1" })).GetBoolean()
            && PlaybackSession.Require(core.Call("cache.hasContent", new { tenantId = "storage-b:user-1" })).GetBoolean(),
            "metadata clear removes both migrated and current-account database tenants without touching other servers");

        Directory.CreateDirectory(ServerSubtitleService.DirectoryPath);
        File.WriteAllText(Path.Combine(ServerSubtitleService.DirectoryPath, "fixture.srt"), "subtitle");
        ServerSubtitleService.Clear(); Assert(ServerSubtitleService.UsedBytes == 0, "subtitle clear removes actual downloaded subtitle files");
        var aliasStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var service = new DanmakuService(core, data, new DanmakuSettings(() => null, _ => { }), aliasProvider: async (_, token) =>
        { aliasStarted.TrySetResult(); await Task.Delay(Timeout.Infinite, token); return []; }, introProvidersEnabled: false);
        PlaybackSession.Require(core.Call("danmakuCache.setEpisodeMatch", new { mediaID = "manual", payloadJSON = new { episodeID = 1, shiftSeconds = 5 } }));
        PlaybackSession.Require(core.Call("danmakuCache.setComments", new { episodeID = 1, payloadJSON = new[] { new { p = "0,1,16777215", m = "cached comment" } } }));
        var mediaPath = Path.Combine(data, "storage-media.mkv"); File.WriteAllText(mediaPath, "fixture");
        var media = new DemoMedia("waiting", "Storage title", "", "", "", "", "");
        var pending = service.Load(service.Context(media, new PlaybackSource(media.Id, media.Title, mediaPath)), false, null, default);
        await aliasStarted.Task.WaitAsync(TimeSpan.FromSeconds(5)); await service.ClearComments();
        try { await pending; throw new Exception("Pending load was not cancelled"); } catch (OperationCanceledException) { }
        var match = PlaybackSession.Require(core.Call("danmakuCache.episodeMatch", new { mediaID = "manual" }));
        Assert(service.UsedBytes == 0 && Json.Text(match, "payloadJSON").Contains("episodeID"), "danmaku clear drains pending loads and retains manual episode corrections");

        using var fixture = new StorageHttpFixture();
        var first = ImageDiskCache.Resolve(fixture.Url); var second = ImageDiskCache.Resolve(fixture.Url);
        await fixture.Started.Task.WaitAsync(TimeSpan.FromSeconds(5)); var clearing = ImageDiskCache.Clear();
        Assert(await ImageDiskCache.Resolve(fixture.Url) == fixture.Url, "new image cache requests bypass disk while a clear is in progress");
        fixture.Release.TrySetResult(); await clearing; await Task.WhenAll(first, second);
        Assert(fixture.Requests == 1 && ImageDiskCache.UsedBytes == 0, "image downloads are deduplicated and cannot write back after clear");
    }

    private sealed class StorageHttpFixture : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        public string Url { get; }
        public int Requests;
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public StorageHttpFixture()
        {
            _listener.Start(); var port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            Url = $"http://127.0.0.1:{port}/image.jpg";
            _ = Serve();
        }
        private async Task Serve()
        {
            try {
                using var client = await _listener.AcceptTcpClientAsync(); using var stream = client.GetStream();
                using var reader = new StreamReader(stream, System.Text.Encoding.ASCII, leaveOpen: true);
                while (await reader.ReadLineAsync() is { Length: > 0 }) { }
                Interlocked.Increment(ref Requests); Started.TrySetResult(); await Release.Task;
                await stream.WriteAsync(System.Text.Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n"));
                await stream.WriteAsync(new byte[] { 1, 2, 3, 4 });
            }
            catch (Exception ex) when (ex is IOException or SocketException or ObjectDisposedException) { }
        }
        public void Dispose() { Release.TrySetResult(); _listener.Stop(); }
    }
}

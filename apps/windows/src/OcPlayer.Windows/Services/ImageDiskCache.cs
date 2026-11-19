using System.Net.Http;
using System.Security.Cryptography;
using System.Text;

namespace OcPlayer.Windows.Services;

internal static class ImageDiskCache
{
    public const long CapacityBytes = 512L * 1024 * 1024;
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };
    private static readonly SemaphoreSlim Gate = new(6);
    private static readonly Dictionary<string, Lazy<Task<string>>> Inflight = [];
    private static readonly object Sync = new();
    private static bool _clearing;
    private static long _generation;
    public static string DirectoryPath => Path.Combine(AppPaths.DataDirectory, "Images");
    public static long UsedBytes { get { lock (Sync) return CacheFiles.UsedBytes(DirectoryPath, x => x.Extension == ".image"); } }
    public static void Maintain() { lock (Sync) CacheFiles.Prune(DirectoryPath, CapacityBytes, x => x.Extension == ".image", force: true); }
    public static async Task<string> Resolve(string url, CancellationToken token = default)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")) return url;
        var key = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(url)));
        var path = Path.Combine(DirectoryPath, key + ".image");
        Task<string> task;
        lock (Sync)
        {
            if (_clearing) return url;
            AppPaths.RejectReparsePoints(path, AppPaths.DataDirectory);
            if (File.Exists(path)) { File.SetLastWriteTimeUtc(path, DateTime.UtcNow); return path; }
            if (!Inflight.TryGetValue(path, out var pending))
            {
                var generation = _generation;
                pending = new Lazy<Task<string>>(() => Download(uri, path, generation)); Inflight.Add(path, pending);
            }
            task = pending.Value;
        }
        try { return await task.WaitAsync(token); }
        finally { lock (Sync) if (task.IsCompleted && Inflight.TryGetValue(path, out var current) && current.IsValueCreated && ReferenceEquals(current.Value, task)) Inflight.Remove(path); }
    }
    private static async Task<string> Download(Uri uri, string path, long generation)
    {
        await Gate.WaitAsync(); var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            if (File.Exists(path)) return path;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            request.Headers.TryAddWithoutValidation("User-Agent", RuntimeSettings.Current.EffectiveUserAgent);
            using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength > 32 * 1024 * 1024) throw new IOException("图片超出缓存单项限制。");
            await using (var source = await response.Content.ReadAsStreamAsync())
            await using (var destination = File.Create(temporary))
            {
                var buffer = new byte[64 * 1024]; long bytes = 0; int read;
                while ((read = await source.ReadAsync(buffer)) > 0) { bytes += read; if (bytes > 32 * 1024 * 1024) throw new IOException("图片超出缓存单项限制。"); await destination.WriteAsync(buffer.AsMemory(0, read)); }
            }
            lock (Sync)
            {
                if (generation != _generation) return uri.AbsoluteUri;
                File.Move(temporary, path, true);
                CacheFiles.Prune(Path.GetDirectoryName(path)!, CapacityBytes, x => x.Extension == ".image", protect: path);
                return path;
            }
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException or UnauthorizedAccessException or TaskCanceledException) { return uri.AbsoluteUri; }
        finally { try { if (File.Exists(temporary)) File.Delete(temporary); } finally { lock (Sync) Inflight.Remove(path); Gate.Release(); } }
    }
    public static async Task Clear()
    {
        Task<string>[] pending; var directory = DirectoryPath;
        lock (Sync)
        {
            if (_clearing) throw new InvalidOperationException("图片缓存正在清理。");
            _clearing = true; _generation++; pending = Inflight.Values.Select(x => x.Value).ToArray();
        }
        try
        {
            try { await Task.WhenAll(pending); } catch (Exception) { /* Failed downloads cannot prevent deletion. */ }
            lock (Sync) CacheFiles.Clear(directory, x => x.Extension == ".image");
        }
        finally { lock (Sync) _clearing = false; }
    }
}

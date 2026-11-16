using System.Collections.Concurrent;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;

namespace OcPlayer.Windows.Services;

internal static class ImageDiskCache
{
    public const long CapacityBytes = 512L * 1024 * 1024;
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };
    private static readonly SemaphoreSlim Gate = new(4);
    private static readonly ConcurrentDictionary<string, Task<string>> Inflight = new();
    private static long _generation;
    public static string DirectoryPath => Path.Combine(Environment.GetEnvironmentVariable("OCP_DATA_DIRECTORY") ??
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OcPlayer", "Windows"), "Images");
    public static long UsedBytes => Directory.Exists(DirectoryPath) ? Directory.EnumerateFiles(DirectoryPath, "*.image").Sum(path => { try { return new FileInfo(path).Length; } catch (IOException) { return 0; } }) : 0;
    public static async Task<string> Resolve(string url, CancellationToken token = default)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")) return url;
        var key = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(url)));
        var path = Path.Combine(DirectoryPath, key + ".image");
        if (File.Exists(path)) { File.SetLastWriteTimeUtc(path, DateTime.UtcNow); return path; }
        var task = Inflight.GetOrAdd(key, _ => Download(uri, path, Interlocked.Read(ref _generation)));
        try { return await task.WaitAsync(token); }
        finally { if (task.IsCompleted) Inflight.TryRemove(new KeyValuePair<string, Task<string>>(key, task)); }
    }
    private static async Task<string> Download(Uri uri, string path, long generation)
    {
        await Gate.WaitAsync(); var temporary = path + ".tmp";
        try
        {
            if (File.Exists(path)) return path;
            Directory.CreateDirectory(DirectoryPath);
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
            if (generation != Interlocked.Read(ref _generation)) return uri.AbsoluteUri;
            File.Move(temporary, path, true); Evict(); return path;
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException or TaskCanceledException) { return uri.AbsoluteUri; }
        finally { if (File.Exists(temporary)) File.Delete(temporary); Gate.Release(); }
    }
    private static void Evict()
    {
        var files = new DirectoryInfo(DirectoryPath).EnumerateFiles("*.image").OrderBy(x => x.LastWriteTimeUtc).ToArray();
        var bytes = files.Sum(x => x.Length);
        foreach (var file in files) { if (bytes <= CapacityBytes) break; try { var size = file.Length; file.Delete(); bytes -= size; } catch (IOException) { } }
    }
    public static async Task Clear()
    {
        Interlocked.Increment(ref _generation);
        await Task.WhenAll(Inflight.Values); // Prevent a completed in-flight request from repopulating after clear.
        if (Directory.Exists(DirectoryPath)) foreach (var path in Directory.EnumerateFiles(DirectoryPath, "*.image")) File.Delete(path);
    }
}

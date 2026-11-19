using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OcPlayer.Windows.Services;

// Cache only catalog metadata. Credentials and signed image parameters are never persisted.
internal sealed class BrowserCache(ServerProfile profile)
{
    public const long CapacityBytes = 128L * 1024 * 1024;
    public static string DirectoryPath => Path.Combine(AppPaths.DataDirectory, "browser-cache");
    private static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    private string ServerDirectory => Path.Combine(DirectoryPath, Hash(profile.Id));
    public long Revision { get { var state = CacheFiles.For(ServerDirectory); lock (state.Gate) return state.Generation; } }
    public static long UsedBytes => CacheFiles.UsedBytes(DirectoryPath, CacheFiles.HashedJson);
    private string FileName(string key)
    {
        return Path.Combine(ServerDirectory, Hash(profile.UserId ?? ""), Hash(key) + ".json");
    }
    public (T Value, DateTimeOffset SavedAt)? Read<T>(string key) where T : class
    {
        try
        {
            var path = FileName(key); AppPaths.RejectReparsePoints(path, DirectoryPath);
            var node = JsonNode.Parse(File.ReadAllText(path))!;
            var saved = node["savedAt"]!.GetValue<DateTimeOffset>();
            var value = Transform(node["value"], true)?.Deserialize<T>(MediaServer.JsonOptions);
            return value is null ? null : (value, saved);
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException or InvalidOperationException) { return null; }
    }
    public void Save<T>(string key, T value, long? revision = null)
    {
        try
        {
            var state = CacheFiles.For(ServerDirectory);
            lock (state.Gate)
            {
                if (revision is not null && revision != state.Generation) return;
                var path = FileName(key); AppPaths.RejectReparsePoints(path, DirectoryPath); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                var envelope = new JsonObject { ["savedAt"] = DateTimeOffset.UtcNow, ["value"] = Transform(JsonSerializer.SerializeToNode(value, MediaServer.JsonOptions), false) };
                var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                try { File.WriteAllText(temp, envelope.ToJsonString()); File.Move(temp, path, true); }
                finally { if (File.Exists(temp)) File.Delete(temp); }
                CacheFiles.Prune(DirectoryPath, CapacityBytes, CacheFiles.HashedJson, TimeSpan.FromDays(30), path);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { System.Diagnostics.Debug.WriteLine(ex.Message); }
    }
    public static void ClearServer(string serverId)
    {
        var directory = Path.Combine(DirectoryPath, Hash(serverId)); var state = CacheFiles.For(directory);
        lock (state.Gate) { state.Generation++; CacheFiles.Clear(directory, CacheFiles.HashedJson); }
    }
    public static void Maintain()
    {
        // Old flat cache files cannot be attributed to a server/account. They are
        // disposable and are invalidated once by the new scoped layout.
        AppPaths.RejectReparsePoints(DirectoryPath, AppPaths.DataDirectory);
        if (Directory.Exists(DirectoryPath))
            foreach (var file in new DirectoryInfo(DirectoryPath).EnumerateFiles("*.json"))
                if ((file.Attributes & FileAttributes.ReparsePoint) == 0) file.Delete();
        CacheFiles.Prune(DirectoryPath, CapacityBytes, CacheFiles.HashedJson, TimeSpan.FromDays(30), force: true);
    }
    private JsonNode? Transform(JsonNode? value, bool restore)
    {
        if (value is JsonObject obj)
        {
            foreach (var key in obj.Select(x => x.Key).ToArray()) obj[key] = Transform(obj[key]?.DeepClone(), restore);
        }
        else if (value is JsonArray array)
            for (var i = 0; i < array.Count; i++) array[i] = Transform(array[i]?.DeepClone(), restore);
        else if (value is JsonValue scalar && scalar.TryGetValue<string>(out var text)
            && Uri.TryCreate(text, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https")
        {
            var url = new UriBuilder(uri);
            var query = uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
                .Where(x => !new[] { "api_key", "token", "access_token", "x-emby-token" }.Contains(Uri.UnescapeDataString(x.Split('=')[0]), StringComparer.OrdinalIgnoreCase)).ToList();
            if (restore && !string.IsNullOrEmpty(profile.Token) && uri.AbsolutePath.Contains("/Images/", StringComparison.OrdinalIgnoreCase)
                && profile.AllAddresses.Any(x => text.StartsWith(x.TrimEnd('/') + "/", StringComparison.OrdinalIgnoreCase)))
                query.Add("api_key=" + Uri.EscapeDataString(profile.Token));
            url.Query = string.Join("&", query); return JsonValue.Create(url.Uri.AbsoluteUri);
        }
        return value;
    }
}

internal sealed record BrowserPage(OcPlayer.Windows.Preview.DemoMedia[] Items, int StartIndex, int? TotalCount, bool HasMore)
{
    public int NextIndex => StartIndex + Items.Length;
}

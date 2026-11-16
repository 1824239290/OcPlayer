using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace OcPlayer.Windows.Services;

// Cache only catalog metadata. Credentials and signed image parameters are never persisted.
internal sealed class BrowserCache(ServerProfile profile)
{
    private string FileName(string key)
    {
        var root = Environment.GetEnvironmentVariable("OCP_DATA_DIRECTORY") ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OcPlayer", "Windows");
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(profile.Id + ":" + profile.UserId + ":" + key)));
        return Path.Combine(root, "browser-cache", hash + ".json");
    }
    public (T Value, DateTimeOffset SavedAt)? Read<T>(string key) where T : class
    {
        try
        {
            var node = JsonNode.Parse(File.ReadAllText(FileName(key)))!;
            var saved = node["savedAt"]!.GetValue<DateTimeOffset>();
            var value = Transform(node["value"], true)?.Deserialize<T>(MediaServer.JsonOptions);
            return value is null ? null : (value, saved);
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException or InvalidOperationException) { return null; }
    }
    public void Save<T>(string key, T value)
    {
        try
        {
            var path = FileName(key); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var envelope = new JsonObject { ["savedAt"] = DateTimeOffset.UtcNow, ["value"] = Transform(JsonSerializer.SerializeToNode(value, MediaServer.JsonOptions), false) };
            var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllText(temp, envelope.ToJsonString()); File.Move(temp, path, true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { System.Diagnostics.Debug.WriteLine(ex.Message); }
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

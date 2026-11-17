using System.Net.Http;
using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OcPlayer.Windows.Services;

internal sealed record AppRelease(string Version, DateTimeOffset? PublishedAt, string Notes, string DownloadUrl)
{
    public bool IsNewer => AppReleaseService.CompareVersions(Version, AppReleaseService.Version) > 0;
}
internal static class AppReleaseService
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };
    public static string Version => typeof(AppReleaseService).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? typeof(AppReleaseService).Assembly.GetName().Version?.ToString() ?? "0.0.0";
    public static string Build => typeof(AppReleaseService).Assembly.GetName().Version?.ToString() ?? "未知";
    public static string DisplayVersion => $"v{Version} · Build {Build}";
    private static string StatePath => Path.Combine(AppPaths.DataDirectory, "ignored-release.txt");
    public static string? IgnoredVersion { get { try { return File.Exists(StatePath) ? File.ReadAllText(StatePath).Trim() : null; } catch (IOException) { return null; } } }
    public static AppRelease? Latest { get; private set; }
    public static void Ignore(string version) { Directory.CreateDirectory(Path.GetDirectoryName(StatePath)!); File.WriteAllText(StatePath, version); }
    public static async Task<AppRelease?> Check(CancellationToken token = default)
    {
        string? feed = Environment.GetEnvironmentVariable("OCP_UPDATE_FEED") ?? "https://api.github.com/repos/1824239290/OcPlayer/releases?per_page=50";
        AppRelease? latest = null;
        var visited = new HashSet<string>(StringComparer.Ordinal);
        while (feed is not null)
        {
            if (!visited.Add(feed)) throw new InvalidOperationException("更新服务返回了重复的分页地址。");
            using var request = new HttpRequestMessage(HttpMethod.Get, feed); request.Headers.TryAddWithoutValidation("User-Agent", RuntimeSettings.Current.EffectiveUserAgent);
            using var response = await Http.SendAsync(request, token);
            if (response.StatusCode == System.Net.HttpStatusCode.NotFound) break;
            response.EnsureSuccessStatusCode(); using var document = JsonDocument.Parse(await response.Content.ReadAsStringAsync(token));
            var release = ParseRelease(document.RootElement);
            if (release is not null && (latest is null || CompareVersions(release.Version, latest.Version) > 0)) latest = release;
            string? next = null;
            if (response.Headers.TryGetValues("Link", out var links))
            {
                var match = Regex.Match(string.Join(",", links), @"<([^>]+)>;\s*rel=""next""");
                if (match.Success)
                {
                    var currentUri = new Uri(feed); var nextUri = new Uri(currentUri, match.Groups[1].Value);
                    if (nextUri.Scheme != currentUri.Scheme || nextUri.Authority != currentUri.Authority) throw new InvalidOperationException("更新服务返回了跨站分页地址。");
                    next = nextUri.AbsoluteUri;
                }
            }
            feed = next;
        }
        Latest = latest; return Latest;
    }
    private static AppRelease? ParseRelease(JsonElement data)
    {
        if (data.ValueKind == JsonValueKind.Array)
        {
            JsonElement? selected = null;
            foreach (var release in data.EnumerateArray())
            {
                if (release.ValueKind != JsonValueKind.Object || !Json.Text(release, "tag_name").StartsWith("windows/v", StringComparison.Ordinal) ||
                    release.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True ||
                    release.TryGetProperty("prerelease", out var prerelease) && prerelease.ValueKind == JsonValueKind.True) continue;
                if (selected is null || CompareVersions(Json.Text(release, "tag_name"), Json.Text(selected.Value, "tag_name")) > 0) selected = release;
            }
            if (selected is null) return null;
            data = selected.Value;
        }
        var url = Json.Text(data, "html_url");
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme is not ("https" or "http")) throw new InvalidOperationException("更新服务返回了无效的下载地址。");
        return new(NormalizeTag(Json.Text(data, "tag_name")), DateTimeOffset.TryParse(Json.Text(data, "published_at"), out var date) ? date : null, Json.Text(data, "body"), uri.AbsoluteUri);
    }
    private static string NormalizeTag(string value) => value.StartsWith("windows/", StringComparison.Ordinal) ? value["windows/".Length..] : value;
    internal static int CompareVersions(string a, string b)
    {
        static (int[] Numbers, string Suffix) Parse(string value)
        {
            value = NormalizeTag(value).TrimStart('v', 'V').Split('+')[0]; var parts = value.Split('-', 2);
            return (parts[0].Split('.').Select(x => int.TryParse(x, out var n) ? n : 0).ToArray(), parts.Length > 1 ? parts[1] : "");
        }
        var left = Parse(a); var right = Parse(b);
        for (var i = 0; i < Math.Max(left.Numbers.Length, right.Numbers.Length); i++) { var cmp = (i < left.Numbers.Length ? left.Numbers[i] : 0).CompareTo(i < right.Numbers.Length ? right.Numbers[i] : 0); if (cmp != 0) return cmp; }
        if (left.Suffix.Length == 0 && right.Suffix.Length > 0) return 1;
        if (left.Suffix.Length > 0 && right.Suffix.Length == 0) return -1;
        return string.Compare(left.Suffix, right.Suffix, StringComparison.OrdinalIgnoreCase);
    }
}

using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using OcPlayer.CoreAdapter;

namespace OcPlayer.Windows.Services;

internal sealed record ServerSubtitle(string Key, string DisplayName, string? Language, string Extension, Uri DownloadUri);
internal sealed class ServerSubtitleException(string message) : InvalidOperationException(message);

internal sealed class ServerSubtitleService
{
    internal const int MaximumBytes = 32 * 1024 * 1024;
    public const long CapacityBytes = 128L * 1024 * 1024;
    public static string DirectoryPath => Path.Combine(AppPaths.DataDirectory, "SubtitleCache");
    private static bool CacheFile(FileInfo file) => file.Extension is ".srt" or ".ass" or ".ssa" or ".vtt";
    public static long UsedBytes => CacheFiles.UsedBytes(DirectoryPath, CacheFile);
    public static void Maintain() => CacheFiles.Prune(DirectoryPath, CapacityBytes, CacheFile, TimeSpan.FromDays(30));
    public static void Clear()
    {
        var state = CacheFiles.For(DirectoryPath);
        lock (state.Gate) { state.Generation++; CacheFiles.Clear(DirectoryPath, CacheFile); }
    }
    private static readonly HttpClient Client = new(new HttpClientHandler
    {
        AllowAutoRedirect = false,
        AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli
    }) { Timeout = Timeout.InfiniteTimeSpan };
    private readonly OcpCoreClient _core;
    private readonly PlaybackReport _report;
    private readonly ServerProfile _profile;
    private readonly Uri _baseUri;
    private readonly string _cacheDirectory;

    public ServerSubtitleService(OcpCoreClient core, PlaybackReport report, string dataDirectory)
    {
        _core = core;
        _report = report;
        _profile = report.Profile.Deserialize<ServerProfile>(MediaServer.JsonOptions)
            ?? throw new ServerSubtitleException("无法读取当前片源的服务器信息。");
        if (!Uri.TryCreate(_profile.BaseUrl.TrimEnd('/') + "/", UriKind.Absolute, out var baseUri)
            || baseUri.Scheme is not ("http" or "https") || baseUri.UserInfo.Length > 0
            || baseUri.Query.Length > 0 || baseUri.Fragment.Length > 0)
            throw new ServerSubtitleException("服务器字幕地址无效。");
        _baseUri = baseUri;
        _cacheDirectory = Path.Combine(dataDirectory, "SubtitleCache");
    }

    public async Task<ServerSubtitle[]> ListAsync(CancellationToken token)
    {
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(TimeSpan.FromSeconds(25));
        try
        {
            var response = await new MediaServer(_core, _profile).Request("media.subtitles",
                new { itemId = _report.ItemId, mediaSourceId = _report.MediaSourceId }, budget.Token).ConfigureAwait(false);
            if (!response.TryGetProperty("subtitles", out var subtitles) || subtitles.ValueKind != JsonValueKind.Array)
                throw new ServerSubtitleException("服务器返回的外挂字幕信息格式不正确。");
            var result = new List<ServerSubtitle>();
            foreach (var subtitle in subtitles.EnumerateArray())
            {
                if (subtitle.ValueKind != JsonValueKind.Object || !subtitle.TryGetProperty("index", out var indexValue)
                    || !indexValue.TryGetInt32(out var index) || index < 0) continue;
                var codec = Text(subtitle, "codec")?.ToLowerInvariant();
                var extension = codec switch { "srt" or "subrip" => "srt", "ass" => "ass", "ssa" => "ssa", "vtt" or "webvtt" => "vtt", _ => null };
                if (extension is null) continue;
                var sourceId = Text(subtitle, "mediaSourceId") ?? _report.MediaSourceId ?? _report.ItemId;
                if (_report.MediaSourceId is { Length: > 0 } expected && sourceId != expected) continue;
                var language = Text(subtitle, "language");
                var name = Text(subtitle, "title") ?? language?.ToLowerInvariant() ?? codec!.ToUpperInvariant();
                var route = $"Videos/{PathSegment(_report.ItemId)}/{PathSegment(sourceId)}/Subtitles/{index}/Stream.{extension}";
                var address = new Uri(_baseUri, route);
                var identity = JsonSerializer.Serialize(new[] { _baseUri.AbsoluteUri, _profile.Id, _profile.UserId ?? "", _report.ItemId, sourceId, index.ToString(System.Globalization.CultureInfo.InvariantCulture), extension });
                var key = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(identity)));
                result.Add(new(key, name, language, extension, address));
            }
            return result.DistinctBy(x => x.Key).ToArray();
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { throw new ServerSubtitleException("获取服务器字幕超时，请重试。"); }
        catch (OperationCanceledException) { throw; }
        catch (ServerSubtitleException) { throw; }
        catch (Exception)
        {
            // Core/server errors can contain authenticated request URLs. Keep them out of UI/log messages.
            throw new ServerSubtitleException("无法获取服务器外挂字幕，请检查连接后重试。");
        }
    }

    public async Task<string> DownloadAsync(ServerSubtitle subtitle, CancellationToken token)
    {
        var state = CacheFiles.For(_cacheDirectory); long generation;
        lock (state.Gate) generation = state.Generation;
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(TimeSpan.FromSeconds(30));
        string? temporary = null;
        try
        {
            if (subtitle.Key.Length != 64 || subtitle.Key.Any(character => !Uri.IsHexDigit(character))
                || subtitle.Extension is not ("srt" or "ass" or "ssa" or "vtt"))
                throw new ServerSubtitleException("服务器字幕缓存标识无效。");
            AppPaths.RejectReparsePoints(_cacheDirectory, Path.GetDirectoryName(_cacheDirectory)!);
            Directory.CreateDirectory(_cacheDirectory);
            var destination = Path.Combine(_cacheDirectory, subtitle.Key + "." + subtitle.Extension);
            var address = subtitle.DownloadUri;
            for (var redirect = 0; redirect <= 5; redirect++)
            {
                if (!SameOrigin(address, _baseUri) || address.UserInfo.Length > 0)
                    throw new ServerSubtitleException("服务器字幕下载发生跨站跳转，无法加载。");
                using var request = new HttpRequestMessage(HttpMethod.Get, address);
                request.Headers.TryAddWithoutValidation("Authorization", Authorization());
                request.Headers.TryAddWithoutValidation("X-Emby-Authorization", Authorization());
                using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, budget.Token).ConfigureAwait(false);
                if (response.StatusCode is HttpStatusCode.MovedPermanently or HttpStatusCode.Redirect or HttpStatusCode.SeeOther or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect)
                {
                    if (response.Headers.Location is not { } location)
                        throw new ServerSubtitleException("服务器字幕下载跳转无效。");
                    address = new Uri(address, location);
                    continue;
                }
                if (response.StatusCode != HttpStatusCode.OK)
                    throw new ServerSubtitleException($"服务器字幕下载失败（HTTP {(int)response.StatusCode}）。");
                if (response.Content.Headers.ContentLength is > MaximumBytes)
                    throw new ServerSubtitleException("外挂字幕超过 32 MiB，无法加载。");
                temporary = Path.Combine(_cacheDirectory, subtitle.Key + "." + Guid.NewGuid().ToString("N") + ".tmp");
                long total = 0;
                await using (var input = await response.Content.ReadAsStreamAsync(budget.Token).ConfigureAwait(false))
                await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, FileOptions.Asynchronous))
                {
                    var buffer = new byte[65536];
                    while (true)
                    {
                        var remaining = (int)Math.Min(buffer.Length, MaximumBytes - total + 1);
                        var count = await input.ReadAsync(buffer.AsMemory(0, remaining), budget.Token).ConfigureAwait(false);
                        if (count == 0) break;
                        total += count;
                        if (total > MaximumBytes) throw new ServerSubtitleException("外挂字幕超过 32 MiB，无法加载。");
                        await output.WriteAsync(buffer.AsMemory(0, count), budget.Token).ConfigureAwait(false);
                    }
                }
                if (total == 0) throw new ServerSubtitleException("服务器返回了空字幕文件。");
                budget.Token.ThrowIfCancellationRequested();
                lock (state.Gate)
                {
                    if (generation != state.Generation) throw new ServerSubtitleException("字幕缓存已清空，请重新加载字幕。");
                    File.Move(temporary, destination, true); temporary = null;
                    CacheFiles.Prune(_cacheDirectory, CapacityBytes, CacheFile, TimeSpan.FromDays(30), destination);
                }
                return destination;
            }
            throw new ServerSubtitleException("服务器字幕下载跳转次数过多。");
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { throw new ServerSubtitleException("服务器字幕下载超时，请重试。"); }
        catch (OperationCanceledException) { throw; }
        catch (ServerSubtitleException) { throw; }
        catch (Exception ex) when (ex is HttpRequestException or IOException or UnauthorizedAccessException or UriFormatException)
        { throw new ServerSubtitleException("无法下载服务器字幕，请检查网络及缓存目录后重试。"); }
        finally
        {
            if (temporary is not null)
                try { File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private string Authorization()
    {
        static string Clean(string? value) => (value ?? "").Replace("\"", "").Replace("\r", "").Replace("\n", "");
        var scheme = _profile.Kind == "emby" ? "Emby" : "MediaBrowser";
        return $"{scheme} Client=\"OcPlayer\", Device=\"Windows\", DeviceId=\"ocplayer-windows\", Version=\"1.0\", UserId=\"{Clean(_profile.UserId)}\", Token=\"{Clean(_profile.Token)}\"";
    }

    private static bool SameOrigin(Uri first, Uri second) => first.Scheme.Equals(second.Scheme, StringComparison.OrdinalIgnoreCase)
        && first.Host.Equals(second.Host, StringComparison.OrdinalIgnoreCase) && first.Port == second.Port;
    private static string PathSegment(string value) => value is "." or ".." or ""
        ? throw new ServerSubtitleException("服务器字幕条目标识无效。") : Uri.EscapeDataString(value);
    private static string? Text(JsonElement value, string key) => value.TryGetProperty(key, out var text)
        && text.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(text.GetString()) ? text.GetString()!.Trim() : null;
}

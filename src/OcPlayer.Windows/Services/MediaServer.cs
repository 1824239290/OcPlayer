using System.Text.Json;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Preview;

namespace OcPlayer.Windows.Services;

internal sealed record ServerProfile(string Id, string Kind, string BaseUrl, string? UserId = null, string? Token = null,
    string? ServerName = null, string? ServerVersion = null, string? UserName = null, string? ResolvedServerId = null,
    string[]? Addresses = null, string? PinnedAddress = null, string? UserAgent = null)
{
    public string[] AllAddresses => (Addresses ?? []).Append(BaseUrl).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
    public string DisplayName => string.IsNullOrWhiteSpace(ServerName) ? new Uri(BaseUrl).Authority : ServerName;
    public string DisplayKind => Kind == "emby" ? "Emby" : "Jellyfin";
}
internal sealed record MediaLibrary(string Id, string Name, string Artwork, string CollectionType = "", string[]? CoverPosters = null)
{
    public string DisplayType => CollectionType.ToLowerInvariant() switch
    {
        "movies" => "电影", "tvshows" => "剧集", "music" => "音乐", "musicvideos" => "MV",
        "homevideos" => "家庭视频", "boxsets" => "合集", "books" => "书籍", "photos" => "照片",
        "playlists" => "播放列表", "livetv" => "直播电视", _ => "混合内容"
    };
}
internal class ServerConnectionException(string message) : InvalidOperationException(message);
internal sealed class ServerAuthenticationException(string message) : ServerConnectionException(message);
internal sealed record EndpointStatus(string Address, long? LatencyMs, string? Error = null);

internal sealed class MediaServer(OcpCoreClient core, ServerProfile profile)
{
    internal static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    public ServerProfile Profile { get; private set; } = profile;
    public event Action<MediaServer>? AuthenticationExpired;
    public event Action<ServerProfile>? ProfileChanged;
    private BrowserCache _cache => new(Profile);
    public DateTimeOffset? HomeUpdatedAt { get; private set; }
    public string? UserAvatarUrl { get; private set; }
    private DateTimeOffset _lastEndpointCheck;
    private readonly SemaphoreSlim _endpointLock = new(1);
    public List<MediaLibrary> Libraries { get; } = [];
    public List<DemoMedia> Latest { get; } = [];
    public List<DemoMedia> Resume { get; } = [];
    public List<DemoMedia> NextUp { get; } = [];
    public string? HomeWarning { get; private set; }

    public static async Task<ServerProfile> Probe(OcpCoreClient client, string address, string kind, CancellationToken token)
    {
        address = NormalizeAddress(address);
        var candidate = new ServerProfile(Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(address))), kind, address,
            UserAgent: RuntimeSettings.Current.EffectiveUserAgent);
        var info = Require(await client.CallJSONAsync("server.probe", JsonSerializer.Serialize(new { profile = candidate }, JsonOptions), token), token);
        var product = NullableString(info, "productName") ?? "";
        return candidate with { Kind = product.Contains("Emby", StringComparison.OrdinalIgnoreCase) ? "emby" : product.Contains("Jellyfin", StringComparison.OrdinalIgnoreCase) ? "jellyfin" : kind,
            ServerName = NullableString(info, "serverName"), ServerVersion = NullableString(info, "version"), ResolvedServerId = NullableString(info, "id") };
    }
    public async Task<EndpointStatus[]> CheckEndpoints(CancellationToken token)
    {
        return await Task.WhenAll(Profile.AllAddresses.Select(async address =>
        {
            var watch = System.Diagnostics.Stopwatch.StartNew();
            try
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token); timeout.CancelAfter(TimeSpan.FromSeconds(8));
                var found = await Probe(core, address, Profile.Kind, timeout.Token);
                if (Profile.ResolvedServerId is { Length: > 0 } id && found.ResolvedServerId != id)
                    return new EndpointStatus(address, null, "地址属于另一台服务器");
                return new EndpointStatus(address, watch.ElapsedMilliseconds);
            }
            catch (OperationCanceledException) when (!token.IsCancellationRequested) { return new EndpointStatus(address, null, "超时"); }
            catch (ServerConnectionException ex) { return new EndpointStatus(address, null, ex.Message); }
        }));
    }
    public async Task SelectEndpoint(CancellationToken token, string? exclude = null)
    {
        await _endpointLock.WaitAsync(token);
        try
        {
            if (Profile.PinnedAddress is { } pinned) { UpdateProfile(Profile with { BaseUrl = pinned }); return; }
            var best = (await CheckEndpoints(token)).Where(x => x.Address != exclude && x.LatencyMs is not null).OrderBy(x => x.LatencyMs).FirstOrDefault();
            _lastEndpointCheck = DateTimeOffset.UtcNow;
            if (best is not null) UpdateProfile(Profile with { Addresses = Profile.AllAddresses, BaseUrl = best.Address });
        }
        finally { _endpointLock.Release(); }
    }
    public void UpdateProfile(ServerProfile value) { Profile = value; ProfileChanged?.Invoke(value); }
    public async Task RefreshAvatar(CancellationToken token)
    {
        var info = await Request("server.avatarTag", token: token);
        var tag = NullableString(info, "tag");
        if (tag is null) { UserAvatarUrl = null; return; }
        var result = await Request("server.userImageURL", new { tag }, token);
        var url = NullableString(result, "url");
        UserAvatarUrl = url is null ? null : url + (url.Contains('?') ? "&" : "?") + "api_key=" + Uri.EscapeDataString(Profile.Token ?? "");
    }
    public bool RestoreHome()
    {
        if (_cache.Read<HomeSnapshot>("home") is not { } cached) return false;
        ApplyHome(cached.Value); HomeUpdatedAt = cached.SavedAt; HomeWarning = $"正在显示缓存内容 · 更新于 {cached.SavedAt.LocalDateTime:g}"; return true;
    }
    private sealed record HomeSnapshot(MediaLibrary[] Libraries, DemoMedia[] Latest, DemoMedia[] Resume, DemoMedia[] NextUp);
    private void ApplyHome(HomeSnapshot value)
    {
        Libraries.Clear(); Libraries.AddRange(value.Libraries); Latest.Clear(); Latest.AddRange(value.Latest);
        Resume.Clear(); Resume.AddRange(value.Resume); NextUp.Clear(); NextUp.AddRange(value.NextUp);
    }
    public void HomeRefreshFailed(string error) => HomeWarning = error + (HomeUpdatedAt is { } time ? $" · 显示缓存内容，更新于 {time.LocalDateTime:g}" : "");

    public static string NormalizeAddress(string address)
    {
        address = address.Trim();
        if (address.Length == 0) throw new ArgumentException("请输入服务器地址。");
        if (!address.Contains("://", StringComparison.Ordinal)) address = "http://" + address;
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") || string.IsNullOrEmpty(uri.Host))
            throw new ArgumentException("请输入有效的 HTTP 或 HTTPS 服务器地址。");
        if (!string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
            throw new ArgumentException("请填写服务器根地址（可包含反向代理路径），不要包含账号、查询参数或 # 片段。");
        return uri.AbsoluteUri.TrimEnd('/');
    }

    public static async Task<MediaServer> Connect(OcpCoreClient core, string address, string kind, string username, string password,
        CancellationToken token, Action<string>? status = null)
    {
        address = NormalizeAddress(address);
        status?.Invoke("正在检测服务器…");
        ServerProfile detected;
        try { detected = await Probe(core, address, kind, token); }
        catch (ServerConnectionException)
        { detected = new ServerProfile("", kind, address); status?.Invoke("公共探测不可用，尝试按所选类型验证账号…"); }
        status?.Invoke("正在验证账号…");
        var profile = await Login(core, address, detected.Kind, username, password, token);
        profile = profile with { ServerName = detected.ServerName, ServerVersion = detected.ServerVersion, ResolvedServerId = detected.ResolvedServerId };
        var server = new MediaServer(core, profile);
        status?.Invoke("正在读取媒体库…");
        // browse.home returns success even when individual endpoints fail.
        // A libraries failure must not activate an unusable account.
        await server.Refresh(token);
        status?.Invoke("正在读取服务器信息…");
        try
        {
            var info = await server.Request("server.probe", token: token);
            profile = profile with { ServerName = NullableString(info, "serverName"), ServerVersion = NullableString(info, "version"), ResolvedServerId = NullableString(info, "id") };
        }
        catch (ServerConnectionException) { /* Some proxies deny the public info endpoint; the authenticated library is already verified. */ }
        token.ThrowIfCancellationRequested();
        // Copy the verified catalog without a second network load.
        return new MediaServer(core, profile) { HomeWarning = server.HomeWarning, HomeUpdatedAt = server.HomeUpdatedAt, UserAvatarUrl = server.UserAvatarUrl }.CopyCatalog(server);
    }

    private MediaServer CopyCatalog(MediaServer source)
    {
        Libraries.AddRange(source.Libraries); Latest.AddRange(source.Latest); Resume.AddRange(source.Resume); NextUp.AddRange(source.NextUp);
        return this;
    }

    public static async Task<ServerProfile> Login(OcpCoreClient core, string address, string kind, string username, string password, CancellationToken token)
    {
        address = NormalizeAddress(address);
        if (kind is not ("jellyfin" or "emby")) throw new ArgumentException("请选择 Jellyfin 或 Emby。");
        if (string.IsNullOrWhiteSpace(username)) throw new ArgumentException("请输入用户名。");
        var profile = new ServerProfile(Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(address))), kind, address);
        var arguments = JsonSerializer.Serialize(new { profile, username, password }, JsonOptions);
        var data = Require(await core.CallJSONAsync("server.login", arguments, token), token);
        var userId = data.GetProperty("userId").GetString();
        return profile with { Id = profile.Id + ":" + userId, Token = data.GetProperty("token").GetString(), UserId = userId, UserName = NullableString(data, "userName") ?? username };
    }

    public async Task<JsonElement> Request(string method, object? arguments = null, CancellationToken token = default)
    {
        if (Profile.PinnedAddress is null && Profile.AllAddresses.Length > 1 && DateTimeOffset.UtcNow - _lastEndpointCheck > TimeSpan.FromMinutes(1))
            await SelectEndpoint(token);
        var node = System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(arguments ?? new { }, JsonOptions))!.AsObject();
        node["profile"] = System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(Profile with { UserAgent = RuntimeSettings.Current.EffectiveUserAgent }, JsonOptions));
        var response = await core.CallJSONAsync(method, node.ToJsonString(), token);
        if (!response.Ok && response.Code is 1521 or 1522 or 1523 && Profile.PinnedAddress is null && Profile.AllAddresses.Length > 1
            && (method.StartsWith("browse.") || method is "playback.info" or "media.fileInfo" or "server.avatarTag"))
        {
            var failed = Profile.BaseUrl;
            await SelectEndpoint(token, failed);
            if (Profile.BaseUrl != failed)
            {
                node["profile"] = System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(Profile with { UserAgent = RuntimeSettings.Current.EffectiveUserAgent }, JsonOptions));
                response = await core.CallJSONAsync(method, node.ToJsonString(), token);
            }
        }
        if (!response.Ok && response.Code == 2001 && !string.IsNullOrEmpty(Profile.Token)) AuthenticationExpired?.Invoke(this);
        return Require(response, token);
    }

    private static JsonElement Require(OcpResponse response, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (response.Ok) return response.Data;
        var message = response.Code switch
        {
            2001 or 2003 => "账号验证失败，请检查用户名、密码和账号权限。",
            1521 => "服务器响应超时，请检查网络后重试。",
            1522 or 1523 => "无法连接服务器，请检查地址、端口和网络。",
            2004 or 1514 => "服务器地址没有返回有效的媒体服务，请检查地址和反向代理路径。",
            _ => "服务器请求失败：" + response.Message
        };
        if (response.Code is 2001 or 2003) throw new ServerAuthenticationException(message);
        throw new ServerConnectionException(message);
    }

    public async Task Refresh(CancellationToken token)
    {
        var home = await Request("browse.home", token: token);
        var failures = home.TryGetProperty("failures", out var failed) && failed.ValueKind == JsonValueKind.Object ? failed.EnumerateObject().ToArray() : [];
        if (failed.ValueKind == JsonValueKind.Object && failed.TryGetProperty("libraries", out var libraryFailure) && Libraries.Count == 0)
            throw new ServerConnectionException("无法读取媒体库，请检查账号权限或重新登录。" + libraryFailure);
        var libraries = home.GetProperty("libraries").EnumerateArray().Select(library =>
        {
            var id = String(library, "id");
            return new MediaLibrary(id, String(library, "name"), Image(id, "Primary", NullableString(library, "primaryImageTag")), String(library, "collectionType"));
        }).ToArray();
        DemoMedia[] Section(string key) => home.GetProperty(key) is { ValueKind: JsonValueKind.Array } items ? items.EnumerateArray().Select(Project).ToArray() : [];
        var latest = Section("latest");
        var resume = Section("resume");
        var next = Section("nextUp");
        // Match macOS: only supplement libraries without their own Primary image.
        // Keep lookup bounded to two libraries, twelve entries and four collections.
        using var coverSlots = new SemaphoreSlim(2);
        libraries = await Task.WhenAll(libraries.Select(async library =>
        {
            if (library.Artwork.Length > 0) return library;
            await coverSlots.WaitAsync(token);
            try { return library with { CoverPosters = await LibraryCoverPosters(library, token) }; }
            catch (ServerConnectionException) { return library; } // Optional artwork retries on the next refresh.
            finally { coverSlots.Release(); }
        }));
        token.ThrowIfCancellationRequested();
        bool Failed(string key) => failures.Any(x => x.Name == key);
        if (!Failed("libraries")) { Libraries.Clear(); Libraries.AddRange(libraries); }
        if (!Failed("latest")) { Latest.Clear(); Latest.AddRange(latest); }
        if (!Failed("resume")) { Resume.Clear(); Resume.AddRange(resume); }
        if (!Failed("nextUp")) { NextUp.Clear(); NextUp.AddRange(next); }
        NextUp.RemoveAll(x => Resume.Any(y => y.Id == x.Id));
        HomeUpdatedAt = DateTimeOffset.UtcNow;
        _cache.Save("home", new HomeSnapshot(Libraries.ToArray(), Latest.ToArray(), Resume.ToArray(), NextUp.ToArray()));
        try { await RefreshAvatar(token); } catch (ServerConnectionException) { }
        HomeWarning = failures.Length > 0 ? "部分首页栏目加载失败（" + string.Join("、", failures.Select(x => x.Name switch { "resume" => "继续观看", "latest" => "最近添加", "nextUp" => "接下来看", _ => x.Name })) + "），可点击刷新重试。" : null;
    }

    private async Task<string[]> LibraryCoverPosters(MediaLibrary library, CancellationToken token)
    {
        async Task<JsonElement[]> Items(string parentId, int limit, bool recursive)
        {
            var page = await Request("browse.library", new { parentId, startIndex = 0, limit, recursive,
                sort = new { field = "name", ascending = true } }, token);
            return page.GetProperty("items").EnumerateArray().ToArray();
        }
        string[] Posters(IEnumerable<JsonElement> items) => items
            .Select(item => Image(String(item, "id"), "Primary", NullableString(item, "primaryImageTag")))
            .Where(url => url.Length > 0).Select(url => ResizeImage(url, 720)).Take(4).ToArray();

        var top = await Items(library.Id, 12, true);
        if (!library.CollectionType.Equals("boxsets", StringComparison.OrdinalIgnoreCase)) return Posters(top);

        // Collections often have no image themselves. Take turns across their
        // members so the collage represents several collections, as on macOS.
        var collections = new List<string[]>();
        foreach (var collection in top.Where(item => String(item, "kind") == "boxSet").Take(4))
        {
            try { collections.Add(Posters((await Items(String(collection, "id"), 4, false)).Take(4))); }
            catch (ServerConnectionException) { /* Still use the other collections' posters. */ }
        }
        var posters = new List<string>();
        for (var index = 0; index < 4 && posters.Count < 4; index++)
            foreach (var collection in collections.Where(x => x.Length > index))
            {
                posters.Add(collection[index]);
                if (posters.Count == 4) break;
            }
        return posters.ToArray();
    }

    public async Task<DemoMedia[]> Browse(string? libraryId, string query, LibrarySortSettings settings, CancellationToken token)
    {
        return (await BrowsePage(libraryId, query, settings, 0, token)).Items;
    }
    private static string BrowseKey(string? libraryId, string query, LibrarySortSettings settings) => "browse:" + JsonSerializer.Serialize(new { libraryId, query, settings });
    public (BrowserPage Value, DateTimeOffset SavedAt)? CachedBrowse(string? libraryId, string query, LibrarySortSettings settings) => _cache.Read<BrowserPage>(BrowseKey(libraryId, query, settings));
    public void CacheBrowse(string? libraryId, string query, LibrarySortSettings settings, BrowserPage page) => _cache.Save(BrowseKey(libraryId, query, settings), page);
    public async Task<BrowserPage> BrowsePage(string? libraryId, string query, LibrarySortSettings settings, int start, CancellationToken token, bool collection = false)
    {
        const int limit = 60;
        var type = Libraries.FirstOrDefault(x => x.Id == libraryId)?.CollectionType;
        string[] kinds = collection ? [] : type switch { "movies" => ["movie"], "tvshows" => ["series"], _ => libraryId is null ? ["movie", "series"] : [] };
        var page = await Request("browse.library", new { parentId = libraryId, searchTerm = query,
            startIndex = start, limit, recursive = !collection, kinds,
            sort = new { field = settings.Field, ascending = settings.Ascending },
            watchState = settings.WatchState }, token);
        var items = page.GetProperty("items").EnumerateArray().Select(Project).ToArray();
        int? total = page.TryGetProperty("totalRecordCount", out var count) && count.ValueKind == JsonValueKind.Number ? count.GetInt32() : null;
        return new BrowserPage(items, start, total, items.Length > 0 && (total is { } n ? start + items.Length < n : items.Length == limit));
    }

    public async Task<DemoMedia[]> RandomBackdrops(CancellationToken token)
    {
        var page = await Request("browse.library", new { startIndex = 0, limit = 24, recursive = true,
            kinds = new[] { "movie", "series" }, sort = new { field = "random", ascending = true }, watchState = "all" }, token);
        return page.GetProperty("items").EnumerateArray().Select(Project).Where(x => x.BackdropArtwork.Length > 0).ToArray();
    }

    internal static string AmbientImage(string source)
        => ResizeImage(source, 800);

    internal static string DetailImage(string source)
        => ResizeImage(source, 1600);

    private static string ResizeImage(string source, int width)
    {
        if (!Uri.TryCreate(source, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")) return source;
        var builder = new UriBuilder(uri);
        var query = builder.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries)
            .Where(x => !x.Split('=', 2)[0].Equals("maxWidth", StringComparison.OrdinalIgnoreCase));
        builder.Query = string.Join("&", query.Append("maxWidth=" + width));
        return builder.Uri.AbsoluteUri;
    }

    public DemoMedia? CachedDetail(DemoMedia media, string? seasonId = null) => _cache.Read<DemoMedia>("detail:" + media.Id + ":" + seasonId)?.Value;
    public async Task<DemoMedia> Detail(DemoMedia media, CancellationToken token, string? seasonId = null)
    {
        var key = "detail:" + media.Id + ":" + seasonId;
        try
        {
            var value = await FetchDetail(media, token, seasonId); _cache.Save(key, value); return value;
        }
        catch (ServerConnectionException ex) when (ex is not ServerAuthenticationException)
        {
            if (_cache.Read<DemoMedia>(key) is { } cached) return cached.Value with { DetailWarning = $"更新失败：{ex.Message} · 显示 {cached.SavedAt.LocalDateTime:g} 的缓存" };
            throw;
        }
    }
    private async Task<DemoMedia> FetchDetail(DemoMedia media, CancellationToken token, string? seasonId)
    {
        var detail = await Request("browse.detail", new { itemId = media.Id }, token);
        var projected = Project(detail);
        var entry = projected;
        if (entry.Kind is "episode" or "season")
        {
            var seriesId = entry.SeriesId ?? media.SeriesId;
            if (string.IsNullOrEmpty(seriesId)) throw new InvalidOperationException("服务器未返回此条目所属的剧集，无法加载剧集详情。");
            seasonId ??= entry.Kind == "season" ? entry.Id : entry.SeasonId ?? media.SeasonId;
            projected = Project(await Request("browse.detail", new { itemId = seriesId }, token));
        }
        if (projected.Kind == "series")
        {
            var seasons = await Request("browse.seasons", new { seriesId = projected.Id, limit = 500 }, token);
            var choices = seasons.EnumerateArray().Select(item => new DemoSeason(String(item, "id"), String(item, "name"),
                item.TryGetProperty("seasonNumber", out var number) && number.ValueKind == JsonValueKind.Number ? number.GetInt32() : null,
                String(item, "overview"), Project(item).IsPlayed,
                item.TryGetProperty("playState", out var state) && state.ValueKind == JsonValueKind.Object && state.TryGetProperty("unplayedCount", out var unplayed) && unplayed.ValueKind == JsonValueKind.Number ? unplayed.GetInt32() : null)).ToArray();
            if (seasonId is null && entry.Kind == "episode")
                seasonId = choices.FirstOrDefault(x => x.Number == (entry.SeasonNumber ?? media.SeasonNumber))?.Id;
            var preferred = Resume.Concat(NextUp).FirstOrDefault(x => x.SeriesId == projected.Id && (seasonId is null || x.SeasonId == seasonId));
            seasonId ??= preferred?.SeasonId ?? choices.FirstOrDefault(x => x.Number == preferred?.SeasonNumber)?.Id;
            seasonId ??= choices.Where(x => x.Number != 0).FirstOrDefault(x => !x.Played && x.UnplayedCount != 0)?.Id
                ?? choices.FirstOrDefault(x => x.Number != 0)?.Id ?? choices.FirstOrDefault()?.Id;
            var rawEpisodes = new List<JsonElement>();
            while (true)
            {
                var batch = await Request("browse.episodes", new { seriesId = projected.Id, seasonId, startIndex = rawEpisodes.Count, limit = 500 }, token);
                var batchItems = batch.EnumerateArray().ToArray();
                if (batchItems.Length == 0 || batchItems.All(x => rawEpisodes.Any(y => String(x, "id") == String(y, "id")))) break;
                rawEpisodes.AddRange(batchItems); if (batchItems.Length < 500) break;
            }
            var items = rawEpisodes.Select(item =>
            {
                var episode = Project(item);
                return new DemoEpisode(episode.EpisodeNumber ?? 0, episode.Title, episode.StillArtwork.Length > 0 ? episode.StillArtwork : episode.Artwork,
                    MediaId: episode.Id, SeasonNumber: episode.SeasonNumber ?? 1,
                    Progress: episode.Progress, DurationSeconds: episode.DurationSeconds, Played: episode.Played, Overview: episode.Description);
            }).OrderBy(x => x.Number).ToArray();
            // Match the server identity first: episode numbers can repeat across seasons.
            var selected = entry.Kind == "episode" ? items.FirstOrDefault(x => x.MediaId == entry.Id) : null;
            if (entry.Kind == "episode" && selected is null)
                throw new InvalidOperationException("此集不在服务器返回的季中，请刷新后重试。");
            if (selected is not null && entry.Kind == "episode")
            {
                var index = Array.IndexOf(items, selected);
                selected = selected with { Progress = entry.Progress, Played = entry.Played,
                    DurationSeconds = entry.DurationSeconds > 0 ? entry.DurationSeconds : selected.DurationSeconds };
                items[index] = selected;
            }
            selected ??= items.FirstOrDefault(x => x.MediaId == preferred?.Id) ?? items.FirstOrDefault(x => x.Progress is > 0 and < 100)
                ?? items.FirstOrDefault(x => !x.IsPlayed) ?? items.FirstOrDefault();
            projected = projected with { Seasons = choices, SelectedSeasonId = seasonId, Episodes = items,
                SeasonNumber = choices.FirstOrDefault(x => x.Id == seasonId)?.Number,
                DurationSeconds = selected is { DurationSeconds: > 0 } ? selected.DurationSeconds : projected.DurationSeconds,
                EpisodeNumber = selected?.Number, EpisodeLabel = selected is null ? null : $"S{selected.SeasonNumber}E{selected.Number}",
                SeasonOverview = choices.FirstOrDefault(x => x.Id == seasonId)?.Overview };
        }
        if (projected.Kind == "boxSet")
        {
            var members = await BrowsePage(projected.Id, "", new LibrarySortSettings(), 0, token, collection: true);
            projected = projected with { Members = members.Items, MemberCount = members.TotalCount };
        }
        else try
        {
            var similar = await Request("browse.similar", new { itemId = projected.Id, limit = 12 }, token);
            projected = projected with { Similar = similar.GetProperty("items").EnumerateArray().Select(Project).ToArray() };
        }
        catch (ServerConnectionException ex) when (ex is not ServerAuthenticationException) { projected = projected with { DetailWarning = "类似推荐加载失败，可刷新重试。" }; }
        return projected;
    }

    public async Task<DemoEpisode> SetEpisodeWatched(DemoEpisode episode, bool watched, CancellationToken token)
    {
        if (!episode.Available || string.IsNullOrEmpty(episode.MediaId))
            throw new InvalidOperationException("此集尚未入库，无法更新观看状态。");
        await Request(watched ? "server.markPlayed" : "server.markUnplayed", new { itemId = episode.MediaId }, token);
        return episode with { Progress = watched ? 100 : 0, Played = watched };
    }

    public async Task<PlaybackSource> Resolve(DemoMedia media, int episode, CancellationToken token, int attempt = 0)
    {
        var id = media.Kind == "series" ? media.Episodes?.FirstOrDefault(x => x.Number == episode)?.MediaId : media.Id;
        if (string.IsNullOrEmpty(id)) throw new InvalidOperationException("没有可播放的分集。");
        // Resume belongs to the selected episode, never to the series or another season.
        var playbackMedia = media.Kind == "series" ? Project(await Request("browse.detail", new { itemId = id }, token)) : media;
        var series = media.Kind == "series" ? media : null;
        if (series is null && playbackMedia.Kind == "episode" && !string.IsNullOrEmpty(playbackMedia.SeriesId))
        {
            try { series = Project(await Request("browse.detail", new { itemId = playbackMedia.SeriesId }, token)); }
            catch (InvalidOperationException) { /* Optional series identity must not prevent playback. */ }
        }
        JsonElement info;
        try { info = await Request("playback.info", new { itemId = id }, token); }
        catch (ServerConnectionException ex) when (ex is not ServerAuthenticationException)
        { info = JsonSerializer.SerializeToElement(new { mediaSources = new[] { new { id = (string?)null } }, playSessionId = (string?)null }); }
        var sources = info.GetProperty("mediaSources").EnumerateArray().OrderByDescending(x =>
            x.TryGetProperty("supportsDirectPlay", out var direct) && direct.ValueKind == JsonValueKind.True ? 2 :
            x.TryGetProperty("supportsDirectStream", out var stream) && stream.ValueKind == JsonValueKind.True ? 1 : 0).ToArray();
        if (sources.Length == 0) sources = [JsonSerializer.SerializeToElement(new { id = (string?)null })];
        if (attempt >= sources.Length) throw new InvalidOperationException("已尝试全部可用媒体源，请检查网络或重试。");
        var source = sources[attempt];
        var sourceId = NullableString(source, "id"); var sessionId = NullableString(info, "playSessionId");
        var url = await Request("server.streamURL", new { itemId = id, mediaSourceId = sourceId, playSessionId = sessionId }, token);
        return new PlaybackSource(id, media.Title, url.GetProperty("url").GetString()!, Profile.Id + ":" + Profile.UserId,
            playbackMedia.Progress >= 100 ? 0 : playbackMedia.DurationSeconds * playbackMedia.Progress / 100,
            HttpHeaders: new Dictionary<string, string> { ["User-Agent"] = RuntimeSettings.Current.EffectiveUserAgent },
            Report: new PlaybackReport(JsonSerializer.SerializeToElement(Profile, JsonOptions), id, sourceId, sessionId),
            Metadata: new PlaybackMetadata(NullableString(source, "path") ?? NullableString(source, "name") ?? playbackMedia.Title,
                source.TryGetProperty("size", out var size) && size.TryGetInt64Safe(out var bytes) ? bytes : null,
                Number(source, "runTimeSeconds") > 0 ? Number(source, "runTimeSeconds") : playbackMedia.DurationSeconds,
                playbackMedia.SeriesTitle ?? series?.Title ?? playbackMedia.Title, series?.OriginalTitle ?? playbackMedia.OriginalTitle,
                playbackMedia.EpisodeNumber, playbackMedia.SeasonNumber, playbackMedia.Kind == "movie" ? playbackMedia.TmdbId : null,
                series?.TmdbId, playbackMedia.Kind == "movie"));
    }

    public async Task<(DemoMedia Media, int Episode)?> NextEpisode(DemoMedia media, int episode, CancellationToken token)
    {
        if (media.Kind != "series" || media.SeasonNumber == 0) return null;
        if (media.Episodes?.Where(x => x.Available && x.SeasonNumber != 0 && x.Number > episode).OrderBy(x => x.Number).FirstOrDefault() is { } next)
            return (media, next.Number);
        var currentSeason = media.SeasonNumber ?? media.Seasons?.FirstOrDefault(x => x.Id == media.SelectedSeasonId)?.Number ?? 1;
        foreach (var season in (media.Seasons ?? []).Where(x => x.Number > currentSeason).OrderBy(x => x.Number))
        {
            var detail = await Detail(media, token, season.Id);
            if (detail.Episodes?.Where(x => x.Available && x.SeasonNumber != 0).OrderBy(x => x.Number).FirstOrDefault() is { } first) return (detail, first.Number);
        }
        return null;
    }

    // Episode Primary/Thumb images are stills. Portrait cards use the series Primary poster.
    public async Task<string> Poster(DemoMedia media, CancellationToken token)
    {
        if (media.Kind is not ("episode" or "season")) return media.Artwork;
        if (media.SeriesId is not { Length: > 0 } seriesId) return "";
        var cached = CachedDetail(media);
        if (cached is { Kind: "series", Artwork.Length: > 0 }) return cached.Artwork;
        return Project(await Request("browse.detail", new { itemId = seriesId }, token)).Artwork;
    }

    public DemoMedia Project(JsonElement item)
    {
        var id = String(item, "id"); var kind = String(item, "kind");
        var progress = item.TryGetProperty("playState", out var play) && play.ValueKind == JsonValueKind.Object ? Number(play, "percentage") * 100 : 0;
        var isPlayed = play.ValueKind == JsonValueKind.Object && play.TryGetProperty("played", out var played) && played.ValueKind == JsonValueKind.True;
        if (isPlayed) progress = 100;
        var duration = Number(item, "runtimeSeconds");
        var artwork = Image(id, "Primary", NullableString(item, "primaryImageTag"));
        var backdrop = Image(id, "Backdrop", NullableString(item, "backdropImageTag"));
        var logoOwner = NullableString(item, "parentLogoItemID");
        var logo = Image(string.IsNullOrWhiteSpace(logoOwner) ? id : logoOwner, "Logo", NullableString(item, "logoImageTag"));
        var episode = Number(item, "episodeNumber"); var season = Number(item, "seasonNumber");
        return new DemoMedia(id, String(item, "name"), String(item, "originalTitle"), item.TryGetProperty("year", out var year) ? year.ToString() : "",
            item.TryGetProperty("genres", out var genres) && genres.ValueKind == JsonValueKind.Array ? string.Join(" / ", genres.EnumerateArray().Select(x => x.GetString())) : "",
            artwork, String(item, "overview"), progress, episode > 0 ? $"S{season}E{episode}" : null,
            duration > 0 ? (int)Math.Ceiling(duration * (1 - progress / 100) / 60) : null, kind,
            StillArtwork: Image(id, "Thumb", NullableString(item, "thumbImageTag")), BackdropArtwork: backdrop,
            LogoArtwork: logo, DurationSeconds: duration, DetailArtwork: backdrop,
            SeriesId: NullableString(item, "seriesID"), SeasonId: NullableString(item, "seasonID"),
            SeasonNumber: item.TryGetProperty("seasonNumber", out var seasonNumber) && seasonNumber.ValueKind == JsonValueKind.Number ? seasonNumber.GetInt32() : null,
            EpisodeNumber: item.TryGetProperty("episodeNumber", out var episodeNumber) && episodeNumber.ValueKind == JsonValueKind.Number ? episodeNumber.GetInt32() : null,
            Played: isPlayed, CommunityRating: item.TryGetProperty("communityRating", out var rating) && rating.ValueKind == JsonValueKind.Number ? rating.GetDouble() : null,
            SeriesTitle: NullableString(item, "seriesName"),
            TmdbId: long.TryParse(NullableString(item, "tmdbID"), out var tmdb) ? tmdb : null,
            OfficialRating: NullableString(item, "officialRating"),
            Cast: item.TryGetProperty("cast", out var cast) && cast.ValueKind == JsonValueKind.Array ? cast.EnumerateArray().Select(person =>
                new DemoPerson(String(person, "name"), NullableString(person, "role") ?? String(person, "kind"), Image(String(person, "id"), "Primary", ""))).ToArray() : []);
    }

    private string Image(string id, string type, string? tag)
    {
        if (tag is null) return "";
        var args = JsonSerializer.Serialize(new { profile = Profile, itemId = id, imageType = type, tag, maxWidth = 1280 }, JsonOptions);
        var url = PlaybackSession.Require(core.CallJSON("server.imageURL", args)).GetProperty("url").GetString()!;
        // BitmapImage cannot supply authentication headers. Keep the token in
        // the in-memory URL; profiles and images are never written to recent files.
        return string.IsNullOrEmpty(Profile.Token) ? url : url + (url.Contains('?') ? "&" : "?") + "api_key=" + Uri.EscapeDataString(Profile.Token);
    }
    private static string String(JsonElement value, string key) => NullableString(value, key) ?? "";
    private static string? NullableString(JsonElement value, string key) => value.TryGetProperty(key, out var result) && result.ValueKind == JsonValueKind.String ? result.GetString() : null;
    private static double Number(JsonElement value, string key) => value.TryGetProperty(key, out var result) && result.ValueKind == JsonValueKind.Number ? result.GetDouble() : 0;
}

using System.Text.Json;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Preview;

namespace OcPlayer.Windows.Services;

internal sealed record ServerProfile(string Id, string Kind, string BaseUrl, string? UserId = null, string? Token = null,
    string? ServerName = null, string? ServerVersion = null, string? UserName = null)
{
    public string DisplayName => string.IsNullOrWhiteSpace(ServerName) ? new Uri(BaseUrl).Authority : ServerName;
    public string DisplayKind => Kind == "emby" ? "Emby" : "Jellyfin";
}
internal sealed record MediaLibrary(string Id, string Name, string Artwork);
internal sealed class ServerConnectionException(string message) : InvalidOperationException(message);

internal sealed class MediaServer(OcpCoreClient core, ServerProfile profile)
{
    internal static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    public ServerProfile Profile { get; } = profile;
    public List<MediaLibrary> Libraries { get; } = [];
    public List<DemoMedia> Latest { get; } = [];
    public List<DemoMedia> Resume { get; } = [];
    public List<DemoMedia> NextUp { get; } = [];
    public string? HomeWarning { get; private set; }

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
        status?.Invoke("正在验证账号…");
        var profile = await Login(core, address, kind, username, password, token);
        var server = new MediaServer(core, profile);
        status?.Invoke("正在读取媒体库…");
        // browse.home returns success even when individual endpoints fail.
        // A libraries failure must not activate an unusable account.
        await server.Refresh(token);
        status?.Invoke("正在读取服务器信息…");
        try
        {
            var info = await server.Request("server.probe", token: token);
            profile = profile with { ServerName = NullableString(info, "serverName"), ServerVersion = NullableString(info, "version") };
        }
        catch (ServerConnectionException) { /* Some proxies deny the public info endpoint; the authenticated library is already verified. */ }
        token.ThrowIfCancellationRequested();
        // Copy the verified catalog without a second network load.
        return new MediaServer(core, profile) { HomeWarning = server.HomeWarning }.CopyCatalog(server);
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
        return profile with { Token = data.GetProperty("token").GetString(), UserId = data.GetProperty("userId").GetString(), UserName = NullableString(data, "userName") ?? username };
    }

    public async Task<JsonElement> Request(string method, object? arguments = null, CancellationToken token = default)
    {
        var node = System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(arguments ?? new { }, JsonOptions))!.AsObject();
        node["profile"] = System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(Profile, JsonOptions));
        return Require(await core.CallJSONAsync(method, node.ToJsonString(), token), token);
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
        throw new ServerConnectionException(message);
    }

    public async Task Refresh(CancellationToken token)
    {
        var home = await Request("browse.home", token: token);
        var failures = home.TryGetProperty("failures", out var failed) && failed.ValueKind == JsonValueKind.Object ? failed.EnumerateObject().ToArray() : [];
        if (failed.ValueKind == JsonValueKind.Object && failed.TryGetProperty("libraries", out var libraryFailure))
            throw new ServerConnectionException("无法读取媒体库，请检查账号权限或重新登录。" + libraryFailure);
        var libraries = home.GetProperty("libraries").EnumerateArray().Select(library =>
        {
            var id = String(library, "id");
            return new MediaLibrary(id, String(library, "name"), Image(id, "Primary", NullableString(library, "primaryImageTag")));
        }).ToArray();
        DemoMedia[] Section(string key) => home.GetProperty(key) is { ValueKind: JsonValueKind.Array } items ? items.EnumerateArray().Select(Project).ToArray() : [];
        var latest = Section("latest");
        var resume = Section("resume");
        var next = Section("nextUp");
        token.ThrowIfCancellationRequested();
        Libraries.Clear(); Latest.Clear(); Resume.Clear(); NextUp.Clear();
        Libraries.AddRange(libraries); Latest.AddRange(latest); Resume.AddRange(resume); NextUp.AddRange(next);
        HomeWarning = failures.Length > 0 ? "部分首页栏目加载失败（" + string.Join("、", failures.Select(x => x.Name switch { "resume" => "继续观看", "latest" => "最近添加", "nextUp" => "接下来看", _ => x.Name })) + "），可点击刷新重试。" : null;
    }

    public async Task<DemoMedia[]> Browse(string? libraryId, string query, string sort, string watchState, CancellationToken token)
    {
        var page = await Request("browse.library", new { parentId = libraryId, searchTerm = query,
            startIndex = 0, limit = 500, recursive = true, kinds = new[] { "movie", "series" },
            sort = new { field = sort == "名称" ? "name" : sort == "年份" ? "year" : "dateAdded", ascending = sort == "名称" },
            watchState = watchState == "未观看" ? "unwatched" : "all" }, token);
        var items = page.GetProperty("items").EnumerateArray().Select(Project);
        return (watchState == "继续观看" ? items.Where(x => x.Progress > 0 && x.Progress < 100) : items).ToArray();
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

    public async Task<DemoMedia> Detail(DemoMedia media, CancellationToken token, string? seasonId = null)
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
                item.TryGetProperty("seasonNumber", out var number) && number.ValueKind == JsonValueKind.Number ? number.GetInt32() : null)).ToArray();
            if (seasonId is null && entry.Kind == "episode")
                seasonId = choices.FirstOrDefault(x => x.Number == (entry.SeasonNumber ?? media.SeasonNumber))?.Id;
            seasonId ??= choices.FirstOrDefault()?.Id;
            var episodes = await Request("browse.episodes", new { seriesId = projected.Id, seasonId, limit = 500 }, token);
            var items = episodes.EnumerateArray().Select(item =>
            {
                var episode = Project(item);
                return new DemoEpisode(episode.EpisodeNumber ?? 0, episode.Title, episode.Artwork,
                    MediaId: episode.Id, SeasonNumber: episode.SeasonNumber ?? 1,
                    Progress: episode.Progress, DurationSeconds: episode.DurationSeconds, Played: episode.Played);
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
            selected ??= items.FirstOrDefault();
            projected = projected with { Seasons = choices, SelectedSeasonId = seasonId, Episodes = items,
                SeasonNumber = choices.FirstOrDefault(x => x.Id == seasonId)?.Number,
                DurationSeconds = selected is { DurationSeconds: > 0 } ? selected.DurationSeconds : projected.DurationSeconds,
                EpisodeNumber = selected?.Number, EpisodeLabel = selected is null ? null : $"S{selected.SeasonNumber}E{selected.Number}" };
        }
        return projected;
    }

    public async Task<DemoEpisode> SetEpisodeWatched(DemoEpisode episode, bool watched, CancellationToken token)
    {
        if (!episode.Available || string.IsNullOrEmpty(episode.MediaId))
            throw new InvalidOperationException("此集尚未入库，无法更新观看状态。");
        await Request(watched ? "server.markPlayed" : "server.markUnplayed", new { itemId = episode.MediaId }, token);
        return episode with { Progress = watched ? 100 : 0, Played = watched };
    }

    public async Task<PlaybackSource> Resolve(DemoMedia media, int episode, CancellationToken token)
    {
        var id = media.Kind == "series" ? media.Episodes?.FirstOrDefault(x => x.Number == episode)?.MediaId : media.Id;
        if (string.IsNullOrEmpty(id)) throw new InvalidOperationException("没有可播放的分集。");
        // Resume belongs to the selected episode, never to the series or another season.
        var playbackMedia = media.Kind == "series" ? Project(await Request("browse.detail", new { itemId = id }, token)) : media;
        var info = await Request("playback.info", new { itemId = id }, token);
        var sources = info.GetProperty("mediaSources");
        if (sources.GetArrayLength() == 0) throw new InvalidOperationException("服务器没有返回可播放的片源。");
        var source = sources[0];
        var sourceId = NullableString(source, "id"); var sessionId = NullableString(info, "playSessionId");
        var url = await Request("server.streamURL", new { itemId = id, mediaSourceId = sourceId, playSessionId = sessionId }, token);
        return new PlaybackSource(id, media.Title, url.GetProperty("url").GetString()!, Profile.Id + ":" + Profile.UserId,
            playbackMedia.Progress >= 100 ? 0 : playbackMedia.DurationSeconds * playbackMedia.Progress / 100,
            Report: new PlaybackReport(JsonSerializer.SerializeToElement(Profile, JsonOptions), id, sourceId, sessionId));
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
            Played: isPlayed);
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

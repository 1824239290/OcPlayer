using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Preview;

namespace OcPlayer.Windows.Services;

internal sealed record DanmakuContext(string CacheKey, bool AllowsCachedMatchReuse, string FileName,
    string? LocalPath, PlaybackSource Source, long? FileSize, long? DurationSeconds,
    string AnimeTitle, string? OriginalTitle, int? EpisodeNumber, int? SeasonNumber,
    long? TmdbId, long? SeriesTmdbId, bool IsMovie, bool IsFinal, DanmakuSpecialTarget? Special = null);
internal sealed record DanmakuSpecialTarget(int index, string[] kinds);
internal sealed record DanmakuEpisode(long EpisodeId, long AnimeId, string AnimeTitle, string EpisodeTitle, bool IsCurrentMatch = false)
{
    public override string ToString() => $"{(IsCurrentMatch ? "✓ " : "")}{(EpisodeTitle.Length > 0 ? EpisodeTitle : "未命名剧集")} · ID {EpisodeId}"
        + (IsCurrentMatch ? " · 当前匹配" : "");
}
internal sealed record DanmakuAnime(long AnimeId, string Title, DanmakuEpisode[] Episodes,
    string? TypeDescription = null, bool ContainsCurrentMatch = false)
{
    public override string ToString() => $"{Title}{(string.IsNullOrWhiteSpace(TypeDescription) ? "" : " · " + TypeDescription)} · {Episodes.Length} 集"
        + (ContainsCurrentMatch ? " · 包含当前匹配" : "");
}
internal sealed record DanmakuPayload(string Kind, string Title, int Count, string? Json, double ShiftSeconds = 0,
    DanmakuEpisode? Match = null, JsonElement? IntroHint = null);

/// Core owns matching, scoring, retries, mappings and comment caches; this adapter supplies Windows media identity.
internal sealed class DanmakuService
{
    private readonly OcpCoreClient _core;
    private readonly Func<string> _bangumiBase;
    private readonly Func<string, CancellationToken, Task<string[]>>? _aliasProvider;
    private readonly bool _introProvidersEnabled;
    private static long _revision;
    public const long CapacityBytes = 256L * 1024 * 1024;
    private readonly string _directory;
    private readonly object _loadsGate = new();
    private sealed class PendingLoad(CancellationTokenSource cancellation) { public CancellationTokenSource Cancellation = cancellation; public Task<DanmakuPayload> Task = null!; }
    private readonly List<PendingLoad> _loads = [];
    private bool _clearing;
    public long UsedBytes => CacheFiles.UsedBytes(_directory, x => x.Name.StartsWith("comments-", StringComparison.Ordinal) && x.Extension == ".json");
    public DanmakuSettings Settings { get; }

    public DanmakuService(OcpCoreClient core, string directory, DanmakuSettings settings, Func<string>? bangumiBase = null,
        Func<string, CancellationToken, Task<string[]>>? aliasProvider = null, bool introProvidersEnabled = true)
    {
        _core = core; Settings = settings;
        _bangumiBase = bangumiBase ?? (() => "https://api.bgm.tv/"); _aliasProvider = aliasProvider; _introProvidersEnabled = introProvidersEnabled;
        _directory = Path.GetFullPath(Path.Combine(directory, "Danmaku"));
        AppPaths.RejectReparsePoints(_directory, directory);
        CacheFiles.Prune(_directory, long.MaxValue, _ => false); // Remove abandoned native temporary writes only.
        PlaybackSession.Require(core.Call("danmakuCache.open", new { directory = _directory, commentsDiskCapacityBytes = CapacityBytes }));
    }

    public DanmakuContext Context(DemoMedia media, PlaybackSource source)
    {
        var metadata = source.Metadata;
        var local = File.Exists(source.Uri) ? Path.GetFullPath(source.Uri)
            : Uri.TryCreate(source.Uri, UriKind.Absolute, out var uri) && uri.IsFile && File.Exists(uri.LocalPath) ? uri.LocalPath : null;
        var remote = local is null && Uri.TryCreate(source.Uri, UriKind.Absolute, out var remoteUri) ? remoteUri : null;
        var name = FileName(metadata?.FileName ?? local ?? (remote is null ? source.Title : Uri.UnescapeDataString(remote.AbsolutePath)));
        if (name.Length == 0) name = FileName(source.Title);
        var parsed = Parse(name);
        var anime = metadata?.AnimeTitle ?? Json.Text(parsed, "title");
        var season = metadata?.SeasonNumber ?? Integer(parsed, "season_number");
        var episode = metadata?.EpisodeNumber ?? Integer(parsed, "episode_number");
        var specialKind = Json.Text(PlaybackSession.Require(_core.Call("danmaku.specialKind", new { text = name })), "kind");
        var special = source.Report is not null
            ? season == 0 && episode is >= 1 ? new DanmakuSpecialTarget(episode.Value, specialKind.Length > 0 ? [specialKind] : ["special", "extra", "other"]) : null
            : specialKind.Length > 0 ? new DanmakuSpecialTarget(episode ?? 1, [specialKind]) : null;
        long? size = metadata?.FileSize;
        var duration = metadata?.DurationSeconds is > 0 ? (long?)Math.Round(metadata.DurationSeconds.Value) : null;
        string identity;
        var cached = source.Report is not null;
        if (local is not null)
        {
            var info = new FileInfo(local); size = info.Length;
            identity = $"{info.FullName}\n{info.Length}\n{info.LastWriteTimeUtc.Ticks}";
            cached = true;
            if (anime.Length <= 3 || anime.All(x => char.IsDigit(x) || char.IsWhiteSpace(x)))
            {
                var parent = info.Directory;
                if (parent is not null)
                {
                    var folder = Parse(parent.Name);
                    season ??= Integer(folder, "season_number");
                    anime = Json.Text(folder, "title");
                    if (season is not null && parent.Parent is not null && (anime.Length == 0 ||
                        System.Text.RegularExpressions.Regex.IsMatch(parent.Name, @"^(?:season\s*\d+|s\d+|第[\d一二两三四五六七八九十]+[季期部])$", System.Text.RegularExpressions.RegexOptions.IgnoreCase)))
                        anime = Json.Text(Parse(parent.Parent.Name), "title");
                    if (anime.Length == 0) anime = parent.Name;
                }
            }
        }
        else if (source.Report is { } report)
        {
            object? episodeToken = special is not null ? new { tokenType = "special", kind = special.kinds[0], index = special.index } : episode is not null ? new { tokenType = "number", value = episode.Value } : null;
            name = Json.Text(PlaybackSession.Require(_core.Call("danmaku.canonicalMatchName", new { seriesTitle = anime, season, episode = episodeToken, rawFileName = name })), "fileName");
            identity = $"{source.TenantId}\n{source.Id}\n{report.MediaSourceId}\n{name}\n{size}\n{duration}";
        }
        else identity = source.Uri;
        return new("windows:" + Hash(identity), cached, name, local, source, size, duration, anime, metadata?.OriginalTitle,
            episode, season, metadata?.TmdbId, metadata?.SeriesTmdbId, metadata?.IsMovie == true,
            Json.Get(parsed, "is_final").ValueKind == JsonValueKind.True, special);
    }

    private JsonElement Parse(string name) => PlaybackSession.Require(_core.Call("danmaku.parseFilename", new { fileName = name }));
    private static int? Integer(JsonElement data, string key) => Json.Get(data, key).TryGetInt32Safe();
    private static string FileName(string value)
    {
        var name = value.Replace('\\', '/').Split('/').Last().Trim();
        var extension = Path.GetExtension(name);
        // A title such as "Series.E01" is not a file extension.
        return new[] { ".mkv", ".mp4", ".avi", ".mov", ".wmv", ".webm", ".ts", ".m2ts", ".flv", ".m4v" }.Contains(extension.ToLowerInvariant())
            ? name[..^extension.Length] : name;
    }
    private static string Hash(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    public Task<DanmakuPayload> Load(DanmakuContext context, bool force, DanmakuEpisode? manual, CancellationToken token)
    {
        lock (_loadsGate)
        {
            if (_clearing) return Task.FromException<DanmakuPayload>(new InvalidOperationException("正在清理弹幕缓存，请稍后重试。"));
            var pending = new PendingLoad(CancellationTokenSource.CreateLinkedTokenSource(token));
            _loads.Add(pending); pending.Task = Run(); return pending.Task;
            async Task<DanmakuPayload> Run()
            {
                try { return await LoadCore(context, force, manual, pending.Cancellation.Token); }
                finally { lock (_loadsGate) _loads.Remove(pending); pending.Cancellation.Dispose(); }
            }
        }
    }

    public async Task ClearComments()
    {
        PendingLoad[] pending;
        lock (_loadsGate)
        {
            if (_clearing) throw new InvalidOperationException("弹幕缓存正在清理。");
            _clearing = true; pending = _loads.ToArray();
            foreach (var load in pending) load.Cancellation.Cancel();
        }
        try
        {
            try { await Task.WhenAll(pending.Select(x => x.Task)); } catch (Exception) { /* Drain cancelled requests before deleting their results. */ }
            AppPaths.RejectReparsePoints(_directory, Path.GetDirectoryName(_directory)!);
            PlaybackSession.Require(_core.Call("danmakuCache.clearComments"));
        }
        finally { lock (_loadsGate) _clearing = false; }
    }

    private async Task<DanmakuPayload> LoadCore(DanmakuContext context, bool force, DanmakuEpisode? manual, CancellationToken token)
    {
        var preferences = Settings.Current.Validated();
        var key = Hash(preferences.EffectiveUrl) + ":" + context.CacheKey;
        var revision = Interlocked.Increment(ref _revision);
        token.ThrowIfCancellationRequested();
        PlaybackSession.Require(_core.Call("danmakuCache.claimRevision", new { mediaID = key, revision }));
        var cached = false;
        if (!force && manual is null && context.AllowsCachedMatchReuse)
        {
            var cache = PlaybackSession.Require(_core.Call("danmakuCache.episodeMatch", new { mediaID = key }));
            using var value = JsonDocument.Parse(Json.Text(cache, "payloadJSON"));
            cached = value.RootElement.ValueKind == JsonValueKind.Object;
        }
        var hash = !cached && manual is null && context.LocalPath is null
            ? await DanmakuFingerprint.ReadRemote(context.Source.Uri, context.Source.HttpHeaders, context.FileSize, token) : null;
        var aliases = manual is null && !cached ? await TitleAliases(context.AnimeTitle, token) : [];
        token.ThrowIfCancellationRequested();
        var response = await _core.CallAsync("danmaku.load", new
        {
            gateway = preferences.Gateway, cacheKey = key, revision, filePath = context.LocalPath, aliases,
            format = "kernelTrack", timeoutSeconds = 12, retryAttempts = 2,
            matchRequest = new { fileName = context.FileName, fileHash = hash, fileSize = context.FileSize,
                videoDuration = context.DurationSeconds, matchMode = "hashAndFileName" },
            configuration = new
            {
                mode = manual is null ? "automatic" : "manual", forceRematch = force, budgetSeconds = 30,
                matchValue = manual is null ? null : new { episodeID = manual.EpisodeId, animeID = manual.AnimeId,
                    animeTitle = manual.AnimeTitle, episodeTitle = manual.EpisodeTitle, shiftSeconds = 0 },
                context = new { fileName = context.FileName, animeTitle = context.AnimeTitle, originalTitle = context.OriginalTitle,
                    episodeNumber = context.EpisodeNumber, seasonNumber = context.SeasonNumber, tmdbId = context.TmdbId ?? context.SeriesTmdbId,
                    seriesTmdbId = context.SeriesTmdbId, isMovie = context.IsMovie, isFinal = context.IsFinal, special = context.Special,
                    fileSize = context.FileSize, durationSeconds = context.DurationSeconds, allowsCachedMatchReuse = context.AllowsCachedMatchReuse }
            },
            providers = new { aniList = new { enabled = _introProvidersEnabled && RuntimeSettings.Current.SkipIntro }, aniSkip = new { enabled = _introProvidersEnabled && RuntimeSettings.Current.SkipIntro },
                animeSkip = new { enabled = _introProvidersEnabled && RuntimeSettings.Current.SkipIntro && preferences.AnimeSkipClientId.Length > 0, clientID = preferences.AnimeSkipClientId }, theIntroDB = new { enabled = _introProvidersEnabled && RuntimeSettings.Current.SkipIntro } }
        }, token);
        token.ThrowIfCancellationRequested();
        if (!response.Ok)
        {
            if (manual is null && aliases.Length > 0 && response.Message == "无法读取媒体指纹，请手动选择弹幕"
                && await FindAliasMatch(context, aliases, token) is { } alternative) return await Load(context, false, alternative, token);
            throw Failure(response);
        }
        var data = response.Data;
        var outcome = Json.Get(data, "outcome");
        var kind = Json.Text(outcome, "kind");
        var hint = Json.Get(data, "introHint");
        if (hint.ValueKind != JsonValueKind.Object) hint = Json.Get(outcome, "introHint");
        JsonElement? intro = hint.ValueKind == JsonValueKind.Object ? hint.Clone() : null;
        if (kind == "noMatch")
        {
            if (manual is null && aliases.Length > 0 && await FindAliasMatch(context, aliases, token) is { } alternative)
                return await Load(context, false, alternative, token);
            return new(kind, "", 0, null, IntroHint: intro);
        }
        var episodes = Json.Get(data, "episodes");
        var first = episodes.ValueKind == JsonValueKind.Array && episodes.GetArrayLength() > 0 ? episodes[0] : default;
        var match = Json.Get(data, "selectedMatch");
        var title = string.Join(" · ", new[] { Json.Text(match, "animeTitle"), Json.Text(match, "episodeTitle") }.Where(x => x.Length > 0));
        var episodeId = ReadId(match, "episodeID");
        var selectedMatch = episodeId > 0 ? new DanmakuEpisode(episodeId, ReadId(match, "animeID"),
            Json.Text(match, "animeTitle"), Json.Text(match, "episodeTitle")) : null;
        var count = (int)Json.Number(first, "count");
        return new(count > 0 ? "loaded" : "empty", title, count, count > 0 ? Json.Text(first, "json") : null,
            Json.Number(match, "shiftSeconds"), selectedMatch, intro);
    }

    public async Task<JsonElement?> LoadIntroHintAsync(DanmakuContext context, CancellationToken token) => (await Load(context, false, null, token)).IntroHint;

    private async Task<DanmakuEpisode?> FindAliasMatch(DanmakuContext context, string[] aliases, CancellationToken token)
    {
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token); budget.CancelAfter(TimeSpan.FromSeconds(6));
        try
        {
            foreach (var alias in aliases.Take(3))
            {
                var episode = context.Special is { } special ? (special.kinds[0] switch { "extra" => "C", "other" => "O", _ => "S" }) + special.index : context.EpisodeNumber?.ToString() ?? "";
                var works = await SearchSingle(alias, episode, budget.Token);
                var flattened = works.SelectMany(work => work.Episodes.Select(part => (Part: part, work.TypeDescription))).ToArray();
                var scored = PlaybackSession.Require(_core.Call("danmaku.scoreCandidates", new
                {
                    target = new { animeTitle = alias, episodeNumber = context.EpisodeNumber, seasonNumber = context.SeasonNumber, isFinal = context.IsFinal, special = context.Special, kind = context.IsMovie ? "movie" : "episode" },
                    candidates = flattened.Select(x => new { episodeId = x.Part.EpisodeId, animeTitle = x.Part.AnimeTitle, episodeTitle = x.Part.EpisodeTitle, type = x.TypeDescription, typeDescription = x.TypeDescription }).ToArray()
                }));
                var selection = Json.Get(scored, "selection");
                if (selection.ValueKind == JsonValueKind.Object && Json.Get(selection, "index").TryGetInt32(out var index) && index >= 0 && index < flattened.Length) return flattened[index].Part;
            }
            return null;
        }
        catch (Exception ex) when (ex is OperationCanceledException or InvalidOperationException) { token.ThrowIfCancellationRequested(); return null; }
    }

    public async Task<DanmakuAnime[]> Search(string anime, string episode, CancellationToken token)
    {
        anime = anime.Trim(); episode = episode.Trim();
        if (anime.Length == 0) throw new ArgumentException("请输入作品名。");
        // Primary search is never held behind optional alias lookup. Alias work has its own short budget.
        var primary = SearchSingle(anime, episode, token);
        async Task<DanmakuAnime[]> Alternate()
        {
            using var budget = CancellationTokenSource.CreateLinkedTokenSource(token); budget.CancelAfter(TimeSpan.FromSeconds(5));
            try { var aliases = await TitleAliases(anime, budget.Token);
                var sets = await Task.WhenAll(aliases.Take(3).Select(x => SearchSingle(x, episode, budget.Token))); return sets.SelectMany(x => x).ToArray(); }
            catch (Exception ex) when (ex is OperationCanceledException or InvalidOperationException) { return []; }
        }
        var alternate = Alternate();
        DanmakuAnime[] main;
        try { main = await primary; }
        catch (InvalidOperationException) { var fallback = await alternate; token.ThrowIfCancellationRequested(); if (fallback.Length > 0) return fallback; throw; }
        var extra = await alternate; token.ThrowIfCancellationRequested();
        return main.Concat(extra).GroupBy(x => x.AnimeId).Select(group => group.First() with { Episodes = group.SelectMany(x => x.Episodes).DistinctBy(x => x.EpisodeId).ToArray() }).ToArray();
    }

    private async Task<string[]> TitleAliases(string title, CancellationToken token)
    {
        if (_aliasProvider is not null) return await _aliasProvider(title, token);
        if (string.IsNullOrWhiteSpace(title)) return [];
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token); budget.CancelAfter(TimeSpan.FromSeconds(2));
        try
        {
            var baseURL = _bangumiBase();
            var response = await _core.CallAsync("bangumi.search", new { keyword = title, subjectType = 2, limit = 5, offset = 0, baseURL }, budget.Token);
            if (!response.Ok) return [];
            var entries = Json.Items(response.Data).Select(Json.Subject).ToArray();
            string Normalize(string value) => Json.Text(PlaybackSession.Require(_core.Call("danmaku.comparableTitle", new { title = value })), "title");
            var normalized = Normalize(title);
            var subjects = entries.Where(x => Normalize(Json.Text(x, "name")) == normalized || Normalize(Json.First(x, "name_cn", "nameCN")) == normalized).Take(2).ToArray();
            var names = subjects.SelectMany(x => new[] { Json.Text(x, "name"), Json.First(x, "name_cn", "nameCN") }).ToList();
            foreach (var subject in subjects)
            {
                OcpResponse raw;
                try { raw = await _core.CallAsync("bangumi.request", new { url = new Uri(new Uri(baseURL), "v0/subjects/" + Json.Text(subject, "id")).AbsoluteUri, httpMethod = "GET", baseURL }, budget.Token); }
                catch (OperationCanceledException) { token.ThrowIfCancellationRequested(); break; }
                if (!raw.Ok || Json.Number(raw.Data, "status") is < 200 or >= 300) continue;
                JsonDocument document;
                try { document = JsonDocument.Parse(Json.Text(raw.Data, "body")); } catch (JsonException) { continue; }
                using var subjectDocument = document;
                var infobox = Json.Get(document.RootElement, "infobox");
                if (infobox.ValueKind != JsonValueKind.Array) continue;
                foreach (var field in infobox.EnumerateArray().Where(x => Json.Text(x, "key") is "别名" or "中文名"))
                {
                    var value = Json.Get(field, "value");
                    if (value.ValueKind == JsonValueKind.String) names.Add(value.GetString()!);
                    else if (value.ValueKind == JsonValueKind.Array) names.AddRange(value.EnumerateArray().Select(x => Json.Text(x, "v")));
                }
            }
            return names.Where(x => x.Length > 0 && !x.Equals(title, StringComparison.OrdinalIgnoreCase)).Distinct(StringComparer.OrdinalIgnoreCase).Take(6).ToArray();
        }
        catch (Exception ex) when (ex is OperationCanceledException or InvalidOperationException) { token.ThrowIfCancellationRequested(); return []; }
    }

    private async Task<DanmakuAnime[]> SearchSingle(string anime, string episode, CancellationToken token)
    {
        anime = anime.Trim(); episode = episode.Trim();
        if (anime.Length == 0) throw new ArgumentException("请输入作品名。");
        var preferences = Settings.Current.Validated();
        var url = preferences.EffectiveUrl + "/v1/search/episodes?anime=" + Uri.EscapeDataString(anime)
            + (episode.Length == 0 ? "" : "&episode=" + Uri.EscapeDataString(episode));
        var response = await _core.CallAsync("danmaku.exchange", new { gateway = preferences.Gateway, url, httpMethod = "GET", timeoutSeconds = 20 }, token);
        token.ThrowIfCancellationRequested();
        if (!response.Ok) throw Failure(response);
        var status = (int)Json.Number(response.Data, "status");
        if (status is < 200 or >= 300) throw new InvalidOperationException(status switch
        { 401 or 403 => "弹幕网关 API Key 无效或请求被拒绝。", 429 => "弹幕请求额度已用完，请稍后重试。", _ => $"弹幕网关暂时不可用（{status}）。" });
        try
        {
            using var document = JsonDocument.Parse(Convert.FromBase64String(Json.Text(response.Data, "bodyBase64")));
            var root = document.RootElement;
            if (Json.Get(root, "success").ValueKind != JsonValueKind.True) throw new InvalidOperationException("弹幕搜索未成功，请检查关键词或稍后重试。");
            var animes = Json.Get(root, "animes");
            if (animes.ValueKind != JsonValueKind.Array) throw new JsonException();
            return animes.EnumerateArray().Select(value =>
            {
                var id = ReadId(value, "animeId"); var title = Json.Text(value, "animeTitle");
                var episodes = Json.Get(value, "episodes");
                return new DanmakuAnime(id, title, episodes.ValueKind == JsonValueKind.Array
                    ? episodes.EnumerateArray().Select(x => new DanmakuEpisode(ReadId(x, "episodeId"), id, title, Json.Text(x, "episodeTitle"))).Where(x => x.EpisodeId > 0).ToArray() : [],
                    Json.First(value, "typeDescription", "type"));
            }).Where(x => x.AnimeId > 0 && x.Episodes.Length > 0).ToArray();
        }
        catch (Exception ex) when (ex is JsonException or FormatException)
        { throw new InvalidOperationException("弹幕服务返回了无法解析的数据。"); }
    }

    private static long ReadId(JsonElement value, string key) => long.TryParse(Json.Text(value, key), out var id) ? id : 0;
    private static InvalidOperationException Failure(OcpResponse response) => new(response.Message switch
    {
        // Only Core-owned fixed messages are safe to display; upstream bodies may contain request URLs or tokens.
        "网关 API Key 无效" or "网关拒绝了请求（API Key 无效或已被限制）" or "弹幕请求额度已用完"
            or "弹幕网关未配置" or "无法读取媒体指纹，请手动选择弹幕" or "弹幕匹配超时，请重试"
            or "弹幕服务返回了无法解析的数据" or "弹幕网络请求失败" or "弹幕服务暂时不可用" => response.Message,
        _ => response.Code switch
    {
        1003 => "弹幕请求已取消。", 2001 or 2003 => "弹幕网关拒绝了请求，请检查 API Key。",
        1501 => "弹幕网络请求失败，请检查网络后重试。",
        1502 => "弹幕加载未完成，请重试或手动选择剧集。", 1503 => "弹幕匹配超时，请重试或手动选择。",
        _ => $"弹幕加载失败（{response.Code}），请检查网关设置或重试。"
    }
    });
}

internal static class DanmakuJsonExtensions
{
    public static int? TryGetInt32Safe(this JsonElement value) => value.ValueKind == JsonValueKind.Number && value.TryGetInt32(out var number) ? number : null;
    public static bool TryGetInt64Safe(this JsonElement value, out long number)
    { number = 0; return value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out number); }
}

using System.Text.Json;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Preview;

namespace OcPlayer.Windows.Services;

internal sealed record TmdbPreferences(string ApiKey = "", string Language = "zh-CN", bool PreferText = true,
    bool ReplaceImages = false, bool ShowMissingEpisodes = true, bool UseMirror = false, string ApiMirror = "", string ImageMirror = "")
{
    public bool Configured => !string.IsNullOrWhiteSpace(ApiKey);
    public string ApiBase => UseMirror && ApiMirror.Length > 0 ? Normalize(ApiMirror, false) : "https://api.themoviedb.org/3";
    public string ImageBase => UseMirror && ImageMirror.Length > 0 ? Normalize(ImageMirror, true) : "https://image.tmdb.org/t/p";
    public TmdbPreferences Validated()
    {
        if (ApiKey is null || ApiMirror is null || ImageMirror is null) throw new ArgumentException("TMDB 配置字段无效。");
        if (!new[] { "zh-CN", "zh-TW", "en", "ja", "ko" }.Contains(Language)) throw new ArgumentException("请选择支持的元数据语言。");
        if (ApiKey.Any(char.IsControl)) throw new ArgumentException("TMDB 凭据不能包含控制字符。");
        return this with { ApiKey = ApiKey.Trim(), ApiMirror = ApiMirror.Trim().Length == 0 ? "" : Normalize(ApiMirror, false),
            ImageMirror = ImageMirror.Trim().Length == 0 ? "" : Normalize(ImageMirror, true) };
    }
    public static string Normalize(string input, bool image)
    {
        input = input.Trim(); if (!input.Contains("://", StringComparison.Ordinal)) input = "https://" + input;
        if (!Uri.TryCreate(input, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")
            || uri.Host.Length == 0 || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0)
            throw new ArgumentException("请输入有效的 HTTP(S) 根地址，不含账号、查询参数或片段。");
        var path = uri.AbsolutePath.TrimEnd('/');
        if (image) path = System.Text.RegularExpressions.Regex.Replace(path, @"/(?:w\d+|h\d+|original)(?:/.*)?$", "");
        if (path.Length == 0) path = image ? "/t/p" : "/3";
        return uri.GetLeftPart(UriPartial.Authority) + path;
    }
}

internal sealed class TmdbSettings
{
    private readonly string _resource;
    public TmdbPreferences Current { get; private set; } = new();
    public string? LoadWarning { get; private set; }
    public event Action? Changed;
    public TmdbSettings(string resource)
    {
        _resource = resource;
        try { var item = new global::Windows.Security.Credentials.PasswordVault().Retrieve(resource, "tmdb-settings"); item.RetrievePassword();
            Current = (JsonSerializer.Deserialize<TmdbPreferences>(item.Password) ?? new()).Validated(); }
        catch (System.Runtime.InteropServices.COMException ex) when (ex.HResult == unchecked((int)0x80070490)) { }
        catch (Exception ex) when (ex is JsonException or ArgumentException or System.Runtime.InteropServices.COMException)
        { LoadWarning = "未能读取 TMDB 设置；请重新配置，原凭据保留。"; }
    }
    public void Save(TmdbPreferences value)
    {
        value = value.Validated();
        new global::Windows.Security.Credentials.PasswordVault().Add(new global::Windows.Security.Credentials.PasswordCredential(_resource, "tmdb-settings", JsonSerializer.Serialize(value)));
        Current = value; LoadWarning = null; Changed?.Invoke();
    }
}

internal sealed record TmdbBatchProgress(int Completed, int Total, string CurrentTitle, int Added, int Skipped, int Unmatched, int Failed, int Seasons, bool Cancelled = false, string? Error = null)
{
    public override string ToString() => $"{Completed}/{Total} · {CurrentTitle}\n新补 {Added} · 跳过 {Skipped} · 匹配不上 {Unmatched} · 失败 {Failed} · 季 {Seasons}"
        + (Cancelled ? "\n已取消，成功结果已保留，下次执行会继续补全。" : "") + (Error is null ? "" : "\n" + Error);
}

internal sealed class TmdbService
{
    private sealed record Cached(string Key, DateTimeOffset FetchedAt, JsonElement Data);
    private readonly OcpCoreClient _core;
    private readonly string _directory;
    private readonly Dictionary<string, Cached> _cache = [];
    private readonly Dictionary<string, string> _links = [];
    private readonly SemaphoreSlim _gate = new(1, 1);
    public TmdbSettings Settings { get; }
    public int EnrichedCount => _links.Values.Count(x => x.Length > 0);
    public string? MatchKey(DemoMedia media, string tenant) => _links.GetValueOrDefault(tenant + ":" + media.Id) is { Length: > 0 } key ? key : null;
    public void Bind(DemoMedia media, string tenant, string? entityKey)
    {
        if (entityKey is not null && !System.Text.RegularExpressions.Regex.IsMatch(entityKey, @"^(movie|tv|collection)/[1-9]\d*$")) throw new ArgumentException("TMDB 关联无效。");
        _links[tenant + ":" + media.Id] = entityKey ?? ""; Write("links.json", _links);
    }
    public TmdbBatchProgress? LastBatch { get; private set; }
    public bool BatchRunning { get; private set; }
    public TmdbService(OcpCoreClient core, string directory, string credentialResource = "OcPlayer.Windows")
    {
        _core = core; _directory = Path.Combine(directory, "Tmdb"); Directory.CreateDirectory(_directory); Settings = new(credentialResource);
        foreach (var path in Directory.EnumerateFiles(_directory, "*.json"))
        {
            try
            {
                if (Path.GetFileName(path) == "links.json") { foreach (var pair in JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path)) ?? []) _links[pair.Key] = pair.Value; }
                else if (Path.GetFileName(path) == "batch.json") LastBatch = JsonSerializer.Deserialize<TmdbBatchProgress>(File.ReadAllText(path));
                else if (JsonSerializer.Deserialize<Cached>(File.ReadAllText(path)) is { } cached) _cache[cached.Key] = cached;
            }
            catch (Exception ex) when (ex is JsonException or IOException) { /* Leave invalid data untouched; re-fetch when requested. */ }
        }
    }
    public string Image(string path, string size = "w780") => string.IsNullOrEmpty(path) ? "" : Settings.Current.ImageBase + "/" + size + "/" + path.TrimStart('/');
    private static string Hash(string text) => Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(text)));
    private void Write(string name, object value)
    { var path = Path.Combine(_directory, name); var temporary = path + ".tmp"; File.WriteAllText(temporary, JsonSerializer.Serialize(value)); File.Move(temporary, path, true); }
    private async Task<JsonElement> Call(string method, object args, CancellationToken token, string? languageOverride = null)
    {
        var p = Settings.Current;
        var node = System.Text.Json.Nodes.JsonNode.Parse(JsonSerializer.Serialize(args))!.AsObject();
        node["apiKey"] = p.ApiKey; node["apiBase"] = p.ApiBase; node["language"] = languageOverride ?? (p.Language == "en" ? "en-US" : p.Language);
        var response = await _core.CallJSONAsync(method, node.ToJsonString(), token); token.ThrowIfCancellationRequested();
        if (!response.Ok) throw new InvalidOperationException($"TMDB 请求失败（{response.Code}），请检查凭据、镜像与网络。");
        return response.Data.Clone();
    }
    public Task<JsonElement> Search(string query, string mediaType, int? year, CancellationToken token) => Call("tmdb.search", new { query, mediaType, year }, token);
    private async Task<JsonElement> Entity(string key, CancellationToken token)
    {
        var cacheKey = Settings.Current.Language + ":" + key;
        // Airing series/seasons refresh daily; completed movie metadata may stay cached for a month.
        var age = key.StartsWith("tv/", StringComparison.Ordinal) ? 1 : 30;
        if (_cache.TryGetValue(cacheKey, out var cached) && DateTimeOffset.UtcNow - cached.FetchedAt < TimeSpan.FromDays(age)) return cached.Data;
        var parts = key.Split('/'); var id = long.Parse(parts[1]);
        var data = parts.Length == 4 ? await Call("tmdb.season", new { id, seasonNumber = int.Parse(parts[3]) }, token)
            : await Call("tmdb.entity", new { id, mediaType = parts[0] }, token);
        if (parts.Length == 4 && Settings.Current.Language != "en")
        {
            var entries = Json.Get(data, "episodes");
            if (Json.Text(data, "name").Length == 0 || Json.Text(data, "overview").Length == 0
                || entries.ValueKind == JsonValueKind.Array && entries.EnumerateArray().Any(x => Json.Text(x, "name").Length == 0 || Json.Text(x, "overview").Length == 0))
            {
                try
                {
                    var fallback = await Call("tmdb.season", new { id, seasonNumber = int.Parse(parts[3]) }, token, "en-US");
                    var merged = System.Text.Json.Nodes.JsonNode.Parse(data.GetRawText())!.AsObject();
                    foreach (var field in new[] { "name", "overview", "poster_path" }) if (Json.Text(data, field).Length == 0) merged[field] = Json.Text(fallback, field);
                    var other = Json.Get(fallback, "episodes"); var byNumber = other.ValueKind == JsonValueKind.Array ? other.EnumerateArray().ToDictionary(x => (int)Json.Number(x, "episode_number")) : [];
                    if (merged["episodes"] is System.Text.Json.Nodes.JsonArray episodeArray) foreach (var episode in episodeArray.OfType<System.Text.Json.Nodes.JsonObject>())
                    {
                        if (!byNumber.TryGetValue(episode["episode_number"]!.GetValue<int>(), out var translated)) continue;
                        foreach (var field in new[] { "name", "overview", "still_path" }) if (string.IsNullOrEmpty(episode[field]?.GetValue<string>())) episode[field] = Json.Text(translated, field);
                    }
                    data = JsonSerializer.SerializeToElement(merged);
                }
                catch (InvalidOperationException) { /* Optional English fallback must not discard primary metadata. */ }
            }
        }
        cached = new(cacheKey, DateTimeOffset.UtcNow, data); _cache[cacheKey] = cached; Write(Hash(cacheKey) + ".json", cached); return data;
    }
    public async Task<JsonElement?> Season(long seriesId, int number, CancellationToken token)
    {
        if (!Settings.Current.Configured) return null;
        await _gate.WaitAsync(token); try { return await Entity($"tv/{seriesId}/season/{number}", token); } finally { _gate.Release(); }
    }
    private async Task<string?> Resolve(DemoMedia media, string tenant, CancellationToken token)
    {
        var itemKey = tenant + ":" + media.Id;
        if (_links.TryGetValue(itemKey, out var existing)) return existing;
        var type = media.Kind == "movie" ? "movie" : media.Kind == "boxSet" ? "collection" : "tv";
        if (media.TmdbId is > 0) return type + "/" + media.TmdbId;
        var item = new { name = media.Title, kind = media.Kind, originalTitle = media.OriginalTitle, year = int.TryParse(media.Year, out var y) ? (int?)y : null };
        var results = new List<JsonElement>();
        foreach (var query in new[] { media.Title, media.OriginalTitle }.Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase))
        {
            var response = await Search(query, type, item.year, token); if (response.ValueKind == JsonValueKind.Array) results.AddRange(response.EnumerateArray());
        }
        var candidates = results.DistinctBy(x => Json.Number(x, "id")).Select(x => new { id = (long)Json.Number(x, "id"), mediaType = type,
            title = Json.First(x, "title", "name"), originalTitle = Json.First(x, "original_title", "original_name"),
            year = int.TryParse(Json.First(x, "release_date", "first_air_date").Split('-')[0], out var yr) ? (int?)yr : null, popularity = Json.Number(x, "popularity") }).ToArray();
        var rank = PlaybackSession.Require(_core.Call("tmdb.matcher", new { operation = "rank", item, candidates }));
        var match = Json.Get(rank, "match");
        return Json.Get(match, "shouldApplyAutomatically").ValueKind == JsonValueKind.True ? Json.Text(match, "entityKey") : null;
    }
    public async Task<DemoMedia> Enrich(DemoMedia media, string tenantId, CancellationToken token)
    {
        if (!Settings.Current.Configured || media.Kind is not ("movie" or "series" or "boxSet")) return media;
        await _gate.WaitAsync(token);
        try
        {
            var key = await Resolve(media, tenantId, token); if (string.IsNullOrEmpty(key)) return media;
            var entity = await Entity(key, token); _links[tenantId + ":" + media.Id] = key; Write("links.json", _links);
            var p = Settings.Current;
            string Text(string current, string replacement) => replacement.Length > 0 && (p.PreferText || string.IsNullOrWhiteSpace(current)) ? replacement : current;
            string Art(string current, string replacement, string size = "w780") => replacement.Length > 0 && (p.ReplaceImages || string.IsNullOrWhiteSpace(current)) ? Image(replacement, size) : current;
            var episodes = media.Episodes; var seasons = media.Seasons; var seasonOverview = media.SeasonOverview;
            if (media.Kind == "series")
            {
                var availableSeasons = Json.Get(entity, "seasons");
                if (availableSeasons.ValueKind == JsonValueKind.Array)
                {
                    var all = (seasons ?? []).ToList();
                    foreach (var s in availableSeasons.EnumerateArray())
                    {
                        var n = (int)Json.Number(s, "season_number");
                        var index = all.FindIndex(x => x.Number == n);
                        if (index >= 0) all[index] = all[index] with { Overview = Text(all[index].Overview, Json.Text(s, "overview")) };
                        else if (p.ShowMissingEpisodes) all.Add(new("tmdb:" + n, Json.Text(s, "name"), n, Overview: Json.Text(s, "overview")));
                    }
                    seasons = all.OrderBy(x => x.Number).ToArray();
                }
                var number = media.SelectedSeasonId?.StartsWith("tmdb:", StringComparison.Ordinal) == true && int.TryParse(media.SelectedSeasonId[5..], out var synthetic) ? synthetic : media.SeasonNumber ?? seasons?.FirstOrDefault(x => x.Id == media.SelectedSeasonId)?.Number
                    ?? episodes?.FirstOrDefault()?.SeasonNumber ?? seasons?.FirstOrDefault(x => x.Number > 0)?.Number;
                if (number is not null)
                {
                    var season = await Entity(key + "/season/" + number, token);
                    seasonOverview = Text(seasonOverview ?? "", Json.Text(season, "overview"));
                    var merged = (episodes ?? []).Where(x => x.SeasonNumber == number && x.Available).ToList();
                    var entries = Json.Get(season, "episodes");
                    foreach (var ep in entries.ValueKind == JsonValueKind.Array ? entries.EnumerateArray().ToArray() : [])
                    {
                        var n = (int)Json.Number(ep, "episode_number"); var index = merged.FindIndex(x => x.Number == n && x.SeasonNumber == number);
                        if (index >= 0) merged[index] = merged[index] with { Title = Text(merged[index].Title, Json.Text(ep, "name")), Artwork = Art(merged[index].Artwork, Json.Text(ep, "still_path")), Overview = Text(merged[index].Overview, Json.Text(ep, "overview")), AirDate = string.IsNullOrEmpty(merged[index].AirDate) ? Json.Text(ep, "air_date") : merged[index].AirDate };
                        else if (p.ShowMissingEpisodes) merged.Add(new(n, Json.Text(ep, "name"), Image(Json.Text(ep, "still_path")), false, SeasonNumber: number.Value, DurationSeconds: Json.Number(ep, "runtime") * 60, Overview: Json.Text(ep, "overview"), AirDate: Json.Text(ep, "air_date")));
                    }
                    episodes = merged.OrderBy(x => x.Number).ToArray();
                }
            }
            var genres = Json.Get(entity, "genres"); var cast = Json.Get(entity, "cast");
            return media with { TmdbId = (long)Json.Number(entity, "id"), Title = Text(media.Title, Json.First(entity, "title", "name")),
                OriginalTitle = Text(media.OriginalTitle, Json.First(entity, "original_title", "original_name")), Description = Text(media.Description, Json.Text(entity, "overview")),
                Category = Text(media.Category, genres.ValueKind == JsonValueKind.Array ? string.Join(" / ", genres.EnumerateArray().Select(x => x.GetString())) : ""),
                Artwork = Art(media.Artwork, Json.Text(entity, "poster_path")), BackdropArtwork = Art(media.BackdropArtwork, Json.Text(entity, "backdrop_path"), "original"),
                DetailArtwork = Art(media.DetailArtwork, Json.Text(entity, "backdrop_path"), "original"),
                CommunityRating = media.CommunityRating ?? (Json.Number(entity, "vote_average") > 0 ? Json.Number(entity, "vote_average") : null),
                Cast = media.Cast is { Length: > 0 } ? media.Cast : cast.ValueKind == JsonValueKind.Array ? cast.EnumerateArray().Select(x => new DemoPerson(Json.Text(x, "name"), Json.Text(x, "character"), Image(Json.Text(x, "profile_path"), "w185"))).ToArray() : null,
                Seasons = seasons, Episodes = episodes, SeasonOverview = seasonOverview };
        }
        finally { _gate.Release(); }
    }
    public async Task EnrichLibrary(MediaServer server, IProgress<TmdbBatchProgress>? progress, CancellationToken token)
    {
        if (BatchRunning) throw new InvalidOperationException("已有媒体库补全任务正在执行。");
        if (!Settings.Current.Configured) throw new InvalidOperationException("请先保存 TMDB 凭据。");
        BatchRunning = true; var state = new TmdbBatchProgress(0, 0, "正在读取媒体库", 0, 0, 0, 0, 0);
        void Report() { LastBatch = state; Write("batch.json", state); progress?.Report(state); }
        try
        {
            var items = new List<DemoMedia>(); var start = 0;
            while (true)
            {
                token.ThrowIfCancellationRequested();
                var page = await server.Request("browse.library", new { startIndex = start, limit = 200, recursive = true, kinds = new[] { "movie", "series" } }, token);
                var entries = Json.Get(page, "items"); if (entries.ValueKind != JsonValueKind.Array || entries.GetArrayLength() == 0) break;
                items.AddRange(entries.EnumerateArray().Select(server.Project).Where(x => x.Kind is "movie" or "series")); start += entries.GetArrayLength();
                if (entries.GetArrayLength() < 200) break;
            }
            items = items.DistinctBy(x => x.Id).ToList(); state = state with { Total = items.Count }; Report();
            foreach (var media in items)
            {
                token.ThrowIfCancellationRequested(); state = state with { CurrentTitle = media.Title }; Report();
                try
                {
                    var before = _links.ContainsKey(server.Profile.Id + ":" + media.Id);
                    var result = await Enrich(media, server.Profile.Id, token);
                    var seasonCount = 0;
                    if (result.Kind == "series" && result.TmdbId is > 0)
                    {
                        JsonElement entity; await _gate.WaitAsync(token); try { entity = await Entity("tv/" + result.TmdbId, token); } finally { _gate.Release(); }
                        var allSeasons = Json.Get(entity, "seasons");
                        foreach (var s in allSeasons.ValueKind == JsonValueKind.Array ? allSeasons.EnumerateArray().ToArray() : [])
                        { await Season(result.TmdbId.Value, (int)Json.Number(s, "season_number"), token); seasonCount++; }
                    }
                    var matched = _links.ContainsKey(server.Profile.Id + ":" + media.Id);
                    state = state with { Completed = state.Completed + 1, Added = state.Added + (!before && matched ? 1 : 0), Skipped = state.Skipped + (before ? 1 : 0), Unmatched = state.Unmatched + (!matched ? 1 : 0), Seasons = state.Seasons + seasonCount };
                }
                catch (OperationCanceledException) { throw; }
                catch (Exception ex) { state = state with { Completed = state.Completed + 1, Failed = state.Failed + 1, Error = ex.Message }; }
                Report();
            }
            state = state with { CurrentTitle = "补全完成" }; Report();
        }
        catch (OperationCanceledException) { state = state with { Cancelled = true, CurrentTitle = "已取消" }; Report(); }
        finally { BatchRunning = false; }
    }
    public async Task Clear(CancellationToken token = default)
    {
        if (BatchRunning) throw new InvalidOperationException("请先取消正在执行的补全任务。");
        await _gate.WaitAsync(token); try { foreach (var path in Directory.EnumerateFiles(_directory, "*.json")) File.Delete(path); _cache.Clear(); _links.Clear(); LastBatch = null; } finally { _gate.Release(); }
    }
}

using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using OcPlayer.Windows.Preview;

namespace OcPlayer.Windows.Services;

internal sealed record BangumiMediaLink(string Source, string SeriesId, int? Season, long SubjectId, string Title);
internal sealed record BangumiDomains(string Api, string Images, string Next, string Main)
{
    public static BangumiDomains Official { get; } = new("https://api.bgm.tv/", "https://lain.bgm.tv/", "https://next.bgm.tv/", "https://bgm.tv/");
    internal static string NextApi(string api)
    {
        var uri = new Uri(MediaServer.NormalizeAddress(api) + "/");
        // The v0 API and Next's p1 API are separate services, including mirrors.
        // Custom/local service roots retain their host and path.
        return uri.Host.StartsWith("api.", StringComparison.OrdinalIgnoreCase)
            ? new UriBuilder(uri) { Host = "next." + uri.Host[4..] }.Uri.AbsoluteUri
            : uri.AbsoluteUri;
    }
    public static BangumiDomains Parse(string raw)
    {
        raw = raw.Trim();
        if (!raw.Contains("://")) raw = "https://" + raw;
        if (!Uri.TryCreate(raw, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https") || uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0 || uri.AbsolutePath != "/" || uri.Host.Length == 0)
            throw new ArgumentException("镜像请填写根域名，可带协议和端口；不要填写 API 路径、账号、查询参数或片段。");
        var host = uri.Host;
        foreach (var prefix in new[] { "api.", "lain.", "next." }) if (host.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) { host = host[prefix.Length..]; break; }
        if (Uri.CheckHostName(host) != UriHostNameType.Dns || !host.Contains('.')) throw new ArgumentException("镜像根域名无效。");
        string Domain(string prefix) => new UriBuilder(uri) { Host = prefix + host }.Uri.AbsoluteUri;
        return new(Domain("api."), Domain("lain."), Domain("next."), Domain(""));
    }
}

internal sealed partial class ViewingIntegrations
{
    private string _store = "";
    private readonly object _preferencesGate = new();
    private Dictionary<string, string> _preferences = [];
    private readonly SemaphoreSlim _moviePilotRefresh = new(1);
    private long _moviePilotRevision;
    private readonly ConcurrentDictionary<string, Action<JsonElement>> _searchObservers = new();
    // 快照内存索引：页面按卡片/条目读取时不再逐个读盘与重复 SHA256。
    private readonly Dictionary<string, (JsonElement Value, DateTimeOffset Stored, int Bytes)> _snapshotMemory = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _snapshotGate = new();
    private long _snapshotBytes;
    private const int SnapshotMemoryLimit = 2000;
    private const long SnapshotMemoryBudget = 24L * 1024 * 1024;
    private void InitializePreferences()
    {
        var root = AppPaths.DataDirectory;
        _store = Path.Combine(root, "Integrations", Hash(_resource)); Directory.CreateDirectory(_store);
        CacheFiles.Prune(Path.Combine(_store, "Bangumi"), 64L * 1024 * 1024, CacheFiles.HashedJson, TimeSpan.FromDays(30), force: true);
        try { if (File.Exists(Path.Combine(_store, "preferences.json"))) _preferences = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(Path.Combine(_store, "preferences.json"))) ?? []; }
        catch (Exception ex) when (ex is IOException or JsonException) { }
        // Enabled is a user preference, independent from an account temporarily invalidated
        // by OAuth rejection. Persist its initial value before any auth state can change.
        if (!_preferences.ContainsKey("bangumi.enabled")) SetPreference("bangumi.enabled", Bangumi?.Enabled == false ? "false" : "true");
        if (!_preferences.ContainsKey("moviepilot.enabled")) SetPreference("moviepilot.enabled", MoviePilot?.Enabled == false ? "false" : "true");
        if (!_preferences.ContainsKey("bangumi.mirror.enabled") && Bangumi is { } account && Uri.TryCreate(account.BaseUrl, UriKind.Absolute, out var previous) && previous.Host.StartsWith("api.") && previous.Host != "api.bgm.tv" && previous.AbsolutePath == "/")
        { SetPreference("bangumi.mirror.root", new UriBuilder(previous) { Host = previous.Host[4..] }.Uri.AbsoluteUri); SetPreference("bangumi.mirror.enabled", "true"); }
    }
    private static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    public string Preference(string key, string fallback = "") { lock (_preferencesGate) return _preferences.GetValueOrDefault(key, fallback); }
    public Dictionary<string, string> ExportPreferences() { lock (_preferencesGate) return new(_preferences); }
    public void RestorePreferences(IReadOnlyDictionary<string, string> preferences)
    {
        if (preferences.GetValueOrDefault("bangumi.mirror.enabled") == "true") BangumiDomains.Parse(preferences.GetValueOrDefault("bangumi.mirror.root") ?? "");
        foreach (var (key, value) in preferences) SetPreference(key, value);
        ConfigureMirror(MirrorEnabled, MirrorRoot); Enable("bangumi", IsEnabled("bangumi")); Enable("moviepilot", IsEnabled("moviepilot"));
    }
    public void SetPreference(string key, string value)
    {
        lock (_preferencesGate) { _preferences[key] = value; AtomicWrite(Path.Combine(_store, "preferences.json"), JsonSerializer.Serialize(_preferences)); }
    }
    private static void AtomicWrite(string path, string value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!); var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        File.WriteAllText(temp, value); File.Move(temp, path, true);
    }
    public bool IsEnabled(string key) => Preference(key + ".enabled", (key == "bangumi" ? Bangumi : MoviePilot)?.Enabled == false ? "false" : "true") != "false";
    public bool MirrorEnabled => Preference("bangumi.mirror.enabled") == "true";
    public string MirrorRoot => Preference("bangumi.mirror.root");
    public BangumiDomains Domains => MirrorEnabled ? BangumiDomains.Parse(MirrorRoot) : BangumiDomains.Official;
    public void ConfigureMirror(bool enabled, string root, bool clear = false)
    {
        var domains = enabled ? BangumiDomains.Parse(root) : BangumiDomains.Official;
        var roots = MirrorRoots().Append(MirrorRoot).Append(root).Where(x => !string.IsNullOrWhiteSpace(x)).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        SetPreference("bangumi.mirror.previousRoots", JsonSerializer.Serialize(roots));
        SetPreference("bangumi.mirror.root", clear ? "" : root.Trim()); SetPreference("bangumi.mirror.enabled", enabled ? "true" : "false");
        lock (_bangumiGate) { BeginBangumiOperation(); if (Bangumi is { } account) Save("bangumi", account with { BaseUrl = domains.Api }); }
        Changed?.Invoke();
    }
    public string RewriteBangumiUrl(string source)
    {
        if (!Uri.TryCreate(source, UriKind.Absolute, out var uri)) return source;
        var root = uri.Host switch { "api.bgm.tv" => Domains.Api, "lain.bgm.tv" => Domains.Images, "next.bgm.tv" => Domains.Next, "bgm.tv" or "bangumi.tv" or "chii.in" => Domains.Main, _ => null };
        if (root is null)
            foreach (var prior in MirrorRoots().Append(MirrorRoot))
            {
                BangumiDomains old; try { old = BangumiDomains.Parse(prior); } catch (ArgumentException) { continue; }
                foreach (var (from, to) in new[] { (old.Api, Domains.Api), (old.Images, Domains.Images), (old.Next, Domains.Next), (old.Main, Domains.Main) })
                    if (new Uri(from).Authority.Equals(uri.Authority, StringComparison.OrdinalIgnoreCase)) { root = to; break; }
                if (root is not null) break;
            }
        return root is null ? source : new Uri(new Uri(root), uri.PathAndQuery).AbsoluteUri;
    }
    private string[] MirrorRoots() { try { return JsonSerializer.Deserialize<string[]>(Preference("bangumi.mirror.previousRoots", "[]")) ?? []; } catch (JsonException) { return []; } }
    public void RememberMoviePilotPassword(bool remember)
    {
        SetPreference("moviepilot.rememberPassword", remember ? "true" : "false");
        if (MoviePilot is { } account) Save("moviepilot", account with { RememberPassword = remember, Password = remember ? account.Password : null });
    }
    private async Task<JsonElement> MoviePilotRequest(string method, object? args, CancellationToken token)
    {
        var revision = Interlocked.Read(ref _moviePilotRevision); var observed = RequireAccount(MoviePilot, "MoviePilot");
        void Check() { token.ThrowIfCancellationRequested(); if (revision != Interlocked.Read(ref _moviePilotRevision)) throw new OperationCanceledException("账号配置已更改。", token); }
        try { var response = await Request("moviepilot." + method, observed, args, token); Check(); return response; }
        catch (IntegrationRequestException ex) when (ex.Code == 2001 && observed.RememberPassword && !string.IsNullOrEmpty(observed.Password))
        {
            await _moviePilotRefresh.WaitAsync(token);
            try
            {
                Check();
                var current = RequireAccount(MoviePilot, "MoviePilot");
                if (current.BaseUrl != observed.BaseUrl || current.UserName != observed.UserName) throw new OperationCanceledException("账号已更换。", token);
                if (current.AccessToken == observed.AccessToken)
                {
                    if (!current.RememberPassword || string.IsNullOrEmpty(current.Password)) throw;
                    var response = await Call("moviepilot.login", new { baseURL = current.BaseUrl, username = current.UserName, password = current.Password, validateUser = true }, token);
                    var access = Json.Text(response, "accessToken"); if (access.Length == 0) throw new InvalidOperationException("重新登录未返回有效令牌。");
                    Check(); if (!ReferenceEquals(current, MoviePilot)) throw new OperationCanceledException("账号配置已更改。", token);
                    Save("moviepilot", current with { AccessToken = access });
                }
            }
            finally { _moviePilotRefresh.Release(); }
            Check(); var replay = await Request("moviepilot." + method, RequireAccount(MoviePilot, "MoviePilot"), args, token); Check(); return replay;
        }
    }
    public void ReceiveCoreEvent(string name, JsonElement data)
    {
        if (name == "moviepilot.searchProgress" && _searchObservers.TryGetValue(Json.Text(data, "requestId"), out var observer)) observer(data.Clone());
    }
    public async Task<JsonElement[]> TorrentSearch(string keyword, long[] sites, Action<JsonElement> update, CancellationToken token)
    {
        var id = Guid.NewGuid().ToString("N"); _searchObservers[id] = update;
        try { return Json.Items(await Mp("torrentSearch", new { keyword, sites, requestId = id }, token)); }
        finally { _searchObservers.TryRemove(id, out _); }
    }
    private string SnapshotPath(string key) => Path.Combine(_store, "Bangumi", Hash(Bangumi?.UserName ?? "anonymous"), Hash(key) + ".json");
    public JsonElement? Snapshot(string key) => ReadSnapshot(key, TimeSpan.MaxValue);
    public JsonElement? SnapshotWithin(string key, TimeSpan maxAge) => maxAge <= TimeSpan.Zero ? null : ReadSnapshot(key, maxAge);
    private JsonElement? ReadSnapshot(string key, TimeSpan maxAge)
    {
        var path = SnapshotPath(key);
        lock (_snapshotGate)
        {
            if (_snapshotMemory.TryGetValue(path, out var entry))
                return DateTimeOffset.UtcNow - entry.Stored <= maxAge ? entry.Value : null;
            try
            {
                if (!File.Exists(path)) return null;
                var text = File.ReadAllText(path);
                var stored = new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero);
                var value = JsonDocument.Parse(text).RootElement.Clone();
                RememberLocked(path, value, stored, text.Length);
                return DateTimeOffset.UtcNow - stored <= maxAge ? value : null;
            }
            catch (Exception ex) when (ex is IOException or JsonException) { return null; }
        }
    }
    private void RememberLocked(string path, JsonElement value, DateTimeOffset stored, int bytes)
    {
        if (_snapshotMemory.TryGetValue(path, out var previous)) _snapshotBytes -= previous.Bytes;
        if (_snapshotMemory.Count >= SnapshotMemoryLimit || _snapshotBytes + bytes > SnapshotMemoryBudget) { _snapshotMemory.Clear(); _snapshotBytes = 0; }
        _snapshotMemory[path] = (value, stored, bytes); _snapshotBytes += bytes;
    }
    public void SaveSnapshot(string key, JsonElement value)
    {
        var path = SnapshotPath(key); var text = value.GetRawText(); AtomicWrite(path, text);
        lock (_snapshotGate) RememberLocked(path, value, DateTimeOffset.UtcNow, text.Length);
        CacheFiles.Prune(Path.Combine(_store, "Bangumi"), 64L * 1024 * 1024, CacheFiles.HashedJson, TimeSpan.FromDays(30), path);
    }
    /// 批量写入同一目录下的多个快照：只做一次缓存维护，供同步与日历页使用。
    public void SaveSnapshots(IEnumerable<(string Key, JsonElement Value)> values)
    {
        var count = 0; string? last = null;
        foreach (var (key, value) in values)
        {
            var path = SnapshotPath(key); var text = value.GetRawText(); AtomicWrite(path, text);
            lock (_snapshotGate) RememberLocked(path, value, DateTimeOffset.UtcNow, text.Length);
            last = path; count++;
        }
        if (count > 0) CacheFiles.Prune(Path.Combine(_store, "Bangumi"), 64L * 1024 * 1024, CacheFiles.HashedJson, TimeSpan.FromDays(30), last);
    }
    public void ClearSnapshot(string key)
    {
        var path = SnapshotPath(key);
        lock (_snapshotGate) if (_snapshotMemory.TryGetValue(path, out var entry)) { _snapshotMemory.Remove(path); _snapshotBytes -= entry.Bytes; }
        if (File.Exists(path)) File.Delete(path);
    }
    public async Task<JsonElement> CachedBgm(string method, object? args, string key, CancellationToken token)
    { var value = await Bgm(method, args, token); SaveSnapshot(key, value); return value; }
    public async Task<JsonElement?> SubjectCollection(long id, CancellationToken token)
    {
        var account = RequireAccount(Bangumi, "Bangumi");
        var response = await Bgm("request", new { url = account.BaseUrl + "v0/users/" + Uri.EscapeDataString(account.UserName) + "/collections/" + id, httpMethod = "GET" }, token);
        if (Json.Number(response, "status") == 404) { ClearSnapshot("collection:" + id); return null; }
        var value = DecodeBangumi(response); SaveSnapshot("collection:" + id, value); return value;
    }
    public async Task UpdateSubjectCollection(long id, CancellationToken token, int? type = null, int? rate = null)
    {
        var body = new JsonObject(); if (type is { } state) body["type"] = state; if (rate is { } score) body["rate"] = score;
        await Bgm("updateSubject", new { subjectId = id, body }, token);
        var previous = Snapshot("collection:" + id); var interest = previous ?? default;
        if (Json.Get(Json.Subject(interest), "interest").ValueKind == JsonValueKind.Object) interest = Json.Get(Json.Subject(interest), "interest");
        var saved = interest.ValueKind == JsonValueKind.Object ? JsonNode.Parse(interest.GetRawText())!.AsObject() : new JsonObject();
        saved.Remove("subject");
        foreach (var (key, value) in body) saved[key] = value?.DeepClone();
        SaveSnapshot("collection:" + id, JsonSerializer.SerializeToElement(saved));
        if (Snapshot("subject:" + id) is { } subject) { var updated = JsonNode.Parse(subject.GetRawText())!.AsObject(); updated["interest"] = saved.DeepClone(); SaveSnapshot("subject:" + id, JsonSerializer.SerializeToElement(updated)); }
        Changed?.Invoke();
    }
    public async Task UpdateEpisodeCollection(long subjectId, long episodeId, int state, bool batch, CancellationToken token)
    {
        await Bgm("updateEpisode", new { episodeId, collectionType = state, batch }, token);
        if (Snapshot("episodes:" + subjectId) is { } snapshot)
        {
            var episodes = Json.Items(snapshot); var selected = episodes.FirstOrDefault(x => Json.Number(x, "id") == episodeId); var sort = Json.Number(selected, "sort");
            var updated = episodes.Select(episode =>
            {
                var node = JsonNode.Parse(episode.GetRawText())!.AsObject();
                if (Json.Number(episode, "id") == episodeId || batch && Json.Number(episode, "type") == 0 && Json.Number(episode, "sort") <= sort && EpisodeAired(episode))
                { var collection = node["collection"] as JsonObject ?? new JsonObject(); collection["status"] = state; if (node["collection"] is not JsonObject) node["collection"] = collection; }
                return node;
            }).ToArray();
            SaveSnapshot("episodes:" + subjectId, JsonSerializer.SerializeToElement(updated));
        }
        Changed?.Invoke();
    }
    public Task<JsonElement> CollectionPage(int type, int subjectType, int offset, CancellationToken token, int limit = 100) =>
        Bgm("collections", new { collectionType = type, subjectType, limit, offset }, token);
    public async Task<JsonElement[]> Watching(CancellationToken token, TimeSpan? maxAge = null)
    { var batches = await Task.WhenAll(Collections(3, token, 2, maxAge), Collections(3, token, 6, maxAge)); return batches.SelectMany(x => x).ToArray(); }
    public async Task SynchronizeCollections(Action<int>? progress, CancellationToken token)
    {
        var count = 0; var identifiers = new HashSet<long>();
        foreach (var kind in new[] { 1, 2, 3, 4, 6 }) foreach (var type in Enumerable.Range(1, 5))
        {
            var rows = await Collections(type, token, kind, TimeSpan.Zero); // Collections 已按同一 key 写入快照
            foreach (var row in rows)
            {
                var subject = Json.Subject(row); var id = (long)Json.Number(subject, "id", Json.Number(row, "subject_id"));
                identifiers.Add(id);
                SaveSnapshot("subject:" + id, subject); SaveSnapshot("collection:" + id, row);
                if (kind is 2 or 6) SaveSnapshot("episodes:" + id, JsonSerializer.SerializeToElement(await Episodes(id, token, TimeSpan.Zero)));
                progress?.Invoke(++count);
            }
        }
        if (Snapshot("collection-index") is { } prior) foreach (var old in Json.OptionalItems(prior).Where(x => x.ValueKind == JsonValueKind.Number).Select(x => x.GetInt64()).Where(x => !identifiers.Contains(x))) ClearSnapshot("collection:" + old);
        SaveSnapshot("collection-index", JsonSerializer.SerializeToElement(identifiers));
        SetPreference("bangumi.lastSync", DateTimeOffset.Now.ToString("O")); Changed?.Invoke();
    }
    private string LinksPath => Path.Combine(_store, "bangumi-links.json");
    public BangumiMediaLink[] Links()
    { try { return File.Exists(LinksPath) ? JsonSerializer.Deserialize<BangumiMediaLink[]>(File.ReadAllText(LinksPath)) ?? [] : []; } catch (Exception ex) when (ex is JsonException or IOException) { return []; } }
    private static string SeriesKey(DemoMedia media) => media.SeriesId ?? media.Id;
    public BangumiMediaLink? ResolveBangumiLink(string source, DemoMedia media)
    {
        var id = SeriesKey(media); var season = media.SeasonNumber ?? (media.Seasons?.FirstOrDefault(x => x.Id == media.SelectedSeasonId)?.Number);
        return Links().FirstOrDefault(x => x.Source == source && x.SeriesId == id && x.Season == season) ??
            (season is null or 1 ? Links().FirstOrDefault(x => x.Source == source && x.SeriesId == id && x.Season is null) : null);
    }
    public void LinkBangumi(string source, DemoMedia media, long subjectId, string title)
    {
        if (subjectId <= 0) throw new ArgumentException("条目编号无效。");
        var season = media.SeasonNumber ?? media.Seasons?.FirstOrDefault(x => x.Id == media.SelectedSeasonId)?.Number;
        var link = new BangumiMediaLink(source, SeriesKey(media), season, subjectId, title);
        var links = Links().Where(x => !(x.Source == source && x.SeriesId == link.SeriesId && x.Season == season)).Append(link).ToArray();
        AtomicWrite(LinksPath, JsonSerializer.Serialize(links)); Changed?.Invoke();
    }
    public async Task<JsonElement[]> BangumiCandidates(DemoMedia media, CancellationToken token) =>
        Json.Items(await Bgm("search", new { keyword = media.SeriesTitle ?? media.Title, subjectType = 0, limit = 100, offset = 0 }, token));
    public async Task<BangumiMediaLink?> AutoLinkBangumi(string source, DemoMedia media, CancellationToken token)
    {
        var rows = await BangumiCandidates(media, token);
        var names = new[] { media.SeriesTitle, media.Title, media.OriginalTitle }.Where(x => !string.IsNullOrEmpty(x)).Select(x => BroadcastTimeline.Normalize(x!)).ToHashSet();
        var candidates = rows.Where(x => Json.Number(x, "type") is 2 or 6 && new[] { Json.Title(x), Json.Text(x, "name") }.Any(y => names.Contains(BroadcastTimeline.Normalize(y)))).ToArray();
        if (candidates.Length != 1) return null;
        LinkBangumi(source, media, (long)Json.Number(candidates[0], "id"), Json.Title(candidates[0])); return ResolveBangumiLink(source, media);
    }
    internal static int EpisodeStatus(JsonElement episode) => (int)Json.Number(Json.Get(episode, "collection"), "status", Json.Number(Json.Get(episode, "collection"), "type"));
    internal static bool EpisodeAired(JsonElement episode) => DateTime.TryParse(Json.First(episode, "airdate", "airDate"), out var date) && date.Date <= DateTime.Today;
    public async Task MarkLinkedEpisodeWatched(string source, DemoMedia media, int episodeNumber, CancellationToken token)
    {
        if (Bangumi is not { Enabled: true, AccessToken.Length: > 0 } || ResolveBangumiLink(source, media) is not { } link) return;
        var rows = await Episodes(link.SubjectId, token);
        var episode = rows.FirstOrDefault(x => Json.Number(x, "type") == 0 && Json.Number(x, "sort") == episodeNumber);
        if (episode.ValueKind != JsonValueKind.Object || !EpisodeAired(episode)) return;
        await UpdateEpisodeCollection(link.SubjectId, (long)Json.Number(episode, "id"), 2, false, token);
        var main = rows.Where(x => Json.Number(x, "type") == 0).ToArray();
        if (main.Length > 0 && main.All(x => Json.Number(x, "id") == Json.Number(episode, "id") || EpisodeStatus(x) == 2))
            await UpdateSubjectCollection(link.SubjectId, token, type: 2);
        SaveSnapshot("episodes:" + link.SubjectId, JsonSerializer.SerializeToElement(await Episodes(link.SubjectId, token))); Changed?.Invoke();
    }
}

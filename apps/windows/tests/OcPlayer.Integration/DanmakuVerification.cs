using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using OcPlayer.CoreAdapter;
using OcPlayer.Tests;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;

internal static partial class Program
{
    private static DanmakuPayload? _verifiedDanmaku;

    private static async Task VerifyDanmaku(OcpCoreClient core, string data)
    {
        using var fixture = new DanmakuFixture();
        string? saved = null;
        var settings = new DanmakuSettings(() => saved, value => saved = value);
        Assert(settings.Current.AutoLoad && settings.Current.Enabled && settings.Current.EffectiveUrl == DanmakuPreferences.DefaultGateway,
            "danmaku defaults match OcPlayer and work without manual gateway setup");
        foreach (var damaged in new[] { "{", "null", "{\"GatewayUrl\":null}", "{\"ApiKey\":null}", "{\"FontSize\":1000}" })
        {
            var recovered = new DanmakuSettings(() => damaged, _ => throw new Exception("Must preserve the damaged credential"));
            Assert(!recovered.Current.AutoLoad && recovered.LoadWarning is not null,
                "damaged danmaku preferences suspend automatic loading without preventing playback");
        }
        settings.Save(settings.Current with { GatewayUrl = fixture.Url, ApiKey = "fixture-danmaku-key", Opacity = .65 });
        var restored = new DanmakuSettings(() => saved, value => saved = value);
        Assert(restored.Current.Opacity == .65 && restored.Current.EffectiveKey == "fixture-danmaku-key", "danmaku settings restore after restart");
        try { settings.Save(settings.Current with { GatewayUrl = "https://another.example", ApiKey = "" }); throw new Exception("Expected custom gateway validation"); }
        catch (ArgumentException) { Assert(settings.Current.GatewayUrl == fixture.Url, "invalid custom gateway does not replace saved configuration"); }
        var failingStore = new DanmakuSettings(() => saved, _ => throw new IOException("fixture storage failure"));
        try { failingStore.Save(failingStore.Current with { Enabled = false }); throw new Exception("Expected storage failure"); }
        catch (IOException) { Assert(failingStore.Current.Enabled, "failed preference save preserves the previous state"); }
        foreach (var address in new[] { "http://example.com", "https://user:password@example.com", "https://example.com?key=value", "https://example.com#fragment" })
        {
            try { DanmakuPreferences.NormalizeGateway(address); throw new Exception("Expected invalid address"); }
            catch (ArgumentException) { }
        }
        Assert(DanmakuPreferences.NormalizeGateway("example.com/proxy/") == "https://example.com/proxy", "gateway normalization supports HTTPS reverse proxy prefixes");

        var directory = Path.Combine(data, "danmaku-fixture"); Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "葬送的芙莉莲.S01E01.mkv");
        await File.WriteAllBytesAsync(path, Encoding.UTF8.GetBytes("small deterministic video fingerprint fixture"));
        var media = new DemoMedia("danmaku-video", "葬送的芙莉莲", "", "", "", "", "", SourceUri: path);
        var service = new DanmakuService(core, directory, settings, aliasProvider: (_, _) => Task.FromResult(Array.Empty<string>()), introProvidersEnabled: false);
        var context = service.Context(media, new PlaybackSource(media.Id, media.Title, path));
        Assert(context.EpisodeNumber == 1 && context.SeasonNumber == 1 && context.AllowsCachedMatchReuse && context.AnimeTitle == media.Title,
            $"Core filename parsing supplies local episode identity (title={context.AnimeTitle}, episode={context.EpisodeNumber}, season={context.SeasonNumber})");
        var changed = service.Context(media, new PlaybackSource(media.Id, media.Title, path));
        Assert(context.CacheKey == changed.CacheKey, "unchanged files have stable danmaku mapping keys");
        File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddMinutes(1));
        Assert(service.Context(media, new PlaybackSource(media.Id, media.Title, path)).CacheKey != context.CacheKey,
            "replacing a local video invalidates its remembered match");
        var seasonDir = Path.Combine(directory, "葬送的芙莉莲", "Season 2"); Directory.CreateDirectory(seasonDir);
        var shortPath = Path.Combine(seasonDir, "01.mkv"); await File.WriteAllBytesAsync(shortPath, [1, 2, 3]);
        var inferred = service.Context(media, new PlaybackSource("short", "01", shortPath));
        Assert(inferred.AnimeTitle == media.Title && inferred.SeasonNumber == 2, "short filenames infer series and season from parent folders");
        var report = new PlaybackReport(JsonSerializer.SerializeToElement(new { }), "episode-2", "version-1", "session-1");
        var serverSource = new PlaybackSource("episode-2", media.Title, fixture.Url + "stream?api_key=secret", "server:user", Report: report,
            Metadata: new("/library/S02E02.mkv", 100, 1440, media.Title, null, 2, 2, SeriesTmdbId: 123));
        var serverContext = service.Context(media, serverSource);
        Assert(serverContext.FileName == $"{media.Title} 第2季 第02话" && serverContext.SeasonNumber == 2 && serverContext.EpisodeNumber == 2 && serverContext.SeriesTmdbId == 123,
            "server metadata uses canonical series, season and episode naming with TMDB identity");
        var numberedSource = serverSource with { Metadata = serverSource.Metadata! with { FileName = "/library/02 1080.mkv" } };
        Assert(service.Context(media, numberedSource).FileName == $"{media.Title} 第2季 第02话", "canonical filename never appends an unrelated raw numeric suffix");
        var specialSource = serverSource with { Metadata = serverSource.Metadata! with { SeasonNumber = 0, EpisodeNumber = 2, FileName = "bonus.mkv" } };
        var special = service.Context(media, specialSource);
        Assert(special.Special is { index: 2 } && special.Special.kinds.SequenceEqual(new[] { "special", "extra", "other" }) && special.FileName == $"{media.Title} SP2",
            "season zero has a special namespace and S/C/O fallback instead of ordinary episode matching");
        Assert(service.Context(media, serverSource with { Uri = fixture.Url + "stream?api_key=rotated" }).CacheKey == serverContext.CacheKey,
            "server mapping identity does not depend on rotating playback credentials");
        Assert(!service.Context(media, new PlaybackSource("url", "url", fixture.Url + "video.mkv")).AllowsCachedMatchReuse,
            "unversioned direct URLs do not reuse a potentially stale match");

        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var payload = await service.Load(context, false, null, timeout.Token);
        Assert(payload.Kind == "loaded" && payload.Count == 3 && payload.ShiftSeconds == 2 && payload.Match?.EpisodeId == 1010001 && !string.IsNullOrEmpty(payload.Json),
            "real Core matches a file, converts valid comments and preserves provider timing shift");
        _verifiedDanmaku = payload;
        Assert(fixture.LastHash == Convert.ToHexStringLower(MD5.HashData(await File.ReadAllBytesAsync(path))) && fixture.HeadersCorrect,
            "hash matching sends the exact head MD5 and configured gateway authentication");
        var requests = fixture.Requests;
        fixture.Reject = true;
        Assert((await service.Load(context, false, null, timeout.Token)).Count == 3 && fixture.Requests == requests,
            "cached mapping and comments load while the gateway is unavailable");
        // Reopen the cache to prove persistence, not just an in-memory hit.
        service = new DanmakuService(core, directory, restored, aliasProvider: (_, _) => Task.FromResult(Array.Empty<string>()), introProvidersEnabled: false);
        Assert((await service.Load(context, false, null, timeout.Token)).Count == 3 && fixture.Requests == requests,
            "danmaku mappings and comments survive reopening the service");
        fixture.Reject = false;
        var results = await service.Search(media.Title, "SP1", timeout.Token);
        Assert(results.Length == 1 && results[0].Episodes.Length == 2 && fixture.LastSearch.Contains("episode=SP1"),
            "manual search lists episodes and preserves special episode tokens");
        var manual = results[0].Episodes[1];
        var selected = await service.Load(context, false, manual, timeout.Token);
        Assert(selected.Title.Contains("第2集") && selected.ShiftSeconds == 0, "manual selection replaces the automatic match");
        requests = fixture.Requests;
        Assert((await service.Load(context, false, null, timeout.Token)).Title.Contains("第2集") && fixture.Requests == requests,
            "manual correction is remembered for subsequent playback");
        Assert((await service.Load(context, true, null, timeout.Token)).Title.Contains("第1集") && fixture.Requests > requests,
            "force rematch bypasses a remembered manual correction");
        var empty = await service.Load(context, false, new(1010003, 101, media.Title, "第3集"), timeout.Token);
        Assert(empty.Kind == "empty" && empty.Json is null, "empty comments are distinct from a successful rendered payload");
        fixture.NoMatches = true;
        Assert((await service.Load(context, true, null, timeout.Token)).Kind == "noMatch", "no automatic candidate produces a recoverable no-match outcome");
        fixture.NoMatches = false; fixture.Reject = true;
        try { await service.Search("test", "", timeout.Token); throw new Exception("Expected unauthorized search"); }
        catch (InvalidOperationException ex) { Assert(ex.Message.Contains("API Key") && !ex.Message.Contains("fixture-danmaku-key"), "gateway errors are actionable and never expose credentials"); }
        try { await service.Load(context, true, null, timeout.Token); throw new Exception("Expected unauthorized automatic match"); }
        catch (InvalidOperationException ex) { Assert(ex.Message.Contains("API Key"), "automatic matching reports invalid credentials rather than claiming no episode matched"); }
        fixture.Reject = false;
        var tmdbContext = serverContext with { CacheKey = "tmdb-fixture", SeasonNumber = 1, EpisodeNumber = 1,
            Source = serverSource with { Uri = "unavailable-fingerprint" } };
        Assert((await service.Load(tmdbContext, true, null, timeout.Token)).Kind == "loaded" && fixture.LastSearch.Contains("tmdbId=123"),
            "series TMDB identity participates in fallback matching when the media fingerprint is unavailable");
        fixture.DelaySearch = new(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.DelayMatch = new(TaskCreationOptions.RunContinuationsAsynchronously);
        var stale = service.Load(context, true, null, timeout.Token);
        await fixture.MatchEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await service.Load(context, false, manual, timeout.Token);
        fixture.DelayMatch.TrySetResult();
        var superseded = false;
        try { await stale; }
        catch (InvalidOperationException) { superseded = true; }
        fixture.DelayMatch = null;
        Assert(superseded && (await service.Load(context, false, null, timeout.Token)).Title.Contains("第2集"),
            "late automatic responses cannot overwrite a newer manual correction in the persistent Core cache");
        using (var cancelled = new CancellationTokenSource())
        {
            var search = service.Search("cancel", "", cancelled.Token);
            await fixture.SearchEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            cancelled.Cancel();
            try { await search; throw new Exception("Expected cancellation"); }
            catch (OperationCanceledException) { Assert(true, "manual search cancellation propagates through the real Core request"); }
            finally { fixture.DelaySearch.TrySetResult(); }
        }
        await VerifyDanmakuRaces(context);
        await VerifyDanmakuFingerprint();
        Evidence.Add(new { stage = "danmaku", validComments = payload.Count, gatewayRequests = fixture.Requests, fixture.HeadersCorrect });
    }

    private static async Task VerifyDanmakuRaces(DanmakuContext context)
    {
        var older = new TaskCompletionSource<DanmakuPayload>(TaskCreationOptions.RunContinuationsAsynchronously);
        var current = new TaskCompletionSource<DanmakuPayload>(TaskCreationOptions.RunContinuationsAsynchronously);
        var applied = new List<string>(); var cleared = 0; var calls = 0;
        using var coordinator = new DanmakuCoordinator((_, _, _, _) => ++calls == 1 ? older.Task : current.Task,
            () => true, payload => applied.Add(payload.Title), () => cleared++);
        coordinator.Start(context, true); var previous = coordinator.Completion;
        coordinator.Start(context with { CacheKey = "next-source" }, true);
        current.SetResult(new("loaded", "new", 1, "{}", Match: new(2, 1, "show", "new"))); await coordinator.Completion;
        older.SetResult(new("loaded", "old", 1, "{}", Match: new(1, 1, "show", "old"))); await previous;
        Assert(applied.SequenceEqual(["new"]) && coordinator.Status.StartsWith("new"), "late results cannot replace a newer source's danmaku or status");
        Assert(coordinator.CurrentMatch?.EpisodeId == 2, "late results cannot replace the current-match marker in manual search");
        coordinator.Start(context with { CacheKey = "disabled-next-source" }, false);
        Assert(coordinator.CurrentMatch is null, "switching sources clears the previous match marker even with automatic loading disabled");
        var loading = new TaskCompletionSource<DanmakuPayload>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var local = new DanmakuCoordinator((_, _, _, _) => loading.Task, () => true, p => applied.Add(p.Title), () => cleared++);
        local.Start(context, true); var online = local.Completion;
        local.LoadLocal("manual.xml", _ => applied.Add("local")); await local.Completion;
        loading.SetResult(new("loaded", "late-online", 1, "{}")); await online;
        Assert(applied.Last() == "local" && !applied.Contains("late-online"), "local import cancels and supersedes an automatic request");
        using var marked = new DanmakuCoordinator((_, _, _, _) => Task.FromResult(new DanmakuPayload("loaded", "marked", 1, "{}",
            Match: new(3, 1, "show", "marked"))), () => true, _ => { }, () => { });
        marked.Start(context, true); await marked.Completion;
        marked.LoadLocal("manual.xml", _ => { }); await marked.Completion;
        Assert(marked.CurrentMatch is null, "local import removes the online episode's current-match marker");
        using var empty = new DanmakuCoordinator((_, _, _, _) => Task.FromResult(new DanmakuPayload("empty", "empty", 0, null)),
            () => true, _ => throw new Exception("Must clear empty payload"), () => cleared++);
        empty.Start(context, true); await empty.Completion;
        Assert(cleared == 1 && !empty.Busy, "empty episode clears stale onscreen danmaku");
        var deferred = new TaskCompletionSource<DanmakuPayload>(TaskCreationOptions.RunContinuationsAsynchronously);
        var disposed = new DanmakuCoordinator((_, _, _, _) => deferred.Task, () => true, _ => applied.Add("disposed"), () => cleared++);
        disposed.Start(context, true); var inFlight = disposed.Completion; disposed.Dispose();
        deferred.SetResult(new("loaded", "disposed", 1, "{}")); await inFlight;
        Assert(!applied.Contains("disposed"), "closing the player prevents delayed native renderer access");
        var ready = false;
        using var waiting = new DanmakuCoordinator((_, _, _, _) => Task.FromResult(new DanmakuPayload("loaded", "ready", 1, "{}")),
            () => ready, p => applied.Add(p.Title), () => cleared++);
        waiting.Start(context, true);
        Assert(!applied.Contains("ready"), "danmaku waits for the decoder to be ready");
        ready = true; await waiting.Completion;
        Assert(applied.Last() == "ready", "pending danmaku applies once the decoder becomes ready");
        waiting.Start(context, false);
        Assert(waiting.Status == "自动加载已关闭" && !waiting.Busy, "disabled automatic loading starts no new request");
    }

    private static async Task VerifyDanmakuFingerprint()
    {
        var bytes = Encoding.UTF8.GetBytes("bounded media bytes");
        using var handler = new FingerprintHandler(bytes);
        using var client = new HttpClient(handler);
        var hash = await DanmakuFingerprint.ReadRemote("https://media.example/video", new Dictionary<string, string> { ["Authorization"] = "media-token" }, bytes.Length, default, client);
        Assert(hash == Convert.ToHexStringLower(MD5.HashData(bytes)) && handler.SawHeaders, "remote fingerprints hash authenticated range responses");
        handler.InvalidRange = true;
        Assert(await DanmakuFingerprint.ReadRemote("https://media.example/video", null, null, default, client) is null,
            "incorrect Content-Range does not generate a false fingerprint");
        handler.InvalidRange = false; handler.IgnoredRange = true;
        Assert(await DanmakuFingerprint.ReadRemote("https://media.example/video", null, bytes.Length, default, client) is null && handler.LastStream!.ReadBytes == 0,
            "ignored Range on a large response is rejected before reading the body");
        handler.IgnoredRange = false; handler.Truncated = true;
        Assert(await DanmakuFingerprint.ReadRemote("https://media.example/video", null, bytes.Length, default, client) is null,
            "truncated range responses are rejected instead of hashing incomplete bytes");
    }

    private static void VerifyDanmakuRenderer(PlaybackSession session)
    {
        session.ConfigureDanmaku(new DanmakuPreferences().Renderer);
        session.LoadDanmakuJson(_verifiedDanmaku!.Json!); session.SetDanmakuOffset(_verifiedDanmaku.ShiftSeconds);
        Assert(session.DanmakuTracks.GetArrayLength() == 1 && Json.Number(session.DanmakuTracks[0], "itemCount") == 3,
            "real Erika accepts Core's converted danmaku payload");
        session.SetDanmaku(false); session.SetDanmaku(true); session.SetDanmakuOffset(-.5);
        session.ClearDanmaku();
        Assert(session.DanmakuTracks.GetArrayLength() == 0, "native danmaku clear removes the previous track");
        session.LoadDanmakuJson(_verifiedDanmaku.Json!);
    }

    private sealed class FingerprintHandler(byte[] bytes) : HttpMessageHandler
    {
        public bool SawHeaders, InvalidRange, IgnoredRange, Truncated;
        public CountingStream? LastStream;
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            SawHeaders = request.Headers.Range?.ToString() == "bytes=0-16777215" && request.Headers.Authorization?.ToString() == "media-token";
            LastStream = new CountingStream(Truncated ? bytes[..^1] : bytes);
            var response = new HttpResponseMessage(IgnoredRange ? HttpStatusCode.OK : HttpStatusCode.PartialContent) { Content = new StreamContent(LastStream) };
            response.Content.Headers.ContentLength = IgnoredRange ? 100_000_000 : bytes.Length;
            if (!IgnoredRange) response.Content.Headers.ContentRange = new ContentRangeHeaderValue(InvalidRange ? 1 : 0, bytes.Length - 1, bytes.Length);
            return Task.FromResult(response);
        }
    }
    private sealed class CountingStream(byte[] bytes) : MemoryStream(bytes)
    {
        public long ReadBytes;
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        { var count = await base.ReadAsync(buffer, cancellationToken); ReadBytes += count; return count; }
    }

}

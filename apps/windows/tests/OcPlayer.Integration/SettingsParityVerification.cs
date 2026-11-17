using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;

internal static partial class Program
{
    private static async Task VerifySettingsParity(OcpCoreClient core, string data)
    {
        var original = RuntimeSettings.Current;
        var preference = new RuntimePreferences(NetworkBufferMiB: 32, BackBufferMiB: 128, SkipIntro: false, SkipOutro: false, OutroRetainSeconds: 30,
            SubtitleLanguage: "off", SubtitlePosition: "bottom-right", SubtitleMargin: 200, SubtitleColor: "#AABBCC80", SubtitleOutlineColor: "#000000FF", SubtitleOutlineWidth: 32,
            SubtitleBold: false, OverrideSubtitleStyles: true, QualityEnhancement: "artcnn-f32", UserAgent: "fixture\r\nUA", DetailedLogging: true, DanmakuDiagnostics: true);
        var changes = 0; void Changed(RuntimePreferences _) => changes++;
        RuntimeSettings.Changed += Changed;
        RuntimeSettings.Save(preference);
        Assert(RuntimeSettings.Current.UserAgent == "fixtureUA" && changes == 1, "global User-Agent strips controls and publishes the saved setting immediately");
        var persisted = JsonSerializer.Deserialize<RuntimePreferences>(await File.ReadAllTextAsync(Path.Combine(data, "runtime-settings.json")));
        Assert(persisted?.BackBufferMiB == 128 && persisted.SubtitleBold == false && persisted.SubtitleColor == "#AABBCC80" && persisted.SubtitleLanguage == "off",
            "real runtime settings persist largest buffer, explicit non-bold, RGBA and subtitles off");
        foreach (var value in new[] { 11d, 44d }) Assert(new DanmakuPreferences(FontSize: value, UseKernelRenderer: false, AnimeSkipClientId: "fixture").Validated().FontSize == value,
            "danmaku accepts both endpoints of the full 11–44 point range");
        try { RuntimeSettings.Save(preference with { SubtitleColor = "white" }); throw new InvalidOperationException("Expected invalid RGBA"); } catch (ArgumentException) { }
        Assert(RuntimeSettings.Current.SubtitleColor == "#AABBCC80", "invalid subtitle input cannot replace a valid saved value");
        Assert(TmdbPreferences.Normalize("api.example", false) == "https://api.example/3" && TmdbPreferences.Normalize("https://images.example/t/p/w780/poster.jpg", true) == "https://images.example/t/p",
            "TMDB domain and pasted image normalization match the actual request roots");
        Assert(TmdbPreferences.Normalize("https://api.example/proxy/v3", false) == "https://api.example/proxy/v3", "custom TMDB proxy paths are preserved");
        using var fixture = new SettingsHttpFixture();
        var resource = "OcPlayer.SettingsParity." + Guid.NewGuid().ToString("N");
        try
        {
            using var runtime = new CoreRuntime(resource);
            runtime.Tmdb.Settings.Save(new TmdbPreferences(ApiKey: "fixture-tmdb-secret", PreferText: true, ReplaceImages: true, UseMirror: true,
                ApiMirror: fixture.Url + "3", ImageMirror: fixture.Url + "t/p"));
            var media = new DemoMedia("movie", "Untranslated", "", "2024", "", "", "", TmdbId: 7);
            var enriched = await runtime.Tmdb.Enrich(media, "fixture", default);
            Assert(enriched.Title == "English fallback" && enriched.Description == "English synopsis" && enriched.Artwork == fixture.Url + "t/p/w780/poster.jpg",
                "TMDB requests use configured mirror and apply Core English fallback with rewritten artwork");
            Assert(fixture.Requests.Any(x => x.Contains("language=zh-CN")) && fixture.Requests.Any(x => x.Contains("language=en-US")), "TMDB fallback makes real primary and English requests");
            var series = new DemoMedia("show", "Series", "", "2024", "", "", "", Kind: "series", SelectedSeasonId: "tmdb:2", SeasonNumber: 1, TmdbId: 8,
                Episodes: [new DemoEpisode(1, "wrong season", "", SeasonNumber: 1)]);
            var show = await runtime.Tmdb.Enrich(series, "fixture", default);
            Assert(show.Episodes is { Length: 2 } && show.Episodes.All(x => x.SeasonNumber == 2 && !x.Available) && show.Episodes[0].Overview == "Episode overview"
                && show.Episodes[1].AirDate == "2099-01-01" && show.SeasonOverview == "Season overview", "synthetic TMDB season uses its own episodes, descriptions, air dates and unavailable state");
            runtime.Tmdb.Bind(media, "fixture", null);
            var unlinked = await runtime.Tmdb.Enrich(media, "fixture", default);
            Assert(unlinked == media && runtime.Tmdb.MatchKey(media, "fixture") is null, "explicit unlink suppresses immediate automatic reassociation");
            runtime.Tmdb.Bind(media, "fixture", "movie/7");
            Assert((await runtime.Tmdb.Enrich(media, "fixture", default)).Title == "English fallback", "manual TMDB association re-enables enrichment");
            var server = new MediaServer(runtime.Client, new ServerProfile("batch", "jellyfin", fixture.Url.TrimEnd('/'), "user", "fixture-token"));
            using (var cancel = new CancellationTokenSource())
            {
                await runtime.Tmdb.EnrichLibrary(server, new InlineSettingsProgress(value => { if (value.Completed == 1) cancel.Cancel(); }), cancel.Token);
                Assert(runtime.Tmdb.LastBatch is { Cancelled: true, Completed: 1 }, "batch cancellation preserves its exact processed count and resumable state");
            }
            await runtime.Tmdb.EnrichLibrary(server, null, default);
            Assert(runtime.Tmdb.LastBatch is { Completed: 3, Total: 3, Added: 1, Skipped: 1, Unmatched: 1, Failed: 0, Seasons: 2 },
                "batch resumes successful mappings, enriches remaining series seasons, and distinguishes unmatched items");
            var tmdbRequests = fixture.Requests.Count(x => x.StartsWith("/3/movie/") || x.StartsWith("/3/tv/"));
            await runtime.Tmdb.EnrichLibrary(server, null, default);
            Assert(runtime.Tmdb.LastBatch is { Skipped: 2, Unmatched: 1 } && tmdbRequests == fixture.Requests.Count(x => x.StartsWith("/3/movie/") || x.StartsWith("/3/tv/")),
                "rerunning completed batch reuses successful entities and seasons without refetching them");
            runtime.Integrations.ConfigureMirror(true, "bangumi.example");
            runtime.Danmaku.Settings.Save(new DanmakuPreferences(FontSize: 44, UseKernelRenderer: false, AnimeSkipClientId: "fixture-client"));
            var json = SettingsBackup.Export(runtime, ["媒体库", "继续观看", "接下来看", "最近添加"], ["继续观看"], "light", true);
            var prepared = SettingsBackup.Prepare(runtime, json);
            Assert(prepared.Playback.SubtitleColor == "#AABBCC80" && prepared.Playback.SubtitleBold == false && prepared.Danmaku.FontSize == 44 && !prepared.Danmaku.UseKernelRenderer
                && prepared.Tmdb.ApiKey == "fixture-tmdb-secret" && prepared.HiddenSections!.SequenceEqual(new[] { "继续观看" }) && prepared.EpisodesDescending == true,
                "portable backup validates and round-trips playback, tri-state/alpha style, renderer, TMDB credential, home layout and episode ordering");
            Assert(!prepared.Preview.Contains("fixture-tmdb-secret") && prepared.Preview.Contains("cret") && prepared.Preview.Contains("bangumi.example"), "restore preview shows credential tail and mirror details without exposing full key");
            RuntimeSettings.Save(new RuntimePreferences());
            SettingsBackup.Restore(runtime, prepared);
            Assert(RuntimeSettings.Current.BackBufferMiB == 128 && runtime.Integrations.MirrorRoot == "bangumi.example" && runtime.Danmaku.Settings.Current.AnimeSkipClientId == "fixture-client",
                "confirmed restore changes the actual runtime and secure preference stores");
            using (var exported = JsonDocument.Parse(json))
            {
                var native = exported.RootElement.GetProperty("general").GetProperty("homeSections").GetString();
                Assert(native == "libraries,-resume,nextUp,latest", "backup exports original OcPlayer home-section tokens, including hidden positions");
            }
            var before = RuntimeSettings.Current;
            try { SettingsBackup.Prepare(runtime, json.Replace("#AABBCC80", "bad-color", StringComparison.Ordinal)); throw new InvalidOperationException("Expected malformed settings failure"); }
            catch (ArgumentException) { Assert(RuntimeSettings.Current == before, "invalid backup is rejected before any settings mutation"); }
            AppDiagnostics.Clear(); RuntimeSettings.Save(RuntimeSettings.Current with { DetailedLogging = true, DanmakuDiagnostics = false }); AppDiagnostics.ConfigureNativeTrace();
            Assert(Environment.GetEnvironmentVariable("ERIKA_PLAYBACK_TRACE") == "1" && Environment.GetEnvironmentVariable("ERIKA_CAPI_TRACE_FILE") == AppDiagnostics.NativeTracePaths[1],
                "opening playback applies detailed native trace switches and application-owned log paths");
            RuntimeSettings.Save(RuntimeSettings.Current with { DetailedLogging = false, DanmakuDiagnostics = true });
            Assert(Environment.GetEnvironmentVariable("ERIKA_PLAYBACK_TRACE") == "1" && Environment.GetEnvironmentVariable("ERIKA_DANMAKU_TRACE") == "1",
                "native playback verbosity waits for next open while danmaku trace follows its independent switch immediately");
            AppDiagnostics.Write("debug", "filtered application detail"); AppDiagnostics.Write("debug", "danmaku timeline", danmaku: true);
            AppDiagnostics.Write("info", "url https://example.invalid/video?api_key=secret token=secret");
            var log = await AppDiagnostics.Read(); Assert(log.Count == 2 && log.Recent.Any(x => x.Message == "danmaku timeline") && log.Recent.All(x => !x.Message.Contains("secret")),
                "danmaku diagnostics are independent of detailed logging and exported log content redacts URL credentials");
            await File.WriteAllTextAsync(AppDiagnostics.NativeTracePaths[0], "native trace fixture token=fixture-private https://host.invalid/media?api_key=fixture-private");
            var diagnosticPath = Path.Combine(data, "diagnostic-fixture.txt");
            PlaybackSession.Require(runtime.Client.Call("diag.exportFile", new { logDirectory = AppDiagnostics.DirectoryPath, outputPath = diagnosticPath, headerLines = new[] { "settings fixture" },
                bodyByteBudget = 1024 * 1024, traces = new[] { new { path = AppDiagnostics.NativeTracePaths[0], name = "native trace", maxBytes = 4096 } }, username = "fixture-user" }));
            var diagnostic = await File.ReadAllTextAsync(diagnosticPath);
            Assert(diagnostic.Contains("native trace fixture") && diagnostic.Contains("danmaku timeline") && !diagnostic.Contains("fixture-private"),
                "diagnostic export includes actual app logs and native trace tail while redacting credentials");
            AppDiagnostics.Clear(); Assert(!File.Exists(AppDiagnostics.NativeTracePaths[0]) && (await AppDiagnostics.Read()).Count == 0, "clear logs removes both app records and native trace files");
            var image = await ImageDiskCache.Resolve(fixture.Url + "poster.jpg");
            Assert(File.Exists(image) && !Path.GetFileName(image).Contains("poster") && ImageDiskCache.UsedBytes > 0, "real image download is cached by opaque hash and included in disk usage");
            await ImageDiskCache.Clear(); Assert(ImageDiskCache.UsedBytes == 0, "image cache clear removes actual downloaded files");
            Environment.SetEnvironmentVariable("OCP_UPDATE_FEED", fixture.Url + "release");
            var release = await AppReleaseService.Check(); Assert(release is { IsNewer: true, Notes: "Fixture changes" } && release.DownloadUrl == fixture.Url + "download", "manual update request reads version, date, notes and release URL from actual HTTP response");
            AppReleaseService.Ignore(release!.Version); Assert(AppReleaseService.IgnoredVersion == release.Version, "ignored release version survives storage readback");
            Environment.SetEnvironmentVariable("OCP_UPDATE_FEED", fixture.Url + "releases");
            var windowsRelease = await AppReleaseService.Check();
            Assert(windowsRelease is { Version: "v1001.0.0", Notes: "Windows fixture" } && windowsRelease.DownloadUrl == fixture.Url + "windows-download",
                "shared repository update feed selects the newest stable Windows tag and excludes Apple, Core, drafts and prereleases");
            Assert(AppReleaseService.CompareVersions("windows/v1001.0.0", "v1000.0.0") > 0, "Windows tag namespace preserves numeric version comparison");
            Environment.SetEnvironmentVariable("OCP_UPDATE_FEED", fixture.Url + "release-page-one");
            Assert((await AppReleaseService.Check())?.Version == "v1001.0.0", "update lookup follows same-origin pagination when Apple releases fill the first page");
            Environment.SetEnvironmentVariable("OCP_UPDATE_FEED", fixture.Url + "non-windows-releases");
            Assert(await AppReleaseService.Check() is null, "Apple-only release pages do not offer an incompatible Windows update");
            await runtime.Tmdb.Clear(); Assert(runtime.Tmdb.EnrichedCount == 0 && runtime.Tmdb.MatchKey(media, "fixture") is null, "clear TMDB removes both mappings and payload data");
            string? danmakuJson = null;
            var danmakuSettings = new DanmakuSettings(() => danmakuJson, value => danmakuJson = value);
            danmakuSettings.Save(new DanmakuPreferences(GatewayUrl: fixture.Url, ApiKey: "fixture-key"));
            var aliasService = new DanmakuService(runtime.Client, Path.Combine(data, "alias-test"), danmakuSettings,
                bangumiBase: () => fixture.Url, introProvidersEnabled: false);
            var manualResults = await aliasService.Search("Translated title", "1", default);
            Assert(manualResults.Length == 1 && manualResults[0].Episodes.Length == 1 && fixture.Requests.Any(x => x.Contains("anime=Alias%20title"))
                && fixture.Requests.Any(x => x.StartsWith("/v0/subjects/91")) && fixture.Requests.Any(x => x.Contains("anime=Alternate%20alias")),
                $"manual alias requests return missing translated-name results and deduplicate the same episode (works={manualResults.Length}; requests={string.Join(" | ", fixture.Requests.Where(x => x.StartsWith("/v")))})");
            var aliasContext = new DanmakuContext("alias-context", false, "Translated title E01", null, new PlaybackSource("alias", "Translated title", "unavailable-fingerprint"), null, 1440,
                "Translated title", null, 1, 1, null, null, false, false);
            var aliasPayload = await aliasService.Load(aliasContext, true, null, default);
            Assert(aliasPayload.Kind == "loaded" && aliasPayload.Match?.EpisodeId == 91001, "automatic no-match falls back to bounded alias search and shared confidence scoring before loading comments");
            var aliasFile = Path.Combine(data, "alias-local.mkv"); await File.WriteAllTextAsync(aliasFile, "local alias fingerprint fixture");
            var localAliasPayload = await aliasService.Load(aliasContext with { CacheKey = "alias-local", LocalPath = aliasFile }, true, null, default);
            Assert(localAliasPayload.Kind == "loaded" && localAliasPayload.Match?.EpisodeId == 91001 && fixture.Requests.Any(x => x == "/v1/match"),
                "successful fingerprint with no gateway match also reaches alias search and loads the selected episode");
        }
        finally
        {
            RuntimeSettings.Changed -= Changed; RuntimeSettings.Save(original); Environment.SetEnvironmentVariable("OCP_UPDATE_FEED", null);
            var vault = new global::Windows.Security.Credentials.PasswordVault();
            foreach (var credential in vault.RetrieveAll().Where(x => x.Resource == resource)) vault.Remove(credential);
        }
        var complete = new TaskCompletionSource<DanmakuPayload>();
        var context = new DanmakuContext("elapsed", false, "fixture", null, new PlaybackSource("elapsed", "fixture", "https://example.invalid/video"), null, null, "fixture", null, 1, 1, null, null, false, false);
        using var coordinator = new DanmakuCoordinator((_, _, _, _) => complete.Task, () => true, _ => { }, () => { });
        coordinator.Start(context, true); await Task.Delay(1100);
        Assert(coordinator.Busy && coordinator.ElapsedSeconds >= 1 && coordinator.Status.Contains("1s"), "live danmaku status exposes elapsed waiting seconds");
        complete.SetResult(new("empty", "fixture", 0, null)); await coordinator.Completion;
        Assert(!coordinator.Busy, "elapsed updates stop when loading completes");
    }

    private sealed class InlineSettingsProgress(Action<TmdbBatchProgress> changed) : IProgress<TmdbBatchProgress>
    { public void Report(TmdbBatchProgress value) => changed(value); }

    private sealed class SettingsHttpFixture : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0); private readonly CancellationTokenSource _stop = new(); private readonly Task _loop;
        private readonly System.Collections.Concurrent.ConcurrentBag<Task> _responses = [];
        public string Url { get; }
        public System.Collections.Concurrent.ConcurrentBag<string> Requests { get; } = [];
        public SettingsHttpFixture()
        {
            _listener.Start(); var port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            Url = $"http://127.0.0.1:{port}/"; _loop = Run();
        }
        private async Task Run()
        {
            while (!_stop.IsCancellationRequested)
            {
                try { var client = await _listener.AcceptTcpClientAsync(_stop.Token); _responses.Add(Respond(client)); }
                catch (Exception ex) when (ex is OperationCanceledException or SocketException or ObjectDisposedException) { break; }
            }
        }
        private async Task Respond(TcpClient client)
        {
            using (client)
            try
            {
                using var stream = client.GetStream(); using var reader = new StreamReader(stream, Encoding.UTF8, false, leaveOpen: true);
                var request = (await reader.ReadLineAsync(_stop.Token))!.Split(' ');
                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                while (await reader.ReadLineAsync(_stop.Token) is { Length: > 0 } line) { var pair = line.Split(':', 2); headers[pair[0]] = pair[1].Trim(); }
                var length = int.Parse(headers.GetValueOrDefault("Content-Length", "0")); var body = new StringBuilder(); var character = new char[1];
                while (Encoding.UTF8.GetByteCount(body.ToString()) < length) { if (await reader.ReadAsync(character.AsMemory(), _stop.Token) == 0) break; body.Append(character[0]); }
                Requests.Add(request[1]); var uri = new Uri(Url.TrimEnd('/') + request[1]); var path = uri.AbsolutePath;
                var query = uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries).Select(x => x.Split('=', 2))
                    .ToDictionary(x => Uri.UnescapeDataString(x[0]), x => x.Length > 1 ? Uri.UnescapeDataString(x[1].Replace('+', ' ')) : "");
                var english = query.GetValueOrDefault("language") == "en-US";
                object response = path switch
                {
                    "/3/movie/7" => new { id = 7, title = english ? "English fallback" : null, overview = english ? "English synopsis" : null, poster_path = "/poster.jpg", release_date = "2024-01-01" },
                    "/3/tv/8" => new { id = 8, name = "Series", overview = "Series overview", seasons = new[] { new { season_number = 1, name = "Season 1" }, new { season_number = 2, name = "Season 2" } } },
                    "/3/tv/8/season/2" => new { season_number = 2, name = "Season 2", overview = "Season overview", episodes = new[] { new { id = 81, episode_number = 1, name = "First", overview = "Episode overview", air_date = "2024-01-01" }, new { id = 82, episode_number = 2, name = "Future", overview = "Future overview", air_date = "2099-01-01" } } },
                    "/3/tv/8/season/1" => new { season_number = 1, name = "Season 1", overview = "First season", episodes = Array.Empty<object>() },
                    "/3/search/movie" => new { results = Array.Empty<object>() },
                    "/Users/user/Items" or "/Items" => new { Items = new object[] {
                        new { Id = "movie", Name = "Movie", Type = "Movie", ProductionYear = 2024, ProviderIds = new { Tmdb = "7" } },
                        new { Id = "show", Name = "Series", Type = "Series", ProductionYear = 2024, ProviderIds = new { Tmdb = "8" } },
                        new { Id = "unmatched", Name = "Unmatched", Type = "Movie", ProductionYear = 2024 } }, TotalRecordCount = 3 },
                    "/v1/match" => new { success = true, isMatched = false, matches = Array.Empty<object>() },
                    "/p1/search/subjects" => new { total = 1, data = new[] { new { id = 91, name = "Alias title", nameCN = "Translated title", type = 2 } } },
                    "/v0/subjects/91" => new { id = 91, name = "Alias title", name_cn = "Translated title", type = 2, infobox = new[] { new { key = "别名", value = new[] { new { v = "Alias title" }, new { v = "Alternate alias" } } } } },
                    "/v1/search/episodes" => new { success = true, animes = query.GetValueOrDefault("anime") is "Alias title" or "Alternate alias"
                        ? new object[] { new { animeId = 91, animeTitle = "Alias title", type = "tvseries", episodes = new[] { new { episodeId = 91001, episodeTitle = "第1集" } } } } : [] },
                    "/v1/comment/91001" or "/v1/comments/91001" => new { count = 1, comments = new[] { new { p = "1,1,16777215", m = "alias fixture" } } },
                    "/release" => new { tag_name = "v999.0.0", published_at = "2026-11-16T00:00:00Z", body = "Fixture changes", html_url = Url + "download" },
                    "/releases" or "/release-page-two" => new[] {
                        new { tag_name = "v9999.0.0", published_at = "2026-11-17T00:00:00Z", body = "Apple fixture", html_url = Url + "apple-download", draft = false, prerelease = false },
                        new { tag_name = "core/v9999.0.0", published_at = "2026-11-17T00:00:00Z", body = "Core fixture", html_url = Url + "core-download", draft = false, prerelease = false },
                        new { tag_name = "windows/v1000.0.0", published_at = "2026-11-17T00:00:00Z", body = "Older fixture", html_url = Url + "older-download", draft = false, prerelease = false },
                        new { tag_name = "windows/v1001.0.0", published_at = "2026-11-16T00:00:00Z", body = "Windows fixture", html_url = Url + "windows-download", draft = false, prerelease = false },
                        new { tag_name = "windows/v1002.0.0", published_at = "2026-11-17T00:00:00Z", body = "Draft fixture", html_url = Url + "draft-download", draft = true, prerelease = false },
                        new { tag_name = "windows/v1003.0.0", published_at = "2026-11-17T00:00:00Z", body = "Prerelease fixture", html_url = Url + "prerelease-download", draft = false, prerelease = true } },
                    "/non-windows-releases" or "/release-page-one" => new[] { new { tag_name = "v9999.0.0", published_at = "2026-11-17T00:00:00Z", body = "Apple fixture", html_url = Url + "apple-download" } },
                    _ => new { ok = true }
                };
                var bytes = path == "/poster.jpg" ? new byte[] { 1, 2, 3, 4 } : Encoding.UTF8.GetBytes(JsonSerializer.Serialize(response));
                var pagination = path == "/release-page-one" ? $"Link: <{Url}release-page-two>; rel=\"next\"\r\n" : "";
                var header = Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Type: {(path == "/poster.jpg" ? "image/jpeg" : "application/json")}\r\nContent-Length: {bytes.Length}\r\n{pagination}Connection: close\r\n\r\n");
                await stream.WriteAsync(header, _stop.Token); await stream.WriteAsync(bytes, _stop.Token);
            }
            catch (Exception ex) when (ex is OperationCanceledException or IOException or SocketException) { }
        }
        public void Dispose() { _stop.Cancel(); _listener.Stop(); try { _loop.GetAwaiter().GetResult(); Task.WhenAll(_responses).GetAwaiter().GetResult(); } catch (OperationCanceledException) { } _stop.Dispose(); }
    }
}

using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;

internal static partial class Program
{
    private static async Task VerifyViewing(OcpCoreClient core, string data)
    {
        var history = new ViewingHistory(Path.Combine(data, "viewing"));
        var now = DateTimeOffset.Now;
        var media = new DemoMedia("film", "Film", "", "2026", "科幻", "https://image/?api_key=secret", "", DurationSeconds: 120,
            SourceUri: "https://stream/?token=secret");
        var server = new ViewingRecord("film", "account", media, now, null, true);
        var actual = new ViewingRecord("session", "account", media, now, 30, false);
        var merged = ViewingHistory.Merge([server], [actual, actual with { Id = "session-2", ActualSeconds = 10 }], now);
        Assert(merged.Length == 1 && merged[0].Seconds == 40 && merged[0].Completed, "actual wall time replaces same-day server runtime without double counting");
        merged = ViewingHistory.Merge([server], [actual with { Source = "other" }], now);
        Assert(merged.Length == 2 && !merged.Single(x => x.Source == "other").Completed, "completion is isolated by server account");
        history.SaveActual(actual with { Media = ViewingHistory.Sanitize(media) });
        history.SaveActual(actual with { ActualSeconds = 15, Media = ViewingHistory.Sanitize(media) });
        Assert(history.Read("account", true).Records.Single().ActualSeconds == 30, "out-of-order cumulative checkpoints do not regress or duplicate time");
        Assert(!string.Join("", Directory.GetFiles(Path.Combine(data, "viewing"), "*.json", SearchOption.AllDirectories).Select(File.ReadAllText)).Contains("secret"), "history archives omit source URLs and authenticated artwork");
        var clock = new ViewingRecorder(history, "clock", media);
        var midnight = new DateTimeOffset(DateTime.Today.AddDays(1));
        clock.Sample(0, 0, true, 1, midnight.AddSeconds(-.5));
        clock.Sample(1, 1, true, 1, midnight.AddSeconds(.5));
        clock.Sample(2, 1, true, 1, midnight.AddSeconds(1.5)); // buffering/stall
        clock.Sample(3, 100, true, 1, midnight.AddSeconds(2.5)); // seek
        clock.Sample(4, 101, false, 1, midnight.AddSeconds(3.5)); // paused
        clock.Flush(); clock.Flush();
        var days = history.Read("clock", true).Records;
        Assert(days.Length == 2 && Math.Abs(days.Sum(x => x.Seconds) - 1) < .001 && days.All(x => Math.Abs(x.Seconds - .5) < .001), "midnight splits wall time; pause, stall, seek and duplicate flush add no time");
        var sparse = new ViewingRecorder(history, "sparse", media);
        sparse.Sample(0, 0, true, 1, now);
        for (var tick = 1; tick <= 60; tick++) sparse.Sample(tick / 60d, tick == 60 ? 1 : 0, true, 1, now.AddSeconds(tick / 60d));
        sparse.Flush();
        Assert(Math.Abs(history.Read("sparse", true).Records.Sum(x => x.Seconds) - 1) < .001, "60 Hz rendering counts full wall time when decoder positions arrive once per second");
        var offsets = new List<int>();
        var paged = await ViewingIntegrations.Pages(offset => { offsets.Add(offset); return Task.FromResult(JsonSerializer.SerializeToElement(new { total = 101, data = Enumerable.Range(offset, offset == 0 ? 100 : 1).Select(x => new { id = x }) })); }, default);
        Assert(paged.Length == 101 && offsets.SequenceEqual(new[] { 0, 100 }), "Bangumi collection pagination loads beyond the first hundred items");
        using (var cancelled = new CancellationTokenSource())
        {
            cancelled.Cancel();
            try { await ViewingIntegrations.Pages(_ => Task.FromResult(JsonSerializer.SerializeToElement(new { data = new[] { 1 } })), cancelled.Token); throw new Exception("Cancellation ignored"); }
            catch (OperationCanceledException) { Assert(true, "cancelled pagination cannot publish results"); }
        }
        var anchor = new DateTimeOffset(DateTime.Today.AddHours(1)).ToUniversalTime();
        var entry = new BroadcastEntry(JsonSerializer.SerializeToElement(new { id = 1 }), 1, anchor, "P7D", null);
        Assert(BroadcastTimeline.OnDay([entry], DateTime.Today).Single().Time == anchor && !BroadcastTimeline.OnDay([entry], DateTime.Today.AddDays(1)).Any(), "broadcast recurrences use UTC instants and local calendar boundaries");

        using var fixture = new ViewingFixture();
        var resource = "OcPlayer.ViewingTests." + Guid.NewGuid().ToString("N");
        var integrations = new ViewingIntegrations(core, resource);
        try
        {
            await integrations.ConnectBangumi(fixture.Url, "fixture-bgm-token", default);
            await integrations.ConnectMoviePilot(fixture.Url + "proxy", "fixture-user", "fixture-password", default);
            Assert(integrations.Bangumi?.DisplayName == "Fixture BGM" && integrations.MoviePilot?.DisplayName == "Fixture MP", "real Core authenticates Bangumi and MoviePilot through configured endpoints");
            var restored = new ViewingIntegrations(core, resource);
            Assert(restored.Bangumi?.AccessToken == "fixture-bgm-token" && restored.MoviePilot?.AccessToken == "fixture-mp-token", "integration credentials survive restart in isolated Windows vault entries");
            var collections = await integrations.Collections(3, default);
            Assert(collections.Length == 101, "real Bangumi API pagination preserves all entries");
            var episodes = await integrations.Episodes(1, default);
            Assert(ViewingIntegrations.EpisodeStatus(episodes.Single()) == 2, "Bangumi p1 collection.status survives Core projection");
            await integrations.Bgm("updateEpisode", new { episodeId = 12, collectionType = 2, batch = true }, default);
            var mediaResults = Json.Items(await integrations.Mp("mediaSearch", new { title = "Film" }, default));
            var torrentResults = Json.Items(await integrations.Mp("torrentSearch", new { keyword = "Film", sites = new[] { 7 } }, default));
            await integrations.Mp("download.add", new { media = mediaResults.Single(), torrent = Json.Get(torrentResults.Single(), "torrent") }, default);
            var body = JsonDocument.Parse(fixture.DownloadBody!).RootElement;
            Assert(Json.Text(Json.Get(body, "media_in"), "douban_id") == "douban-123" && Json.Text(Json.Get(body, "torrent_in"), "enclosure") == "fixture-enclosure", "download forwards original media identifiers and torrent payload through Core");
            await integrations.Mp("subscription.add", new { subscription = new { name = "Film", type = "电影", tmdbid = 42, state = "R" } }, default);
            Assert(Json.Items(await integrations.Mp("subscription.list", null, default)).Length == 1, "subscription API supports wrapped responses");
            Assert(Json.Items(await integrations.Mp("download.list", null, default)).Length == 1, "download list reaches reverse-proxy base path");
            integrations.Enable("moviepilot", false);
            try { await integrations.Mp("subscription.list", null, default); throw new Exception("Disabled service requested"); }
            catch (InvalidOperationException) { Assert(true, "disabled integration blocks service requests"); }
            fixture.RejectBangumi = true;
            try { await integrations.ConnectBangumi(fixture.Url, "bad-token", default); throw new Exception("Invalid login accepted"); }
            catch (InvalidOperationException) { Assert(integrations.Bangumi?.AccessToken == "fixture-bgm-token", "failed account replacement preserves previous credentials"); }
            fixture.RejectBangumi = false;

            var mediaServer = new MediaServer(core, new ServerProfile("history-fixture", "jellyfin", fixture.Url, "user", "fixture-server-token"));
            var imported = await history.Synchronize(mediaServer, default);
            Assert(imported.Records.Length == 1 && imported.Undated == 1, "server viewing history imports dated completed items and excludes undated and future records");
            var again = await history.Synchronize(mediaServer, default);
            Assert(again.Records.Length == 1 && again.RecordedFrom == imported.RecordedFrom, "repeated server refresh reconciles instead of appending snapshots");
            fixture.FailHistory = true;
            try { await history.Synchronize(mediaServer, default); throw new Exception("Failed history accepted"); }
            catch (ServerConnectionException) { Assert(history.Read(ViewingHistory.Source(mediaServer)).Records.Length == 1, "failed history scan retains last complete archive"); }
        }
        finally { await integrations.Logout("bangumi"); await integrations.Logout("moviepilot"); }
    }

    private sealed class ViewingFixture : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource _stop = new();
        public string Url { get; }
        public bool RejectBangumi, FailHistory;
        public int OAuthTokenCalls, OAuthRefreshCalls, OAuthAuthorizeCalls;
        public bool RejectOAuthRefresh, FailOAuthRefresh, FailOAuthProfile, RejectP1;
        public bool ProfileBearerCorrect = true;
        public bool RejectOldOAuthAccess;
        public string? OAuthGatewayError;
        public int OAuthExpires = 3600;
        public bool GatewayHeadersCorrect = true;
        public TaskCompletionSource? TokenEntered, TokenRelease, RefreshEntered, RefreshRelease;
        public string? DownloadBody;
        public TaskCompletionSource<string> BrowserLoaded { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public ViewingFixture()
        {
            _listener.Start(); Url = $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}/";
            _ = Listen();
        }
        private async Task Listen()
        {
            while (!_stop.IsCancellationRequested)
            {
                try { var client = await _listener.AcceptTcpClientAsync(_stop.Token); _ = Respond(client); }
                catch (OperationCanceledException) { break; }
            }
        }
        private async Task Respond(TcpClient client)
        {
            using (client)
            {
                try
                {
                    using var stream = client.GetStream(); using var reader = new StreamReader(stream, Encoding.UTF8, false, leaveOpen: true);
                    var request = (await reader.ReadLineAsync())!.Split(' '); var target = request[1]; var path = target.Split('?')[0]; var length = 0;
                    var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    while (await reader.ReadLineAsync() is { Length: > 0 } line)
                    {
                        var pair = line.Split(':', 2); headers[pair[0]] = pair[1].Trim();
                        if (pair[0].Equals("Content-Length", StringComparison.OrdinalIgnoreCase)) length = int.Parse(pair[1]);
                    }
                    var bodyText = new StringBuilder(); var character = new char[1];
                    while (Encoding.UTF8.GetByteCount(bodyText.ToString()) < length)
                    {
                        if (await reader.ReadAsync(character) == 0) throw new IOException("Truncated request");
                        bodyText.Append(character[0]);
                    }
                    var status = 200; object body = new { success = true }; var contentType = "application/json";
                    if (path == "/browser-login-probe")
                    {
                        contentType = "text/html; charset=utf-8";
                        body = "<!doctype html><html lang='zh-CN'><meta charset='utf-8'><title>OcPlayer 浏览器登录验证</title><h1>浏览器登录页面已成功加载</h1><p>本页验证浏览器打开和应用回调，不需要输入账号或密码。</p></html>";
                    }
                    else if (path.StartsWith("/v1/bangumi/oauth/"))
                    {
                        GatewayHeadersCorrect &= !headers.ContainsKey("Authorization") && headers.GetValueOrDefault("X-API-Key") == "fixture-gateway-key" && headers.GetValueOrDefault("User-Agent", "").StartsWith("OcPlay/");
                        if (path.EndsWith("authorize"))
                        {
                            Interlocked.Increment(ref OAuthAuthorizeCalls);
                            var state = BangumiOAuthCallback.Query(new Uri(Url.TrimEnd('/') + target))["state"];
                            body = new { authorize_url = "https://bgm.tv/oauth/authorize?client_id=fixture&redirect_uri=ocplayer%3A%2F%2Foauth%2Fcallback&state=" + state };
                        }
                        else if (path.EndsWith("token"))
                        {
                            Interlocked.Increment(ref OAuthTokenCalls); TokenEntered?.TrySetResult(); if (TokenRelease is not null) await TokenRelease.Task;
                            body = new { access_token = "oauth-access", refresh_token = "oauth-refresh", expires_in = OAuthExpires };
                        }
                        else
                        {
                            Interlocked.Increment(ref OAuthRefreshCalls); RefreshEntered?.TrySetResult(); if (RefreshRelease is not null) await RefreshRelease.Task;
                            body = new { access_token = "oauth-renewed", expires_in = 3600 }; // No rotation: preserve the previous refresh token.
                            if (RejectOAuthRefresh) { status = 400; body = new { success = false, error = new { code = "BANGUMI_OAUTH_REJECTED" } }; }
                            if (FailOAuthRefresh) { status = 502; body = new { success = false, error = new { code = "UPSTREAM_ERROR" } }; }
                        }
                        if (OAuthGatewayError is not null) { status = 403; body = new { success = false, error = new { code = OAuthGatewayError } }; }
                    }
                    else if (RejectP1 && path.StartsWith("/p1/")) body = new { request = path, code = 404, error = "Not Found" };
                    else if (path is "/v0/me" or "/p1/me")
                    {
                        status = RejectBangumi || path == "/p1/me" && FailOAuthProfile ? 401 : 200;
                        if (path == "/p1/me") ProfileBearerCorrect &= headers.GetValueOrDefault("Authorization") == "Bearer oauth-access";
                        body = new { username = "fixture", nickname = "Fixture BGM", avatar = new { large = "https://lain.bgm.tv/avatar.jpg" } };
                    }
                    else if (path.Contains("/collections/subjects"))
                    {
                        var offset = target.Contains("offset=100") ? 100 : 0;
                        body = new { total = 101, data = Enumerable.Range(offset + 1, offset == 0 ? 100 : 1).Select(x => new { subject = new { id = x, name = "Anime", nameCN = "番剧" } }) };
                    }
                    else if (path == "/p1/subjects/1/episodes")
                    {
                        if (RejectOldOAuthAccess && headers.GetValueOrDefault("Authorization") == "Bearer oauth-access") status = 401;
                        body = new { total = 1, data = new[] { new { id = 12, name = "Episode", type = 0, sort = 1, airdate = "2026-01-01", collection = new { status = 2 } } } };
                    }
                    else if (path == "/proxy/api/v1/login/access-token") body = new { access_token = "fixture-mp-token", token_type = "bearer" };
                    else if (path == "/proxy/api/v1/user/current") body = new { name = "Fixture MP", id = 1, is_active = true };
                    else if (path == "/proxy/api/v1/media/search") body = new { success = true, data = new[] { new { title = "Film", douban_id = "douban-123", type = "电影" } } };
                    else if (path == "/proxy/api/v1/search/title/stream")
                    {
                        contentType = "text/event-stream";
                        body = "data: {\"type\":\"done\",\"items\":[{\"torrent_info\":{\"title\":\"Film\",\"enclosure\":\"fixture-enclosure\"},\"meta_info\":{\"title\":\"Not a media payload\"}}]}\n\n";
                    }
                    else if (path == "/proxy/api/v1/download/" && request[0] == "POST") DownloadBody = bodyText.ToString();
                    else if (path == "/proxy/api/v1/download/") body = new[] { new { hash = "task", name = "Film", progress = 45 } };
                    else if (path == "/proxy/api/v1/subscribe/" && request[0] == "GET") body = new { success = true, data = new[] { new { id = 1, name = "Film", state = "R" } } };
                    else if (path == "/Items")
                    {
                        status = FailHistory ? 403 : 200;
                        object Item(string id, string? date) => new { Id = id, Name = id, Type = "Movie", RunTimeTicks = 1200000000L, UserData = new { Played = true, LastPlayedDate = date } };
                        body = new { Items = new[] { Item("watched", DateTimeOffset.UtcNow.ToString("O")), Item("undated", null), Item("future", DateTimeOffset.UtcNow.AddDays(10).ToString("O")) }, TotalRecordCount = 3 };
                    }
                    var bytes = Encoding.UTF8.GetBytes(contentType == "text/event-stream" || contentType.StartsWith("text/html") ? (string)body : JsonSerializer.Serialize(body));
                    await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status} Fixture\r\nContent-Type: {contentType}\r\nContent-Length: {bytes.Length}\r\nConnection: close\r\n\r\n")); await stream.WriteAsync(bytes);
                    if (path == "/browser-login-probe") BrowserLoaded.TrySetResult(headers.GetValueOrDefault("User-Agent", ""));
                }
                catch (IOException) { }
            }
        }
        public void Dispose() { _stop.Cancel(); _listener.Stop(); _stop.Dispose(); }
    }
}

using System.Text.Json;
using System.Text.Json.Nodes;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;

internal static partial class Program
{
    private static async Task VerifyIntegrationParity(OcpCoreClient core, string data)
    {
        static JsonElement J(object value) => JsonSerializer.SerializeToElement(value);
        var domains = BangumiDomains.Parse("https://api.bangumi.example:8443/");
        Assert(domains.Api == "https://api.bangumi.example:8443/" && domains.Images == "https://lain.bangumi.example:8443/" && domains.Next == "https://next.bangumi.example:8443/" && domains.Main == "https://bangumi.example:8443/", "mirror root routes four domains and preserves explicit port");
        foreach (var invalid in new[] { "https://example.com/path", "https://user:secret@example.com", "https://example.com/?token=x" })
        { try { BangumiDomains.Parse(invalid); throw new Exception("Invalid mirror accepted"); } catch (ArgumentException) { Assert(true, "mirror rejects paths, credentials and queries"); } }
        var oauthState = Guid.NewGuid().ToString("N"); var authorization = ViewingIntegrations.AuthorizationUrl(J(new { authorize_url = "https://bgm.tv/oauth/authorize?state=" + oauthState }), domains.Api, oauthState);
        Assert(authorization.Host == "bangumi.example" && authorization.Port == 8443, "OAuth browser route uses mirror root and port");
        var normalizedTraditional = BroadcastTimeline.Normalize("聲之形 CAFÉ Ａ"); var normalizedSimplified = BroadcastTimeline.Normalize("声之形 cafe a");
        Assert(normalizedTraditional == normalizedSimplified, $"broadcast titles normalize traditional Chinese, width, case and diacritics ({normalizedTraditional} / {normalizedSimplified})");
        Assert(ViewingIntegrations.EpisodeStatus(J(new { collection = new { status = 3, type = 2 } })) == 3, "p1 collection.status takes precedence over legacy type");
        Assert(!ViewingIntegrations.EpisodeAired(J(new { airdate = DateTime.Today.AddDays(1).ToString("yyyy-MM-dd") })) && !ViewingIntegrations.EpisodeAired(J(new { airdate = "" })) && ViewingIntegrations.EpisodeAired(J(new { airDate = "2000-01-01" })), "unaired and unknown-date chapters remain immutable");
        var item = J(new { title = "Series", type = "电视剧", year = "2026", tmdb_id = 42, douban_id = "douban-5", bangumi_id = 6, poster_path = "https://image.example/p.jpg", overview = "full overview", season = 2 });
        var subscription = MoviePilotPolicies.NewSubscription(item);
        Assert(subscription["year"]!.ToString() == "2026" && subscription["tmdbid"]!.ToString() == "42" && subscription["doubanid"]!.ToString() == "douban-5" && subscription["bangumiid"]!.ToString() == "6" && subscription["poster"]!.ToString().Contains("image.example") && subscription["overview"]!.ToString() == "full overview", "new subscription preserves media identity and result metadata");
        Assert(MoviePilotPolicies.Subscribed(item, [JsonSerializer.SerializeToElement(subscription)]) && !MoviePilotPolicies.Subscribed(item, [J(new { tmdbid = 42, type = "电视剧", season = 1 })]), "duplicate subscriptions match source identity and season");
        MoviePilotPolicies.SetText(subscription, "", true, "tmdbid", "tmdb_id"); Assert(!subscription.ContainsKey("tmdbid") && !subscription.ContainsKey("tmdb_id"), "clearing an identifier removes both protocol aliases");
        Assert(MoviePilotPolicies.State(J(new { state = "P" })) == "暂停" && MoviePilotPolicies.State(J(new { state = "O" })) == "已完成", "MoviePilot paused and completed states use P and O");
        JsonElement Torrent(string site, string season, string promotion, string codec, string edition, string resolution, string group, int size) => J(new { torrent = new { title = "Series", site_name = site, volume_factor = promotion, size, seeders = size, pri_order = size }, meta = new { season_episode = season, video_encode = codec, edition, resource_pix = resolution, resource_team = group } });
        var torrents = new[] { Torrent("A", "S01", "免费", "HEVC", "WEB-DL", "1080p", "Group", 2), Torrent("B", "S02", "普通", "H264", "BluRay", "2160p", "Other", 1) };
        var filters = Enumerable.Range(0, 7).Select(_ => new HashSet<string>()).ToArray();
        for (var i = 0; i < 7; i++) { filters[i].Add(MoviePilotPolicies.FilterValue(torrents[0], i)); Assert(MoviePilotPolicies.Filter(torrents, filters).SequenceEqual([torrents[0]]), "exact resource filter " + MoviePilotPolicies.FilterFields[i].Label); filters[i].Clear(); }
        Assert(MoviePilotPolicies.Sort(torrents, 2, true).First().GetRawText() == torrents[1].GetRawText() && MoviePilotPolicies.Sort(torrents, 3, false).First().GetRawText() == torrents[0].GetRawText(), "resource sort supports both directions without dropping payload");
        var now = DateTimeOffset.Now; var media = new DemoMedia("ep1", "Episode one", "", "2026", "", "", "", Kind: "episode", SeriesId: "series", SeriesTitle: "Series", SeasonNumber: 1, EpisodeNumber: 2);
        var server = new ViewingRecord("ep1", "source", media with { Category = "动画 / 奇幻" }, now, null, true); var actual = new ViewingRecord("session", "source", media, now, 60, false);
        var merged = ViewingHistory.Merge([server], [actual], now);
        Assert(merged.Single().Media.Category == "动画 / 奇幻" && ViewingAnalytics.Genres(merged).Sum(x => x.Seconds) == 60, "actual viewing retains server genres and weighted genre totals conserve time");
        Assert(ViewingAnalytics.Top([actual, actual with { Id = "session2", Media = media with { Id = "ep2" }, ActualSeconds = 40 }]).Single().Seconds == 100, "monthly rankings merge episodes into their series");
        var resource = "OcPlayer.IntegrationParity." + Guid.NewGuid().ToString("N"); var loginCalls = 0; var renewedRequests = 0; var episodeWrites = new List<int>(); var subjectWrites = new List<int>(); var collectionStatus = 200;
        TaskCompletionSource? requestEntered = null, requestRelease = null;
        var searchFinish = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously); string? searchId = null;
        async Task<OcpResponse> Call(string method, string json, CancellationToken token)
        {
            var input = JsonDocument.Parse(json).RootElement; object result = new { };
            if (method == "moviepilot.login") { var call = Interlocked.Increment(ref loginCalls); if (call > 1) await Task.Delay(70, token); result = new { accessToken = call == 1 ? "expired" : "renewed", user = new { name = "test" } }; }
            else if (method == "moviepilot.subscription.list") { if (Json.Text(input, "accessToken") == "expired") return new(false, 2001, false, "expired", default); Interlocked.Increment(ref renewedRequests); if (requestEntered is not null) { requestEntered.TrySetResult(); await requestRelease!.Task; } result = new { items = Array.Empty<object>() }; }
            else if (method == "moviepilot.torrentSearch") { searchId = Json.Text(input, "requestId"); result = await searchFinish.Task.WaitAsync(token); }
            else if (method == "bangumi.request") result = Json.Text(input, "url").Contains("/collections/") ? new { status = collectionStatus, body = "{\"type\":3,\"rate\":8}" } : new { status = 200, body = "{\"username\":\"parity\",\"nickname\":\"Parity\"}" };
            else if (method == "bangumi.episodes") result = new { total = 2, data = new[] { new { id = 10, sort = 1, type = 0, airdate = "2000-01-01", collection = new { status = 2 } }, new { id = 11, sort = 2, type = 0, airdate = "2000-01-01", collection = new { status = 0 } } } };
            else if (method == "bangumi.updateEpisode") episodeWrites.Add((int)Json.Number(input, "collectionType"));
            else if (method == "bangumi.updateSubject" && Json.Get(Json.Get(input, "body"), "type").ValueKind == JsonValueKind.Number) subjectWrites.Add((int)Json.Number(Json.Get(input, "body"), "type"));
            return new(true, 0, false, "", J(result));
        }
        var service = new ViewingIntegrations(Call, resource);
        try
        {
            service.Enable("bangumi", false); var restored = new ViewingIntegrations(Call, resource); Assert(!restored.IsEnabled("bangumi"), "integration enabled preference survives without an account"); service.Enable("bangumi", true);
            await service.ConnectMoviePilot("https://mp.example", "user", "password", default, true);
            await Task.WhenAll(Enumerable.Range(0, 5).Select(_ => service.Mp("subscription.list", null, default)));
            Assert(loginCalls == 2 && renewedRequests == 5, "concurrent MoviePilot 401s coordinate one silent login and replay all requests");
            var updates = new List<JsonElement>(); var search = service.TorrentSearch("Series", [7], updates.Add, default);
            service.ReceiveCoreEvent("moviepilot.searchProgress", J(new { requestId = "other", items = torrents, progress = new { finished = 1, total = 2 } }));
            service.ReceiveCoreEvent("moviepilot.searchProgress", J(new { requestId = searchId, items = torrents.Take(1), progress = new { finished = 1, total = 2 } }));
            Assert(updates.Count == 1 && Json.Items(updates[0]).Length == 1 && !search.IsCompleted, "resource SSE exposes partial results before completion and isolates request IDs");
            searchFinish.SetResult(J(new { items = torrents })); Assert((await search).Length == 2, "resource streaming completes with the final full result projection");
            service.ReceiveCoreEvent("moviepilot.searchProgress", J(new { requestId = searchId, items = torrents })); Assert(updates.Count == 1, "completed searches unsubscribe from late Core events");
            service.RememberMoviePilotPassword(false); Assert(service.MoviePilot is { Password: null, RememberPassword: false }, "disabling remembered password immediately clears the vault account secret");
            await service.ConnectBangumi("https://api.bgm.tv", "access", default); service.ConfigureMirror(true, "https://bangumi.example:8443");
            collectionStatus = 404; Assert(await service.SubjectCollection(101, default) is null, "Bangumi 404 is uncollected rather than default watching"); collectionStatus = 503;
            try { await service.SubjectCollection(101, default); throw new Exception("Server error treated as uncollected"); } catch (InvalidOperationException) { Assert(true, "Bangumi collection transport failures remain errors"); } collectionStatus = 200;
            await service.SubjectCollection(101, default); await service.UpdateSubjectCollection(101, default, rate: 9);
            Assert(service.Snapshot("collection:101") is { } rated && Json.Number(rated, "type") == 3 && Json.Number(rated, "rate") == 9 && subjectWrites.Count == 0, "rating writes preserve collection state and update the local snapshot");
            Assert(service.Bangumi is { AccessToken: "access", BaseUrl: "https://api.bangumi.example:8443/" } && service.RewriteBangumiUrl("https://lain.bgm.tv/pic/cover.jpg") == "https://lain.bangumi.example:8443/pic/cover.jpg", "mirror change keeps login and rewrites existing official image URLs");
            service.ConfigureMirror(false, service.MirrorRoot); Assert(service.MirrorRoot.Contains("bangumi.example") && service.Bangumi?.BaseUrl == BangumiDomains.Official.Api && service.RewriteBangumiUrl("https://lain.bangumi.example:8443/pic/old.jpg") == "https://lain.bgm.tv/pic/old.jpg", "mirror disable retains configuration and restores official API and old image URLs");
            service.LinkBangumi("source", media with { SeasonNumber = null }, 100, "Series");
            Assert(service.ResolveBangumiLink("source", media)?.SubjectId == 100 && service.ResolveBangumiLink("source", media with { SeasonNumber = 2 }) is null && service.ResolveBangumiLink("other", media) is null, "series fallback applies to first season and remains isolated by server");
            service.LinkBangumi("source", media, 101, "Season 1"); service.LinkBangumi("source", media with { SeasonNumber = 2 }, 102, "Season 2");
            Assert(new ViewingIntegrations(Call, resource).ResolveBangumiLink("source", media with { SeasonNumber = 2 })?.SubjectId == 102, "per-season Bangumi links survive restart");
            await service.MarkLinkedEpisodeWatched("source", media, 2, default);
            Assert(episodeWrites.SequenceEqual([2]) && subjectWrites.SequenceEqual([2]), "last linked main episode marks its chapter watched and completes the collection");
            service.SaveSnapshot("subject:101", J(new { id = 101, name = "Cached" })); Assert(new ViewingIntegrations(Call, resource).Snapshot("subject:101") is { } cached && Json.Title(cached) == "Cached", "Bangumi subject snapshots survive restart");
            requestEntered = new(TaskCreationOptions.RunContinuationsAsynchronously); requestRelease = new(TaskCreationOptions.RunContinuationsAsynchronously);
            var late = service.Mp("subscription.list", null, default); await requestEntered.Task;
            await service.Logout("moviepilot"); requestRelease.TrySetResult();
            try { await late; throw new Exception("Old account data published after logout"); } catch (OperationCanceledException) { Assert(true, "late MoviePilot responses cannot publish after logout"); }
            Assert(service.MoviePilot is { BaseUrl: "https://mp.example/", AccessToken: "", Password: null }, "MoviePilot logout clears auth while preserving server configuration");
        }
        finally { await service.Logout("bangumi"); await service.Logout("moviepilot"); }

        var watching = new[] { J(new { id = 101, name = "Different title" }) }; var calendar = new[] { J(new { weekday = new { id = 1 }, items = watching }) };
        var library = new[] { J(new { id = "series", name = "中文标题", kind = "series", tmdbID = "42", childCount = 1 }) };
        var schedule = new[] { J(new { type = "tv", sites = new[] { new { site = "bangumi", id = "101" }, new { site = "tmdb", id = "tv/42" } } }) };
        Assert(BroadcastTimeline.Match(watching, calendar, library, schedule).Length == 1, "broadcast matches external TMDB identity across languages");
        var seasonLibrary = library.Append(J(new { id = "season2", name = "Season 2", kind = "season", seriesID = "series", tmdbID = "999", seasonNumber = 2, childCount = 1 })).ToArray();
        var seasonSchedule = new[] { J(new { type = "tv", sites = new[] { new { site = "bangumi", id = "101" }, new { site = "tmdb", id = "tv/42/season/2" } } }) };
        Assert(BroadcastTimeline.Match(watching, calendar, seasonLibrary, seasonSchedule).Length == 1 && BroadcastTimeline.Match(watching, calendar, library, seasonSchedule).Length == 0, "later-season matching uses parent TMDB ID and requires the actual season container");
        foreach (var provider in new[] { "mal", "aniList" })
        {
            var providerLibrary = new[] { J(new { id = "series", name = "Unrelated", kind = "series", malID = "77", anilistID = "77", childCount = 1 }) };
            var providerSchedule = new[] { J(new { type = "tv", sites = new[] { new { site = "bangumi", id = "101" }, new { site = provider, id = "77" } } }) };
            Assert(BroadcastTimeline.Match(watching, calendar, providerLibrary, providerSchedule).Length == 1, "broadcast matches external provider " + provider);
        }
        Assert(BroadcastTimeline.Match(watching, calendar, library, schedule, [new("source", "series", null, 999, "Other")], "source").Length == 0, "explicit other-subject link prevents accidental external or title match");
        Assert(BroadcastTimeline.Match(watching, calendar, library, [], [new("source", "series", null, 101, "Chosen")], "source").Length == 1, "explicit Bangumi links establish broadcast availability");
        using var fixture = new ViewingFixture(); var network = new ViewingIntegrations(core, resource + ".wire");
        try { await network.ConnectBangumi(fixture.Url, "fixture", default); await network.Bgm("updateEpisode", new { episodeId = 12, collectionType = 3 }, default); Assert(true, "Core permits Bangumi chapter dropped=3 over the actual request path"); }
        finally { await network.Logout("bangumi"); }
    }
}

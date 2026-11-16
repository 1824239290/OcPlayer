using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Preview;
using OcPlayer.Windows.Services;

internal static partial class Program
{
    private static async Task VerifyBrowsingParity(OcpCoreClient core, string data)
    {
        using var fixture = new BrowsingFixture();
        var profile = new ServerProfile("parity-browser", "jellyfin", fixture.Url, "user", "cache-secret", ResolvedServerId: "same-server");
        var server = new MediaServer(core, profile);
        await server.Refresh(default);
        Assert(server.Resume.Count == 1 && server.NextUp.Count == 1 && server.NextUp[0].Id == "next", "home removes resume/next-up overlap");
        fixture.FailNext = true; await server.Refresh(default);
        Assert(server.NextUp.Count == 1 && server.HomeWarning?.Contains("接下来看") == true, "failed home section preserves previous successful entries");
        var restored = new MediaServer(core, profile);
        Assert(restored.RestoreHome() && restored.NextUp.Count == 1 && restored.HomeWarning?.Contains("缓存") == true, "new server session restores disk home snapshot with age notice");
        var all = new List<DemoMedia>(); BrowserPage? page = null;
        do { page = await server.BrowsePage("movies", "alias", new(), page?.NextIndex ?? 0, default); all.AddRange(page.Items); } while (page.HasMore);
        Assert(all.Count == 611 && all.Select(x => x.Id).Distinct().Count() == 611 && page.TotalCount == 611, "library paginates beyond 500 with exact total and no duplicates");
        File.WriteAllLines(Path.Combine(data, "browser-requests.txt"), fixture.Queries);
        Assert(fixture.Queries.Any(x => x.Contains("startIndex=600") && x.Contains("limit=60") && x.Contains("includeItemTypes=Movie")), "pagination cursor, page size and movie library type reach real Core HTTP");
        await server.BrowsePage("tv", "", new(), 0, default);
        Assert(fixture.Queries.Last(x => x.Contains("parentId=tv")).Contains("includeItemTypes=Series"), "series library selects series only");
        await server.BrowsePage("boxes", "", new(), 0, default);
        Assert(!fixture.Queries.Last(x => x.Contains("parentId=boxes")).Contains("includeItemTypes="), "collection library does not discard other kinds");
        server.CacheBrowse("movies", "alias", new(), new(all.ToArray(), 0, 611, false));
        Assert(server.CachedBrowse("movies", "alias", new())?.Value.Items.Length == 611, "all accumulated pages survive catalog restoration");
        var caches = Directory.GetFiles(Path.Combine(data, "browser-cache"), "*.json");
        Assert(caches.All(path => !File.ReadAllText(path).Contains("cache-secret")), "browser cache never persists token-bearing image URLs");
        Assert(restored.Latest.All(x => x.Artwork.Contains("api_key=cache-secret")), "cached artwork regains current in-memory authentication");
        var otherUser = new MediaServer(core, profile with { UserId = "other" });
        Assert(!otherUser.RestoreHome(), "cache identities isolate users on the same server");
        var detail = await server.Detail(new DemoMedia("series", "Series", "", "", "", "", "", Kind: "series"), default);
        File.WriteAllText(Path.Combine(data, "detail.json"), JsonSerializer.Serialize(detail));
        Assert(detail.SelectedSeasonId == "s1" && detail.InitialEpisodeNumber == 2 && detail.Episodes?.Single(x => x.Number == 2).Overview == "episode overview", "smart default skips specials and selects first unfinished regular episode with synopsis");
        Assert(detail.OfficialRating == "TV-14" && detail.Cast?.Single().Name == "Actor" && detail.Similar?.Single().Id == "similar", "detail projects real rating, cast and similar endpoint results");
        var episodePoster = await server.Poster(new DemoMedia("e2", "Episode", "", "", "", "episode-still", "", Kind: "episode", SeriesId: "series"), default);
        Assert(episodePoster.Contains("/Items/series/Images/Primary") && !episodePoster.Contains("/Items/e2/"), "portrait episode cards use the series poster instead of an episode still");
        Assert(await server.Poster(new DemoMedia("movie", "Movie", "", "", "", "movie-poster", ""), default) == "movie-poster", "movie portrait cards retain their own primary poster");
        var movie = new DemoMedia("movie", "Movie", "", "", "", "", "", DurationSeconds: 120);
        var preferred = await server.Resolve(movie, 1, default);
        Assert(preferred.Report?.MediaSourceId == "direct", "playback chooses DirectPlay ahead of source order");
        Assert((await server.Resolve(movie, 1, default, 1)).Report?.MediaSourceId == "stream", "recovery tries DirectStream as the second candidate");
        fixture.FailPlayback = true;
        Assert((await server.Resolve(movie, 1, default)).Uri.Contains("/Videos/movie/stream"), "PlaybackInfo outage falls back to server direct stream");
        var resource = "OcPlayer.BrowserParity." + Guid.NewGuid().ToString("N"); var directory = Path.Combine(data, "profiles"); Directory.CreateDirectory(directory);
        var profiles = new ServerProfiles(directory, resource);
        try
        {
            profiles.Save(profile, true); profiles.Save(profile with { Id = "second", Token = "second-secret" }, true); profiles.SetDefault(profile.Id);
            var again = new ServerProfiles(directory, resource);
            Assert(again.Items.Count == 2 && again.Startup()?.Id == profile.Id && again.Get("second")?.Token == "second-secret", "multiple vault profiles and explicit startup default survive recreation");
            again.Invalidate(profile.Id); Assert(again.Items.Single(x => x.Id == profile.Id).NeedsLogin && again.Get(profile.Id)?.Token is null, "authentication invalidation removes token and flags only the affected profile");
            again.Delete(profile.Id); Assert(again.Items.Single().Id == "second" && again.Get("second")?.Token == "second-secret", "deleting one server preserves all other credentials");
            Assert(!File.ReadAllText(Path.Combine(directory, "servers.json")).Contains("secret"), "profile index contains no credentials");
        }
        finally { profiles.Delete(profile.Id); profiles.Delete("second"); }
        Evidence.Add(new { stage = "browsing-parity", pages = 11, catalogItems = all.Count, cachedFiles = caches.Length });
    }

    private sealed class BrowsingFixture : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource _stop = new();
        public string Url { get; }
        public bool FailNext, FailPlayback;
        public ConcurrentQueue<string> Queries { get; } = new();
        public BrowsingFixture() { _listener.Start(); Url = "http://127.0.0.1:" + ((IPEndPoint)_listener.LocalEndpoint).Port; _ = Listen(); }
        private async Task Listen()
        {
            try { while (!_stop.IsCancellationRequested) { var client = await _listener.AcceptTcpClientAsync(_stop.Token); _ = Respond(client); } }
            catch (Exception ex) when (ex is OperationCanceledException or SocketException or ObjectDisposedException) { }
        }
        private static object Item(string id, string type = "Movie", string? season = null, int? number = null, bool played = false) => new
        {
            Id = id, Name = id, Type = type, Overview = "episode overview", OfficialRating = "TV-14", CommunityRating = 8.5,
            ImageTags = new { Primary = "poster" }, SeasonId = season, SeriesId = type == "Episode" ? "series" : null,
            ParentIndexNumber = type == "Episode" ? 1 : (int?)null, IndexNumber = type is "Episode" or "Season" ? number : (int?)null,
            UserData = new { Played = played }, People = new[] { new { Id = "actor", Name = "Actor", Type = "Actor", Role = "Role" } }
        };
        private async Task Respond(TcpClient client)
        {
            using (client) try
            {
                using var stream = client.GetStream(); using var reader = new StreamReader(stream, Encoding.UTF8, false, leaveOpen: true);
                var line = await reader.ReadLineAsync(_stop.Token); if (line is null) return;
                var target = line.Split(' ')[1]; Queries.Enqueue(Uri.UnescapeDataString(target));
                while (await reader.ReadLineAsync(_stop.Token) is { Length: > 0 }) { }
                var uri = new Uri(Url + target); var path = uri.AbsolutePath; int status = 200; object body;
                var query = uri.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries).Select(x => x.Split('=', 2)).GroupBy(x => x[0].ToLowerInvariant()).ToDictionary(x => x.Key, x => Uri.UnescapeDataString(x.First().Length > 1 ? x.First()[1] : ""));
                if (path.EndsWith("/Views") || path.EndsWith("/UserViews")) body = new { Items = new[] { new { Id = "movies", Name = "Movies", CollectionType = "movies", ImageTags = new { Primary = "cover" } }, new { Id = "tv", Name = "TV", CollectionType = "tvshows", ImageTags = new { Primary = "cover" } }, new { Id = "boxes", Name = "Boxes", CollectionType = "boxsets", ImageTags = new { Primary = "cover" } } } };
                else if (path.EndsWith("/Resume")) body = new { Items = new[] { Item("resume") } };
                else if (path.EndsWith("/Latest")) body = new[] { Item("latest") };
                else if (path.EndsWith("/NextUp")) { status = FailNext ? 503 : 200; body = new { Items = new[] { Item("resume"), Item("next") } }; }
                else if (path.EndsWith("/Seasons") || query.TryGetValue("includeitemtypes", out var kinds) && kinds == "Season") body = new { Items = new[] { Item("sp", "Season", number: 0), Item("s1", "Season", number: 1) } };
                else if (path.EndsWith("/Episodes")) body = new { Items = new[] { Item("e1", "Episode", "s1", 1, true), Item("e2", "Episode", "s1", 2) } };
                else if (path.EndsWith("/Similar")) body = new { Items = new[] { Item("similar") } };
                else if (path.EndsWith("/Items/series")) body = Item("series", "Series");
                else if (path.EndsWith("/PlaybackInfo")) { status = FailPlayback ? 503 : 200; body = new { PlaySessionId = "session", MediaSources = new[] { new { Id = "other", SupportsDirectPlay = false, SupportsDirectStream = false }, new { Id = "stream", SupportsDirectPlay = false, SupportsDirectStream = true }, new { Id = "direct", SupportsDirectPlay = true, SupportsDirectStream = true } } }; }
                else if (path.EndsWith("/Items")) { var start = query.TryGetValue("startindex", out var s) ? int.Parse(s) : 0; var limit = query.TryGetValue("limit", out var l) ? int.Parse(l) : 60; body = new { Items = Enumerable.Range(start, Math.Max(0, Math.Min(limit, 611 - start))).Select(i => Item("item-" + i)).ToArray(), TotalRecordCount = 611, StartIndex = start }; }
                else if (path.EndsWith("/System/Info/Public")) body = new { Id = "same-server", ServerName = "Fixture", ProductName = "Jellyfin", Version = "10.11" };
                else body = new { };
                var payload = JsonSerializer.SerializeToUtf8Bytes(body);
                await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {payload.Length}\r\nConnection: close\r\n\r\n"), _stop.Token);
                await stream.WriteAsync(payload, _stop.Token);
            }
            catch (Exception ex) { if (!_stop.IsCancellationRequested) Console.WriteLine("Browser fixture: " + ex); }
        }
        public void Dispose() { _stop.Cancel(); _listener.Stop(); }
    }
}

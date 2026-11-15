using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Services;

internal static class Program
{
    private static int _assertions;
    private static readonly List<object> Evidence = [];
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 2) throw new ArgumentException("Pass a local media file (or --server-only) and a new verification directory.");
        var output = Path.GetFullPath(args[1]); Directory.CreateDirectory(output);
        var data = Path.Combine(output, "data"); Directory.CreateDirectory(data);
        var config = JsonSerializer.Serialize(new { dataDirectory = data, locale = "zh-CN" });
        var hwnd = CreateWindowEx(0, "STATIC", "OcPlayer integration test", 0x80000000, 0, 0, 640, 360, 0, 0, 0, 0);
        if (hwnd == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            using (var core = new OcpCoreClient(config))
            {
                Assert(core.Ping().Ok, "real Core DLL loads");
                VerifyBackdropLifecycle();
                VerifyServer(core, hwnd, args[0] == "--server-only" ? null : args[0], data);
                if (args[0] == "--server-only")
                {
                    File.WriteAllText(Path.Combine(output, "results.json"), JsonSerializer.Serialize(new { passed = true, assertions = _assertions, evidence = Evidence }, new JsonSerializerOptions { WriteIndented = true }));
                    Console.WriteLine($"Passed {_assertions} server integration assertions."); return 0;
                }
                using var session = new PlaybackSession(core);
                string? error = null; session.Failed += value => error = value;
                session.Attach((ulong)hwnd.ToInt64(), 640, 360, 1);
                Marshal.Release(session.GetSwapChain());
                session.Open(new PlaybackSource("unicode-local", "Unicode local media", Path.GetFullPath(args[0])));
                Pump(session, core, () => session.Ready && Frames(session, "renderedVideoFrames") > 5, () => error);
                Assert(session.DurationSeconds > 60, "duration comes from actual media");
                Assert(Frames(session, "decodedVideoFrames") > 5 && Frames(session, "pushedAudioFrames") > 0, "native video and audio are decoded");
                session.SetPlaying(false);
                var paused = session.PositionSeconds;
                PumpFor(session, core, .5);
                Assert(!session.Playing && Math.Abs(session.PositionSeconds - paused) < 1, "pause freezes the decoder clock");
                session.Seek(40); session.SetRate(1.5); session.SetVolume(.33);
                session.SetPlaying(true);
                Pump(session, core, () => session.PositionSeconds > 41, () => error);
                using (var playback = core.Snapshot("playback"))
                {
                    var value = playback.RootElement;
                    Assert(value.GetProperty("positionSeconds").GetDouble() > 40 && value.GetProperty("rate").GetDouble() == 1.5 && value.GetProperty("volume").GetDouble() == .33, "native controls update shared Core state");
                }
                var audio = session.Tracks.EnumerateArray().First(x => x.GetProperty("kind").GetInt32() == 1);
                session.SelectTrack(audio.GetProperty("id").GetInt64(), false);
                session.SelectTrack(-1, true);
                session.Resize(800, 450, 1.25); Marshal.Release(session.GetSwapChain()); PumpFor(session, core, .3);
                Assert(error is null && Frames(session, "renderFailures") == 0, "resize and track changes preserve rendering");
                Evidence.Add(new { stage = "playback", session.PositionSeconds, session.DurationSeconds, session.Stats, session.Tracks });
                session.Stop();
                session.Open(new PlaybackSource("unicode-local", "Unicode local media", Path.GetFullPath(args[0])));
                Pump(session, core, () => session.Ready && session.PositionSeconds >= 40, () => error);
                Assert(session.PositionSeconds >= 40, "reopening restores Core progress");
            }
            using (var core = new OcpCoreClient(config))
            {
                var record = PlaybackSession.Require(core.Call("progress.get", new { tenantId = "local", itemId = "unicode-local" })).GetProperty("progress");
                Assert(record.GetProperty("positionSeconds").GetDouble() >= 40 && !record.GetProperty("completed").GetBoolean(), "progress survives destroying both native handles");
                using var snapshot = core.Snapshot(); Assert(!snapshot.RootElement.GetProperty("surfaceAttached").GetBoolean(), "new Core has no leaked surface");
                using var failure = new PlaybackSession(core); string? error = null; failure.Failed += value => error = value;
                failure.Attach((ulong)hwnd.ToInt64(), 640, 360, 1);
                try { failure.Open(new PlaybackSource("missing", "Missing file", Path.Combine(output, "does-not-exist.mp4"))); }
                catch (InvalidOperationException) when (error is not null) { }
                Pump(failure, core, () => error is not null, () => null);
                failure.Stop();
                var missing = PlaybackSession.Require(core.Call("progress.get", new { tenantId = "local", itemId = "missing" })).GetProperty("progress");
                Assert(missing.ValueKind == JsonValueKind.Null, "failed opening is never recorded as completed playback");
            }
            File.WriteAllText(Path.Combine(output, "results.json"), JsonSerializer.Serialize(new { passed = true, assertions = _assertions, evidence = Evidence }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine($"Passed {_assertions} integration assertions."); return 0;
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(output, "failure.txt"), ex.ToString()); Console.Error.WriteLine(ex); return 1; }
        finally { DestroyWindow(hwnd); }
    }

    private static void VerifyBackdropLifecycle()
    {
        var view = new OcPlayer.Windows.Controls.AmbientBackdropView();
        var model = new OcPlayer.Windows.ViewModels.DemoViewModel();
        var controller = new AmbientBackdropController(view, model);
        controller.Update();
        // Leaving/entering Demo changes the session through the same branch as
        // connecting, replacing or disconnecting a server, without credentials.
        for (var i = 0; i < 3; i++)
        {
            model.DemoMode = true; controller.Update();
            Assert(view.CurrentSource is not null, "new session loads its ambient background");
            model.DemoMode = false; controller.Update();
            Assert(view.CurrentSource is null, "ending a session cancels and clears its background");
        }
        controller.Update(true);
        model.DemoMode = true; controller.Update();
        model.Route = "detail"; controller.Update();
        model.Route = "home"; controller.Update();
        Assert(view.CurrentSource is not null, "detail navigation retains a usable session background");
        controller.Dispose(); controller.Dispose(); controller.Update();
        Assert(view.Disposed, "background cleanup tolerates repeated disposal and late updates");
    }

    private static void VerifyServer(OcpCoreClient core, IntPtr hwnd, string? media, string data)
    {
        // Exercise the Windows projection against a local wire fixture through
        // the real Rust HTTP client. No credentials or remote server are used.
        var listener = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0); listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        using var shutdown = new CancellationTokenSource();
        var requests = new List<string>();
        var randomQueries = new List<string>();
        var watchedRequests = new List<(string Method, string Path)>();
        object Episode(string id, int number, int season, bool omitSeasonId = false, bool played = false) => new
        {
            Id = id, Name = "Episode " + number, Type = "Episode", SeriesId = "series",
            SeasonId = omitSeasonId ? null : "season-" + season, IndexNumber = number, ParentIndexNumber = season,
            RunTimeTicks = 1200000000L, ImageTags = new { Primary = "episode-image" },
            ParentLogoItemId = "series", ParentLogoImageTag = "series-logo",
            UserData = new { PlaybackPositionTicks = id == "ep2" ? 300000000L : 0L, PlayedPercentage = id == "ep2" ? 25d : 0d, Played = played }
        };
        var worker = Task.Run(async () =>
        {
            while (!shutdown.IsCancellationRequested)
            {
                System.Net.Sockets.TcpClient client;
                try { client = await listener.AcceptTcpClientAsync(shutdown.Token); } catch (OperationCanceledException) { break; }
                using var connection = client;
                using var stream = client.GetStream();
                using var reader = new StreamReader(stream, Encoding.ASCII, false, 1024, true);
                var line = await reader.ReadLineAsync();
                var method = line!.Split(' ')[0];
                var target = line!.Split(' ')[1]; var requestPath = target.Split('?')[0];
                var mode = requestPath.StartsWith("/emby/") ? "emby" : requestPath.StartsWith("/denied/") ? "denied" : requestPath.StartsWith("/partial/") ? "partial" : requestPath.StartsWith("/slow/") ? "slow" : "";
                var path = mode.Length == 0 ? requestPath : requestPath[(mode.Length + 1)..];
                var length = 0;
                while (!string.IsNullOrEmpty(line = await reader.ReadLineAsync()))
                    if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = int.Parse(line[15..].Trim());
                var requestBody = "";
                if (length > 0) { var bodyChars = new char[length]; await reader.ReadBlockAsync(bodyChars); requestBody = new string(bodyChars); }
                lock (requests) requests.Add(requestPath);
                if (path.Contains("/PlayedItems/")) lock (watchedRequests) watchedRequests.Add((method, requestPath));
                if (target.Contains("sortBy=Random")) lock (randomQueries) randomQueries.Add(target);
                if (mode == "slow") await Task.Delay(500);
                var status = requestBody.Contains("wrong") ? 401 : mode == "denied" && path.EndsWith("Views") || mode == "partial" && path.EndsWith("NextUp") ? 403 : 200;
                object body = path == "/System/Info/Public" ? new { Id = "fixture-server", ServerName = "Fixture server", ProductName = mode == "emby" ? "Emby" : "Jellyfin", Version = "10.11" }
                    : path.EndsWith("AuthenticateByName") ? new { AccessToken = "local-fixture-token", User = new { Id = "fixture-user", Name = "fixture" } }
                    : mode == "emby" && path.EndsWith("Items/Latest") ? new[] { new { Id = "movie", Name = "Fixture movie", Type = "Movie" } }
                    : path.EndsWith("Views") ? new { Items = new[] { new { Id = "library", Name = "Movies", CollectionType = "movies" } } }
                    : path == "/Items/series" ? new { Id = "series", Name = "Fixture series", OriginalTitle = "Original series title", Type = "Series", Overview = "Series synopsis", Genres = new[] { "Animation" }, ImageTags = new { Logo = "series-logo" }, BackdropImageTags = new[] { "series-backdrop" } }
                    : path.EndsWith("Items/Resume") ? new { Items = new[] { Episode("ep2", 1, 2) } }
                    : path.EndsWith("NextUp") ? new { Items = new[] { Episode("ep2-next", 7, 2, omitSeasonId: true) } }
                    : path == "/Items/ep1" ? Episode("ep1", 1, 1)
                    : path == "/Items/ep2" ? Episode("ep2", 1, 2)
                    : path == "/Items/ep2-next" ? Episode("ep2-next", 7, 2, omitSeasonId: true)
                    : path == "/Items/ep2-played" ? Episode("ep2-played", 9, 2, played: true)
                    : target.Contains("includeItemTypes=Season") ? new { Items = new[] { new { Id = "season-1", Name = "Season 1", Type = "Season", IndexNumber = 1 }, new { Id = "season-2", Name = "Season 2", Type = "Season", IndexNumber = 2 } } }
                    : path == "/Shows/series/Episodes" ? new { Items = target.Contains("seasonId=season-empty") ? Array.Empty<object>()
                        : target.Contains("seasonId=season-2") ? new[] { Episode("ep2-next", 7, 2), Episode("ep2", 1, 2), Episode("ep2-played", 9, 2, played: true) }
                        : new[] { Episode("ep1", 1, 1) } }
                    : path.EndsWith("PlaybackInfo") ? new { MediaSources = new[] { new { Id = "source", Container = "mp4", SupportsDirectPlay = true } }, PlaySessionId = "session" }
                    : target.Contains("sortBy=Random") ? new { Items = new object[] {
                        new { Id = "ambient", Name = "Backdrop film", Type = "Movie", BackdropImageTags = new[] { "backdrop-tag" } },
                        new { Id = "no-backdrop", Name = "Poster only", Type = "Movie", ImageTags = new { Primary = "poster-tag" } }
                    }, TotalRecordCount = 2 }
                    : new { Items = new[] { new { Id = "movie", Name = "Fixture movie", Type = "Movie", RunTimeTicks = 1200000000L, Genres = new[] { "Test" }, ImageTags = new { Primary = "image-tag" }, UserData = new { PlaybackPositionTicks = 100000000L, PlayedPercentage = 8.3, Played = false } } }, TotalRecordCount = 1 };
                var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(body));
                try
                {
                    await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {bytes.Length}\r\nConnection: close\r\n\r\n"));
                    await stream.WriteAsync(bytes);
                }
                catch (IOException) { /* A cancelled request may close its connection before the fixture responds. */ }
            }
        });
        try
        {
            Assert(MediaServer.NormalizeAddress($" 127.0.0.1:{port}/emby/ ") == $"http://127.0.0.1:{port}/emby", "host/port input preserves reverse proxy path and normalizes slashes");
            foreach (var invalid in new[] { "", "file:///test", "http://user:pass@localhost", "http://localhost?api_key=secret" })
            {
                try { MediaServer.NormalizeAddress(invalid); throw new InvalidOperationException("Accepted invalid server address"); }
                catch (ArgumentException) { }
            }
            Assert(true, "invalid addresses and embedded credentials are rejected before network login");
            var server = MediaServer.Connect(core, $"127.0.0.1:{port}", "jellyfin", "fixture", "fixture", default).GetAwaiter().GetResult();
            var profile = server.Profile;
            Assert(profile.ServerName == "Fixture server" && profile.UserName == "fixture" && profile.ServerVersion == "10.11", "connection verifies home and captures server/account identity");
            Assert(server.Latest.First().Artwork.Contains("api_key=local-fixture-token"), "server artwork carries authentication for WinUI BitmapImage");
            var backdrops = server.RandomBackdrops(default).GetAwaiter().GetResult();
            Assert(backdrops.Length == 1 && backdrops[0].Id == "ambient" && randomQueries.Any(x => x.Contains("limit=24") && x.Contains("recursive=true")),
                "ambient pool uses Core random library query and excludes entries without backdrops");
            var ambientUrl = MediaServer.AmbientImage(backdrops[0].BackdropArtwork);
            Assert(ambientUrl.Contains("maxWidth=800") && !ambientUrl.Contains("1280") && ambientUrl.Contains("api_key=local-fixture-token") && ambientUrl.Contains("backdrop-tag"),
                "ambient request downsizes the image while preserving image tag and authentication");
            Assert(MediaServer.AmbientImage("D:\\fixture\\backdrop.jpg") == "D:\\fixture\\backdrop.jpg", "local ambient fixtures retain their file path");
            var detailUrl = MediaServer.DetailImage(backdrops[0].BackdropArtwork);
            Assert(detailUrl.Contains("maxWidth=1600") && detailUrl.Contains("api_key=local-fixture-token"), "detail requests one larger image shared by sharp and blurred layers");
            try { MediaServer.Connect(core, $"127.0.0.1:{port}", "jellyfin", "wrong", "wrong", default).GetAwaiter().GetResult(); throw new InvalidOperationException("Bad credentials were accepted"); }
            catch (ServerConnectionException ex) { Assert(ex.Message.Contains("账号验证失败"), "HTTP 401 produces a retryable form error in Chinese"); }
            try { MediaServer.Connect(core, $"127.0.0.1:{port}/denied", "jellyfin", "fixture", "fixture", default).GetAwaiter().GetResult(); throw new InvalidOperationException("Unreadable library was activated"); }
            catch (ServerConnectionException ex) { Assert(ex.Message.Contains("无法读取媒体库"), "successful login with denied libraries cannot activate a server"); }
            using (var cancel = new CancellationTokenSource(100))
            {
                try { MediaServer.Connect(core, $"127.0.0.1:{port}/slow", "jellyfin", "fixture", "fixture", cancel.Token).GetAwaiter().GetResult(); throw new InvalidOperationException("Cancelled connection activated"); }
                catch (OperationCanceledException) { Assert(true, "in-flight login cancellation cannot activate a server"); }
            }
            var emby = MediaServer.Connect(core, $"127.0.0.1:{port}/emby/", "emby", "fixture", "fixture", default).GetAwaiter().GetResult();
            Assert(emby.Profile.Kind == "emby" && emby.Libraries.Count == 1 && requests.Contains("/emby/System/Info/Public"), "Emby connects through a reverse proxy base path");
            var partial = MediaServer.Connect(core, $"127.0.0.1:{port}/partial", "jellyfin", "fixture", "fixture", default).GetAwaiter().GetResult();
            Assert(partial.Libraries.Count == 1 && partial.HomeWarning?.Contains("接下来看") == true, "partial home failure remains usable and exposes the failed section");
            var savedDirectory = Environment.GetEnvironmentVariable("OCP_DATA_DIRECTORY");
            Environment.SetEnvironmentVariable("OCP_DATA_DIRECTORY", data);
            var resource = "OcPlayer.Integration." + Guid.NewGuid();
            try
            {
                using (var runtime = new CoreRuntime(resource))
                {
                    runtime.SetServer(new MediaServer(runtime.Client, profile));
                    runtime.SetServer(new MediaServer(runtime.Client, emby.Profile));
                }
                using (var restored = new CoreRuntime(resource))
                {
                    Assert(restored.Server?.Profile.Kind == "emby" && restored.Server.Profile.Token == "local-fixture-token", "PasswordVault replacement restores the selected server after runtime restart");
                    restored.DisconnectServer();
                }
                using (var disconnected = new CoreRuntime(resource)) Assert(disconnected.Server is null, "disconnect removes automatic login from PasswordVault");
            }
            finally
            {
                var vault = new global::Windows.Security.Credentials.PasswordVault();
                try { vault.Remove(vault.Retrieve(resource, "active-server")); } catch (COMException) { }
                Environment.SetEnvironmentVariable("OCP_DATA_DIRECTORY", savedDirectory);
            }
            var items = server.Browse("library", "Fixture", "名称", "未观看", default).GetAwaiter().GetResult();
            Assert(profile.UserId == "fixture-user" && server.Libraries.Count == 1 && items.Length == 1 && items[0].DurationSeconds == 120, "login, home and library use Core HTTP and model projection");
            var series = server.Detail(items[0] with { Id = "series", Kind = "series" }, default, "season-2").GetAwaiter().GetResult();
            Assert(series.Seasons?.Length == 2 && series.Episodes?.First().MediaId == "ep2" && series.SelectedSeasonId == "season-2", "season selection retains the correct server episode identity");
            Assert(new Uri(series.LogoArtwork).AbsolutePath == "/Items/series/Images/Logo"
                && series.LogoArtwork.Contains("series-logo") && series.LogoArtwork.Contains("api_key=local-fixture-token")
                && series.Title == "Fixture series" && series.OriginalTitle == "Original series title",
                "series detail projects its authenticated Logo separately from localized and original titles");
            Assert(new Uri(server.Resume.Single().LogoArtwork).AbsolutePath == "/Items/series/Images/Logo",
                "inherited Logo requests use the parent image owner rather than the episode ID");
            Assert(items[0].LogoArtwork.Length == 0, "media without a Logo retains the text title fallback");
            var resume = server.Detail(server.Resume.Single(), default).GetAwaiter().GetResult();
            Assert(resume.Id == "series" && resume.Title == "Fixture series" && resume.Description == "Series synopsis" && resume.DetailBackdrop.Contains("series-backdrop"),
                "resume episode opens its series metadata and backdrop");
            Assert(resume.SelectedSeasonId == "season-2" && resume.InitialEpisodeNumber == 1 && resume.Episodes?.First().MediaId == "ep2",
                "resume selects its own season when episode numbers repeat");
            var next = server.Detail(server.NextUp.Single(), default).GetAwaiter().GetResult();
            Assert(next.Id == "series" && next.SelectedSeasonId == "season-2" && next.InitialEpisodeNumber == 7 && next.EpisodeLabel == "S2E7",
                "next up uses the season number when season ID is absent and selects the exact episode");
            Assert(next.Episodes?.Select(x => x.Number).SequenceEqual(new[] { 1, 7, 9 }) == true,
                "sparse server episodes remain sorted without fabricated missing episodes");
            Assert(next.Episodes?.First(x => x.Number == 1).WatchStatus == "观看中"
                && next.Episodes.First(x => x.Number == 7).WatchStatus == "未观看"
                && next.Episodes.First(x => x.Number == 9).IsPlayed,
                "server playback progress and played flag provide distinct episode watching states");
            Assert(!next.SelectedIsPlayed(1) && !next.SelectedIsPlayed(7) && next.SelectedIsPlayed(9)
                && !(next with { Progress = 100, Played = true }).SelectedIsPlayed(1),
                "watched toggle follows the selected Jellyfin episode Played flag independently of series state");
            using (var fullProgress = JsonDocument.Parse("""{"id":"ep-full","kind":"episode","playState":{"percentage":1,"played":false}}"""))
                Assert(!server.Project(fullProgress.RootElement).IsPlayed,
                    "100 percent progress cannot override Jellyfin Played=false for watched status");
            Assert(next.PlaybackProgress(1) == 25 && next.PlaybackProgress(7) == 0 && next.PlaybackProgress(9) == 100,
                "detail playback button uses the selected episode progress for resume, unplayed and completed episodes");
            Assert((items[0] with { Progress = double.NaN }).PlaybackProgress(1) == 0
                && (items[0] with { Progress = 125 }).PlaybackProgress(1) == 100,
                "invalid playback percentages cannot overflow the button fill");
            var targetEpisode = next.Episodes!.First(x => x.Number == 7);
            var markedEpisode = server.SetEpisodeWatched(targetEpisode, true, default).GetAwaiter().GetResult();
            var unmarkedEpisode = server.SetEpisodeWatched(markedEpisode, false, default).GetAwaiter().GetResult();
            Assert(markedEpisode.IsPlayed && unmarkedEpisode.WatchStatus == "未观看" && markedEpisode.MediaId == targetEpisode.MediaId,
                "an episode can be marked watched and restored to unwatched without changing its identity");
            Assert(watchedRequests.SequenceEqual(new[] { ("POST", "/Users/fixture-user/PlayedItems/ep2-next"), ("DELETE", "/Users/fixture-user/PlayedItems/ep2-next") }),
                "episode watching actions target only that episode using the Core server commands");
            var resumedSource = server.Resolve(resume, 1, default).GetAwaiter().GetResult();
            var nextSource = server.Resolve(resume, 7, default).GetAwaiter().GetResult();
            Assert(resumedSource.Id == "ep2" && resumedSource.ResumeSeconds == 30 && nextSource.Id == "ep2-next" && nextSource.ResumeSeconds == 0,
                "changing selected episode resolves its own identity and progress");
            Assert(resume.PlaybackPositionSeconds(1) == resumedSource.ResumeSeconds && resume.PlaybackButtonLabel(1) == "继续 00:00:30"
                && resume.PlaybackButtonLabel(7) == "播放" && resume.PlaybackButtonLabel(9) == "播放",
                "button resume time matches the playback source and clears when selecting unplayed or completed episodes");
            Assert((items[0] with { Progress = 50, DurationSeconds = 7344 }).PlaybackButtonLabel(1) == "继续 01:01:12",
                "resume time includes hours for long media");
            var replay = server.Resolve(resume, 9, default).GetAwaiter().GetResult();
            Assert(replay.Id == "ep2-played" && replay.ResumeSeconds == 0, "completed episodes replay from the beginning");
            var firstSeason = server.Detail(resume, default, "season-1").GetAwaiter().GetResult();
            Assert(firstSeason.SelectedSeasonId == "season-1" && firstSeason.Episodes?.Single().MediaId == "ep1" && firstSeason.InitialEpisodeNumber == 1,
                "changing seasons resets selection to an episode in the new season");
            var emptySeason = server.Detail(resume, default, "season-empty").GetAwaiter().GetResult();
            Assert(emptySeason.Episodes?.Length == 0 && emptySeason.EpisodeLabel is null, "empty seasons do not retain the previous episode");
            var source = server.Resolve(items[0], 1, default).GetAwaiter().GetResult();
            Assert(source.TenantId.EndsWith(":fixture-user") && source.Uri.Contains("source"), "playback URL and tenant come from Core server contract");
            if (media is not null) using (var session = new PlaybackSession(core))
            {
                string? error = null; session.Failed += message => error = message;
                session.Attach((ulong)hwnd.ToInt64(), 640, 360, 1);
                session.Open(source with { Uri = Path.GetFullPath(media) });
                Pump(session, core, () => session.Ready && Frames(session, "renderedVideoFrames") > 2, () => error);
                session.SetPlaying(false); session.Stop(); session.ReportingCompleted.GetAwaiter().GetResult();
                Assert(session.ReportingError is null && requests.IndexOf("/Sessions/Playing") < requests.IndexOf("/Sessions/Playing/Progress") && requests.Contains("/Sessions/Playing/Stopped"), "native start, progress and stop are reported to server through Core in order");
            }
            lock (requests) Evidence.Add(new { stage = "server-fixture", requests = requests.ToArray() });
        }
        finally { shutdown.Cancel(); worker.GetAwaiter().GetResult(); listener.Stop(); }
    }

    private static ulong Frames(PlaybackSession session, string name) => session.Stats.ValueKind == JsonValueKind.Object ? session.Stats.GetProperty(name).GetUInt64() : 0;
    private static void Assert(bool condition, string description) { if (!condition) throw new InvalidOperationException(description); _assertions++; Console.WriteLine("PASS " + description); }
    private static void Pump(PlaybackSession session, OcpCoreClient core, Func<bool> done, Func<string?> error)
    {
        var watch = Stopwatch.StartNew();
        while (!done())
        {
            if (watch.Elapsed.TotalSeconds > 30) throw new TimeoutException("Native playback did not reach the expected state.");
            session.Tick(Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency);
            if (error() is { } message) throw new InvalidOperationException(message);
            while (core.TryPollEvent(out _)) { }
            Thread.Sleep(16);
        }
    }
    private static void PumpFor(PlaybackSession session, OcpCoreClient core, double seconds)
    {
        var timer = Stopwatch.StartNew(); Pump(session, core, () => timer.Elapsed.TotalSeconds >= seconds, () => null);
    }
    [DllImport("user32", EntryPoint = "CreateWindowExW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(uint exStyle, string className, string title, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameters);
    [DllImport("user32")] private static extern bool DestroyWindow(IntPtr hwnd);
}

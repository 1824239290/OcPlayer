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
        if (args.Length != 2) throw new ArgumentException("Pass a local media file and a new verification directory.");
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
                VerifyServer(core, hwnd, args[0], data);
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

    private static void VerifyServer(OcpCoreClient core, IntPtr hwnd, string media, string data)
    {
        // Exercise the Windows projection against a local wire fixture through
        // the real Rust HTTP client. No credentials or remote server are used.
        var listener = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0); listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        using var shutdown = new CancellationTokenSource();
        var requests = new List<string>();
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
                var target = line!.Split(' ')[1]; var requestPath = target.Split('?')[0];
                var mode = requestPath.StartsWith("/emby/") ? "emby" : requestPath.StartsWith("/denied/") ? "denied" : requestPath.StartsWith("/partial/") ? "partial" : requestPath.StartsWith("/slow/") ? "slow" : "";
                var path = mode.Length == 0 ? requestPath : requestPath[(mode.Length + 1)..];
                var length = 0;
                while (!string.IsNullOrEmpty(line = await reader.ReadLineAsync()))
                    if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = int.Parse(line[15..].Trim());
                var requestBody = "";
                if (length > 0) { var bodyChars = new char[length]; await reader.ReadBlockAsync(bodyChars); requestBody = new string(bodyChars); }
                lock (requests) requests.Add(requestPath);
                if (mode == "slow") await Task.Delay(500);
                var status = requestBody.Contains("wrong") ? 401 : mode == "denied" && path.EndsWith("Views") || mode == "partial" && path.EndsWith("NextUp") ? 403 : 200;
                object body = path == "/System/Info/Public" ? new { Id = "fixture-server", ServerName = "Fixture server", ProductName = mode == "emby" ? "Emby" : "Jellyfin", Version = "10.11" }
                    : path.EndsWith("AuthenticateByName") ? new { AccessToken = "local-fixture-token", User = new { Id = "fixture-user", Name = "fixture" } }
                    : mode == "emby" && path.EndsWith("Items/Latest") ? new[] { new { Id = "movie", Name = "Fixture movie", Type = "Movie" } }
                    : path.EndsWith("Views") ? new { Items = new[] { new { Id = "library", Name = "Movies", CollectionType = "movies" } } }
                    : path == "/Items/series" ? new { Id = "series", Name = "Fixture series", Type = "Series" }
                    : target.Contains("includeItemTypes=Season") ? new { Items = new[] { new { Id = "season-1", Name = "Season 1", Type = "Season", IndexNumber = 1 }, new { Id = "season-2", Name = "Season 2", Type = "Season", IndexNumber = 2 } } }
                    : path == "/Shows/series/Episodes" ? new { Items = new[] { new { Id = target.Contains("seasonId=season-2") ? "ep2" : "ep1", Name = "Episode 1", Type = "Episode", IndexNumber = 1, ParentIndexNumber = target.Contains("seasonId=season-2") ? 2 : 1 } } }
                    : path.EndsWith("PlaybackInfo") ? new { MediaSources = new[] { new { Id = "source", Container = "mp4", SupportsDirectPlay = true } }, PlaySessionId = "session" }
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
            Assert(series.Seasons?.Length == 2 && series.Episodes?.Single().MediaId == "ep2" && series.SelectedSeasonId == "season-2", "season selection retains the correct server episode identity");
            var source = server.Resolve(items[0], 1, default).GetAwaiter().GetResult();
            Assert(source.TenantId.EndsWith(":fixture-user") && source.Uri.Contains("source"), "playback URL and tenant come from Core server contract");
            using (var session = new PlaybackSession(core))
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

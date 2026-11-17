using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Services;

internal static partial class Program
{
    private static async Task VerifyServerPlayerMenus(OcpCoreClient core, string data)
    {
        var directory = Path.Combine(data, "server-player-menus");
        Directory.CreateDirectory(directory);
        var preferencesDirectory = Path.Combine(directory, "preferences");
        Assert(PlaybackPreferences.Load(preferencesDirectory).SubtitleScale == 1, "subtitle scale starts at the macOS 100 percent default");
        new PlaybackPreferences(1.7).Save(preferencesDirectory);
        Assert(PlaybackPreferences.Load(preferencesDirectory).SubtitleScale == 1.7, "subtitle scale survives reopening its preference store");
        new PlaybackPreferences(9).Save(preferencesDirectory);
        Assert(PlaybackPreferences.Load(preferencesDirectory).SubtitleScale == 3, "subtitle scale persistence clamps to the supported 300 percent maximum");
        var preferencesPath = Path.Combine(preferencesDirectory, "playback-preferences.json");
        File.WriteAllText(preferencesPath, "{broken");
        Assert(PlaybackPreferences.Load(preferencesDirectory).SubtitleScale == 1 && File.ReadAllText(preferencesPath) == "{broken",
            "damaged subtitle preferences use defaults without destroying the original file");

        using var fixture = new ServerPlayerMenuFixture();
        using var foreign = new ServerPlayerMenuFixture();
        var profile = new ServerProfile("menu-fixture", "jellyfin", fixture.Url + "proxy/api", "fixture-user", ServerPlayerMenuFixture.Token);
        var report = new PlaybackReport(JsonSerializer.SerializeToElement(profile, MediaServer.JsonOptions), "item", "source-b", null);
        var chapters = await PlaybackChapters.LoadAsync(core, report, default);
        Assert(chapters.Select(x => x.StartSeconds).SequenceEqual(new[] { 0d, 30d, 90d })
            && chapters.Select(x => x.Name).SequenceEqual(new[] { "开始", "章节 3", "片尾" }),
            "server chapters sort by converted ticks and preserve titles with a missing-name fallback");
        Assert(chapters[0].EndSeconds == 30 && chapters[1].EndSeconds == 90 && chapters[2].EndSeconds is null
            && PlaybackChapters.CurrentIndex(chapters, 29.99) == 0 && PlaybackChapters.CurrentIndex(chapters, 30) == 1
            && PlaybackChapters.CurrentIndex(chapters, -1) == -1,
            "chapter boundaries and current-chapter transitions follow actual media positions");
        fixture.FailChapters = true;
        try { await PlaybackChapters.LoadAsync(core, report, default); Assert(false, "chapter HTTP failures must not appear as an empty list"); }
        catch (ServerConnectionException) { Assert(true, "chapter HTTP failures remain retryable errors rather than empty chapter lists"); }
        fixture.FailChapters = false;

        var service = new ServerSubtitleService(core, report, directory);
        var subtitles = await service.ListAsync(default);
        Assert(subtitles.Length == 2 && subtitles[0].DisplayName == "简体中文" && subtitles[0].Language == "zho"
            && subtitles.Select(x => x.Extension).SequenceEqual(new[] { "srt", "vtt" })
            && subtitles.All(x => x.DownloadUri.AbsolutePath.Contains("/source-b/", StringComparison.Ordinal)),
            "server subtitle discovery honors the chosen media source and filters embedded and image subtitles");
        var subtitle = subtitles[0];
        Assert(subtitle.DownloadUri.AbsolutePath == "/proxy/api/Videos/item/source-b/Subtitles/7/Stream.srt"
            && subtitle.DownloadUri.Query.Length == 0, "subtitle routes preserve reverse-proxy prefixes without URL credentials");
        var file = await service.DownloadAsync(subtitle, default);
        Assert(await File.ReadAllTextAsync(file) == ServerPlayerMenuFixture.Subtitle
            && Path.GetFileNameWithoutExtension(file).Length == 64 && Path.GetDirectoryName(file) == Path.Combine(directory, "SubtitleCache"),
            "downloaded subtitle content reaches a managed cache using a hash filename");
        var alternateReport = report with { Profile = JsonSerializer.SerializeToElement(profile with { UserId = "another-account" }, MediaServer.JsonOptions) };
        var alternate = await new ServerSubtitleService(core, alternateReport, directory).ListAsync(default);
        Assert(alternate[0].Key != subtitle.Key, "subtitle cache identities separate accounts on the same server");

        fixture.Mode = "same-origin";
        Assert(await File.ReadAllTextAsync(await service.DownloadAsync(subtitle, default)) == ServerPlayerMenuFixture.Subtitle,
            "same-origin subtitle redirects preserve authenticated downloads");
        fixture.ForeignUrl = foreign.Url + "leak?api_key=" + ServerPlayerMenuFixture.Token;
        fixture.Mode = "cross-origin";
        await ExpectSubtitleFailure(() => service.DownloadAsync(subtitle, default), "跨站", "cross-origin subtitle redirects are rejected before forwarding credentials");
        Assert(foreign.Requests.IsEmpty, "redirected foreign origins receive no request or authentication header");
        fixture.Mode = "declared-large";
        await ExpectSubtitleFailure(() => service.DownloadAsync(subtitle, default), "32 MiB", "subtitle Content-Length above 32 MiB is rejected before body buffering");
        fixture.Mode = "stream-large";
        await ExpectSubtitleFailure(() => service.DownloadAsync(subtitle, default), "32 MiB", "subtitle streams without Content-Length remain capped at 32 MiB");
        Assert(!Directory.EnumerateFiles(Path.Combine(directory, "SubtitleCache"), "*.tmp").Any(), "failed subtitle downloads remove partial cache files");
        fixture.Mode = "slow";
        using (var cancel = new CancellationTokenSource())
        {
            var pending = service.DownloadAsync(subtitle, cancel.Token);
            await fixture.SlowEntered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var watch = Stopwatch.StartNew();
            cancel.Cancel();
            try { await pending; Assert(false, "cancelled subtitle downloads must not publish files"); }
            catch (OperationCanceledException) { Assert(watch.Elapsed < TimeSpan.FromSeconds(3), "in-flight subtitle cancellation promptly stops a stalled body"); }
        }
        Assert(!Directory.EnumerateFiles(Path.Combine(directory, "SubtitleCache"), "*.tmp").Any()
            && await File.ReadAllTextAsync(file) == ServerPlayerMenuFixture.Subtitle,
            "cancelled subtitle downloads preserve completed cache files and remove partial writes");
        fixture.Mode = "http-failure";
        await ExpectSubtitleFailure(() => service.DownloadAsync(subtitle, default), "HTTP 401", "subtitle HTTP errors expose status without authenticated URLs or response bodies");
        var requests = fixture.Requests.ToArray();
        Assert(requests.All(x => !x.Target.Contains(ServerPlayerMenuFixture.Token, StringComparison.Ordinal))
            && requests.All(x => x.Headers.GetValueOrDefault("Authorization", "").Contains("Token=\"" + ServerPlayerMenuFixture.Token + "\"", StringComparison.Ordinal))
            && requests.All(x => x.Headers.GetValueOrDefault("X-Emby-Authorization", "").Contains(ServerPlayerMenuFixture.Token, StringComparison.Ordinal)),
            "Core metadata and subtitle body requests use authorization headers through the reverse proxy");
        Evidence.Add(new { stage = "server-player-menus", chapters = chapters.Length, subtitles = subtitles.Length,
            requests = requests.Select(x => x.Target).ToArray(), cancellation = true, maxBytes = ServerSubtitleService.MaximumBytes });
    }

    private static async Task ExpectSubtitleFailure(Func<Task<string>> action, string fragment, string description)
    {
        try { await action(); Assert(false, description); }
        catch (ServerSubtitleException ex)
        {
            Assert(ex.Message.Contains(fragment, StringComparison.Ordinal) && !ex.ToString().Contains(ServerPlayerMenuFixture.Token, StringComparison.Ordinal)
                && !ex.Message.Contains("http://", StringComparison.OrdinalIgnoreCase), description);
        }
    }

    private sealed class ServerPlayerMenuFixture : IDisposable
    {
        internal const string Token = "isolated-menu-fixture-token";
        internal const string Subtitle = "1\n00:00:01,000 --> 00:00:04,000\n离线外挂字幕验证\n";
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource _stop = new();
        public ConcurrentQueue<(string Target, Dictionary<string, string> Headers)> Requests { get; } = new();
        public TaskCompletionSource SlowEntered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public string Url { get; }
        public string Mode = "normal", ForeignUrl = "";
        public bool FailChapters;
        public ServerPlayerMenuFixture()
        {
            _listener.Start();
            Url = $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}/";
            _ = Listen();
        }
        private async Task Listen()
        {
            try
            {
                while (!_stop.IsCancellationRequested)
                {
                    var client = await _listener.AcceptTcpClientAsync(_stop.Token);
                    _ = Respond(client);
                }
            }
            catch (Exception ex) when (ex is OperationCanceledException or SocketException or ObjectDisposedException) { }
        }
        private async Task Respond(TcpClient client)
        {
            using (client)
            {
                try
                {
                    using var stream = client.GetStream();
                    using var reader = new StreamReader(stream, Encoding.UTF8, false, leaveOpen: true);
                    var request = (await reader.ReadLineAsync(_stop.Token))!.Split(' ');
                    var target = request[1];
                    var path = target.Split('?')[0];
                    var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    while (await reader.ReadLineAsync(_stop.Token) is { Length: > 0 } line)
                    { var pair = line.Split(':', 2); headers[pair[0]] = pair[1].Trim(); }
                    Requests.Enqueue((target, headers));
                    if (path.EndsWith("/Items/item", StringComparison.Ordinal))
                    {
                        await Send(stream, FailChapters ? 403 : 200, JsonSerializer.SerializeToUtf8Bytes(new
                        {
                            Chapters = new object[] { new { Name = "片尾", StartPositionTicks = 900000000L }, new { Name = " 开始 ", StartPositionTicks = 0L }, new { StartPositionTicks = 300000000L } }
                        }));
                    }
                    else if (path == "/proxy/api/Items")
                    {
                        object Track(int index, string codec, bool external, string title, string language) => new { Type = "Subtitle", Index = index, Codec = codec, IsExternal = external, Title = title, Language = language };
                        await Send(stream, 200, JsonSerializer.SerializeToUtf8Bytes(new
                        {
                            Items = new[] { new { Id = "item", MediaSources = new[] {
                                new { Id = "source-a", MediaStreams = new[] { Track(3, "srt", true, "Wrong version", "eng") } },
                                new { Id = "source-b", MediaStreams = new[] { Track(7, "subrip", true, "简体中文", "zho"), Track(9, "webvtt", true, "English", "eng"), Track(10, "pgssub", true, "Image", "jpn"), Track(11, "ass", false, "Embedded", "jpn") } }
                            } } }
                        }));
                    }
                    else if (path == "/proxy/api/redirected.srt") await Send(stream, 200, Encoding.UTF8.GetBytes(Subtitle));
                    else if (Mode is "same-origin" or "cross-origin")
                    {
                        var location = Mode == "same-origin" ? "/proxy/api/redirected.srt" : ForeignUrl;
                        await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 302 Found\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"), _stop.Token);
                    }
                    else if (Mode == "declared-large")
                        await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 200 OK\r\nContent-Length: {ServerSubtitleService.MaximumBytes + 1}\r\nConnection: close\r\n\r\n"), _stop.Token);
                    else if (Mode == "stream-large")
                    {
                        await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n"), _stop.Token);
                        var block = new byte[65536];
                        for (var index = 0; index <= ServerSubtitleService.MaximumBytes / block.Length; index++) await stream.WriteAsync(block, _stop.Token);
                    }
                    else if (Mode == "slow")
                    {
                        await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n"), _stop.Token);
                        SlowEntered.TrySetResult();
                        await Task.Delay(Timeout.Infinite, _stop.Token);
                    }
                    else if (Mode == "http-failure") await Send(stream, 401, Encoding.UTF8.GetBytes(Url + "secret?api_key=" + Token));
                    else await Send(stream, 200, Encoding.UTF8.GetBytes(Subtitle));
                }
                catch (Exception ex) when (ex is IOException or OperationCanceledException or SocketException or ObjectDisposedException) { }
            }
        }
        private async Task Send(Stream stream, int status, byte[] payload)
        {
            await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {payload.Length}\r\nConnection: close\r\n\r\n"), _stop.Token);
            await stream.WriteAsync(payload, _stop.Token);
        }
        public void Dispose() { _stop.Cancel(); _listener.Stop(); }
    }
}

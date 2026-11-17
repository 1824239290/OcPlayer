using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using OcPlayer.Windows.Services;

namespace OcPlayer.Tests;

internal sealed class DanmakuFixture : IDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _stop = new();
    public string Url { get; }
    public bool Reject { get; set; }
    public bool NoMatches { get; set; }
    public bool RepeatedComments { get; set; }
    public bool HeadersCorrect = true;
    public int Requests;
    public string LastHash = "", LastSearch = "";
    public TaskCompletionSource? DelaySearch { get; set; }
    public TaskCompletionSource? DelayMatch { get; set; }
    public TaskCompletionSource MatchEntered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource SearchEntered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public DanmakuFixture() { _listener.Start(); Url = $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}/"; _ = Listen(); }
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
                var request = (await reader.ReadLineAsync())!.Split(' '); var path = request[1].Split('?')[0];
                var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                while (await reader.ReadLineAsync() is { Length: > 0 } line) { var pair = line.Split(':', 2); headers[pair[0]] = pair[1].Trim(); }
                var length = int.Parse(headers.GetValueOrDefault("Content-Length", "0"));
                var bodyText = new StringBuilder(); var character = new char[1];
                while (Encoding.UTF8.GetByteCount(bodyText.ToString()) < length) { if (await reader.ReadAsync(character) == 0) throw new IOException(); bodyText.Append(character[0]); }
                Interlocked.Increment(ref Requests);
                HeadersCorrect &= headers.GetValueOrDefault("X-API-Key") == "fixture-danmaku-key" && headers.GetValueOrDefault("User-Agent", "").StartsWith("OcPlay/");
                object body;
                if (path == "/v1/match")
                {
                    using var match = JsonDocument.Parse(bodyText.ToString()); LastHash = Json.Text(match.RootElement, "fileHash");
                    if (DelayMatch is not null) { MatchEntered.TrySetResult(); await DelayMatch.Task.WaitAsync(_stop.Token); }
                    body = new { success = true, isMatched = !NoMatches, matches = NoMatches ? Array.Empty<object>() : new object[] { new { episodeId = 1010001, animeId = 101, animeTitle = "葬送的芙莉莲", episodeTitle = "第1集", type = "tvseries", shift = 2 } } };
                }
                else if (path == "/v1/search/episodes")
                {
                    LastSearch = request[1];
                    if (DelaySearch is not null) { SearchEntered.TrySetResult(); await DelaySearch.Task.WaitAsync(_stop.Token); }
                    body = new { success = true, animes = NoMatches ? Array.Empty<object>() : new object[] { new { animeId = 101, animeTitle = "葬送的芙莉莲", type = "tvseries", episodes = new[] { new { episodeId = 1010001, episodeTitle = "第1集" }, new { episodeId = 1010002, episodeTitle = "第2集" } } } } };
                }
                else if (RepeatedComments) body = new { count = 90, comments = Enumerable.Range(1, 90).Select(i => new { p = $"{i * 3},1,16777215", m = $"弹幕接入验证 · 第 {i} 条" }).ToArray() };
                else body = new { count = path.EndsWith("1010003") ? 0 : 5, comments = path.EndsWith("1010003") ? Array.Empty<object>() : new object[]
                { new { p = "1,1,16777215", m = "滚动弹幕" }, new { p = "2,4,16711680", m = "底部弹幕" }, new { p = "3,5,65280", m = "顶部弹幕" }, new { p = "NaN,1,0", m = "invalid time" }, new { p = "4,8,0", m = "unsupported mode" } } };
                var payload = JsonSerializer.SerializeToUtf8Bytes(body);
                var response = Encoding.ASCII.GetBytes($"HTTP/1.1 {(Reject ? "401 Unauthorized" : "200 OK")}\r\nContent-Type: application/json\r\nContent-Length: {payload.Length}\r\nConnection: close\r\n\r\n");
                await stream.WriteAsync(response, _stop.Token); await stream.WriteAsync(payload, _stop.Token);
            }
            catch (Exception ex) when (ex is IOException or OperationCanceledException or SocketException) { }
        }
    }
    public void Dispose() { _stop.Cancel(); _listener.Stop(); _stop.Dispose(); }
}

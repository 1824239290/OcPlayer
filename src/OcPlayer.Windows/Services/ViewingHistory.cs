using System.Text.Json;
using OcPlayer.Windows.Preview;

namespace OcPlayer.Windows.Services;

internal sealed record ViewingRecord(string Id, string Source, DemoMedia Media, DateTimeOffset WatchedAt, double? ActualSeconds, bool Completed)
{
    public double Seconds => ActualSeconds ?? Math.Max(0, Media.DurationSeconds);
}
internal sealed record ViewingArchive(string Source, DateTimeOffset RecordedFrom, ViewingRecord[] Records, int Undated = 0, DateTimeOffset? SyncedAt = null);

/// Same archive semantics as macOS ServerViewingHistory/AppPlaybackHistory.
/// Playback progress remains owned by Core; these records measure wall time, not position.
internal sealed class ViewingHistory(string directory)
{
    public event Action? Changed;
    private readonly string _directory = Path.Combine(directory, "ViewingHistory");
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, long> _generations = new();
    public static string Source(MediaServer? server) => server is null ? "local" : $"{server.Profile.Kind}:{server.Profile.ResolvedServerId ?? server.Profile.Id}:{server.Profile.UserId}";
    private string PathFor(string source, bool actual) => Path.Combine(_directory,
        (actual ? "app-" : "server-") + Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(source))) + ".json");
    public ViewingArchive Read(string source, bool actual = false)
    {
        var path = PathFor(source, actual);
        if (!File.Exists(path)) return new(source, new DateTimeOffset(DateTime.Today.AddDays(-29)), []);
        var archive = JsonSerializer.Deserialize<ViewingArchive>(File.ReadAllText(path));
        if (archive is null || archive.Source != source || archive.Records is null || archive.Records.Any(x => x.Source != source || !double.IsFinite(x.Seconds) || x.Seconds < 0))
            throw new InvalidOperationException("观看记录无法读取，原文件已保留。");
        return archive;
    }
    private void Write(ViewingArchive archive, bool actual)
    {
        Directory.CreateDirectory(_directory);
        var path = PathFor(archive.Source, actual); var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(archive)); File.Move(temp, path, true);
        Changed?.Invoke();
    }
    internal static DemoMedia Sanitize(DemoMedia media) => media with
    {
        SourceUri = null, Artwork = "", StillArtwork = "", BackdropArtwork = "", DetailArtwork = "", LogoArtwork = "", Episodes = null,
        Title = Uri.TryCreate(media.Title, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" ? "直连播放" : media.Title,
        OriginalTitle = ""
    };
    public async Task<ViewingArchive> Synchronize(MediaServer server, CancellationToken token)
    {
        var source = Source(server); var archive = Read(source); var now = DateTimeOffset.Now;
        var generation = _generations.AddOrUpdate(source, 1, (_, old) => old + 1);
        var records = new Dictionary<string, ViewingRecord>(); var undated = 0; var offset = 0;
        var parents = new Dictionary<string, DemoMedia?>();
        for (var pageNumber = 0; pageNumber < 100; pageNumber++)
        {
            var page = await server.Request("browse.played", new { startIndex = offset, limit = 200 }, token);
            var rows = Json.Items(page); var crossed = false;
            foreach (var row in rows)
            {
                var item = Json.Get(row, "item");
                if (Json.Text(item, "kind") is not ("movie" or "episode") || Json.Get(Json.Get(item, "playState"), "played").ValueKind != JsonValueKind.True) continue;
                if (!DateTimeOffset.TryParse(Json.Text(row, "lastPlayedAt"), out var date)) { undated++; continue; }
                if (date < archive.RecordedFrom) { crossed = true; continue; }
                if (date > now.AddMinutes(5)) continue;
                var projected = server.Project(item);
                if (projected.Kind == "episode" && string.IsNullOrEmpty(projected.Category) && projected.SeriesId is { Length: > 0 } parentId)
                {
                    if (!parents.ContainsKey(parentId) && parents.Count < 64)
                    {
                        parents[parentId] = null;
                        try { parents[parentId] = server.Project(await server.Request("browse.detail", new { itemId = parentId }, token)); }
                        catch (ServerConnectionException) { /* Optional metadata must not discard history. */ }
                    }
                    if (parents.GetValueOrDefault(parentId) is { } parent) projected = projected with { Category = parent.Category };
                }
                var media = Sanitize(projected);
                if (media.Id.Length == 0 || records.TryGetValue(media.Id, out var prior) && prior.WatchedAt >= date) continue;
                records[media.Id] = new(media.Id, source, media, date, null, true);
            }
            offset += rows.Length;
            var total = Json.Number(page, "totalRecordCount", -1);
            if (rows.Length == 0 || crossed || total >= 0 && offset >= total || total < 0 && rows.Length < 200)
            {
                token.ThrowIfCancellationRequested();
                if (_generations[source] != generation) throw new OperationCanceledException("A newer viewing-history scan superseded this response.");
                archive = archive with { Records = records.Values.OrderByDescending(x => x.WatchedAt).ToArray(), Undated = undated, SyncedAt = now };
                Write(archive, false); return archive;
            }
        }
        throw new InvalidOperationException("观看记录过多，本次未完成同步；已保留上次记录。");
    }
    public void SaveActual(ViewingRecord record)
    {
        if (record.ActualSeconds is not > 0 || !double.IsFinite(record.ActualSeconds.Value)) return;
        var archive = Read(record.Source, true); var records = archive.Records.ToList();
        var index = records.FindIndex(x => x.Id == record.Id);
        if (index >= 0) { if (records[index].ActualSeconds > record.ActualSeconds) return; records[index] = record; }
        else records.Add(record);
        Write(archive with { Records = records.OrderByDescending(x => x.WatchedAt).ToArray() }, true);
    }
    public ViewingRecord[] Entries(string source) => Merge(Read(source).Records,
        Read("local", true).Records.Concat(source == "local" ? [] : Read(source, true).Records), DateTimeOffset.Now);
    internal static ViewingRecord[] Merge(IEnumerable<ViewingRecord> server, IEnumerable<ViewingRecord> actual, DateTimeOffset now)
    {
        static string Key(ViewingRecord row) => $"{row.Source}/{row.Media.Id}/{row.WatchedAt.LocalDateTime:yyyy-MM-dd}";
        var serverRows = server.ToArray(); var completed = serverRows.ToDictionary(Key);
        var grouped = actual.Where(x => x.ActualSeconds is > 0 && double.IsFinite(x.ActualSeconds.Value) && x.WatchedAt <= now.AddMinutes(5)).GroupBy(Key);
        foreach (var group in grouped)
        {
            var latest = group.MaxBy(x => x.WatchedAt)!;
            var metadata = serverRows.FirstOrDefault(x => x.Source == latest.Source && x.Media.Id == latest.Media.Id)?.Media;
            completed[group.Key] = latest with { ActualSeconds = group.Sum(x => x.ActualSeconds), Completed = completed.ContainsKey(group.Key),
                Media = string.IsNullOrWhiteSpace(latest.Media.Category) && metadata is not null ? latest.Media with { Category = metadata.Category } : latest.Media };
        }
        return completed.Values.OrderByDescending(x => x.WatchedAt).ToArray();
    }
}

internal sealed class ViewingRecorder(ViewingHistory history, string source, DemoMedia media)
{
    private readonly string _session = Guid.NewGuid().ToString("N");
    private readonly Dictionary<DateTime, ViewingRecord> _days = [];
    private double? _time, _position;
    private bool _playing;
    private double _savedAt;
    private readonly Dictionary<DateTime, double> _saved = [];
    public void ResetClock() { _time = _position = null; _playing = false; }
    public void Sample(double time, double position, bool playing, double rate, DateTimeOffset now)
    {
        var elapsed = _time.HasValue ? time - _time.Value : 0;
        var advance = _position.HasValue ? position - _position.Value : 0;
        // Decoder position events are slower than render ticks. Keep the baseline
        // until a position update arrives, otherwise 60 Hz sampling loses wall time.
        if (playing && _playing && advance == 0 && elapsed is > 0 and <= 2) return;
        // Reject stalls, seeks, sleep/resume and speed discontinuities. Count wall time at any rate.
        if (playing && _playing && elapsed is > 0 and <= 2 && advance > 0 && advance <= elapsed * Math.Max(rate, .1) + .5)
        {
            var start = now.AddSeconds(-Math.Min(elapsed, advance / Math.Max(rate, .1)));
            while (start < now)
            {
                var day = start.LocalDateTime.Date;
                var midnight = new DateTimeOffset(day.AddDays(1)); var end = midnight < now ? midnight : now;
                var record = _days.GetValueOrDefault(day) ?? new ViewingRecord(_session + day.ToString("yyyyMMdd"), source,
                    ViewingHistory.Sanitize(media), start, 0, false);
                _days[day] = record with { ActualSeconds = record.ActualSeconds + (end - start).TotalSeconds,
                    WatchedAt = end == midnight ? end.AddTicks(-1) : end };
                start = end;
            }
        }
        _time = time; _position = position; _playing = playing;
        if (!playing || time - _savedAt >= 15) { Flush(); _savedAt = time; }
    }
    public void Flush()
    {
        foreach (var (day, record) in _days)
        {
            if (_saved.GetValueOrDefault(day) == record.ActualSeconds) continue;
            history.SaveActual(record); _saved[day] = record.ActualSeconds ?? 0;
        }
    }
}

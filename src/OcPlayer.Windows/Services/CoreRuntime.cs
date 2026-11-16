using System.Text.Json;
using OcPlayer.CoreAdapter;
using OcPlayer.Windows.Preview;

namespace OcPlayer.Windows.Services;

internal sealed class CoreRuntime : IDisposable
{
    public OcpCoreClient Client { get; }
    public string Version { get; }
    public string DataDirectory { get; }
    public List<DemoMedia> LocalMedia { get; } = [];
    public MediaServer? Server { get; private set; }
    public ViewingIntegrations Integrations { get; }
    public ViewingHistory ViewingHistory { get; }
    public DanmakuService Danmaku { get; }
    public TmdbService Tmdb { get; }
    public ServerProfiles Servers { get; }
    public event Action? SessionExpired;
    private readonly string _recentPath;
    private readonly string _credentialResource;
    private readonly List<Task> _reports = [];
    public CoreRuntime(string credentialResource = "OcPlayer.Windows")
    {
        _credentialResource = credentialResource;
        DataDirectory = Environment.GetEnvironmentVariable("OCP_DATA_DIRECTORY") ??
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OcPlayer", "Windows");
        Directory.CreateDirectory(DataDirectory);
        ViewingHistory = new ViewingHistory(DataDirectory);
        _recentPath = Path.Combine(DataDirectory, "recent-media.json");
        Client = new OcpCoreClient(JsonSerializer.Serialize(new { dataDirectory = DataDirectory, locale = "zh-CN" }));
        Integrations = new ViewingIntegrations(Client, credentialResource);
        Tmdb = new TmdbService(Client, DataDirectory, credentialResource);
        Servers = new ServerProfiles(DataDirectory, credentialResource);
        try
        {
            PlaybackSession.Require(Client.Ping());
            Danmaku = new DanmakuService(Client, DataDirectory, new DanmakuSettings(credentialResource), bangumiBase: () => Integrations.Domains.Api);
            using var snapshot = Client.Snapshot();
            Version = snapshot.RootElement.GetProperty("coreVersion").GetString()!;
            if (File.Exists(_recentPath))
            {
                try { LocalMedia.AddRange(JsonSerializer.Deserialize<DemoMedia[]>(File.ReadAllText(_recentPath)) ?? []); }
                catch (JsonException) { /* Preserve the unreadable file while keeping Core available. */ }
            }
            RefreshProgress();
            try
            {
                if (Servers.Startup() is { } profile) AttachServer(new MediaServer(Client, profile));
            }
            catch (System.Runtime.InteropServices.COMException) { }
            catch (JsonException) { /* Ignore an obsolete saved server profile; local playback remains available. */ }
        }
        catch { Client.Dispose(); throw; }
    }

    public void Remember(DemoMedia media)
    {
        LocalMedia.RemoveAll(x => x.Id == media.Id);
        LocalMedia.Insert(0, media);
        if (LocalMedia.Count > 100) LocalMedia.RemoveRange(100, LocalMedia.Count - 100);
        // URL secrets are kept only in the current session; the recent file
        // stores local files, never signed URLs or authentication headers.
        var saved = LocalMedia.Where(x => x.SourceUri is not null && File.Exists(x.SourceUri)).ToArray();
        var temporary = _recentPath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(saved));
        File.Move(temporary, _recentPath, true);
    }

    public void RefreshProgress()
    {
        for (var i = 0; i < LocalMedia.Count; i++)
        {
            var media = LocalMedia[i];
            var data = PlaybackSession.Require(Client.Call("progress.get", new { tenantId = "local", itemId = media.Id }));
            if (data.GetProperty("progress") is not { ValueKind: JsonValueKind.Object } progress) continue;
            var duration = progress.GetProperty("durationSeconds");
            var seconds = duration.ValueKind == JsonValueKind.Number ? duration.GetDouble() : 0;
            var position = progress.GetProperty("positionSeconds").GetDouble();
            LocalMedia[i] = media with { DurationSeconds = seconds, Progress = progress.GetProperty("completed").GetBoolean() ? 100 : seconds > 0 ? position / seconds * 100 : 0,
                RemainingMinutes = seconds > 0 ? (int)Math.Ceiling(Math.Max(0, seconds - position) / 60) : null };
        }
    }

    public void DrainEvents()
    {
        while (Client.TryPollEvent(out var entry)) if (entry is not null)
        { Integrations.ReceiveCoreEvent(entry.Kind, entry.Data); AppDiagnostics.Write("debug", "Core event: " + entry.Kind); }
    }

    public void SetServer(MediaServer server)
    {
        Servers.Save(server.Profile, true);
        AttachServer(server);
    }

    private void AttachServer(MediaServer server)
    {
        if (Server is { } previous) { previous.AuthenticationExpired -= ExpireSession; previous.ProfileChanged -= SaveProfile; }
        Server = server; server.AuthenticationExpired += ExpireSession; server.ProfileChanged += SaveProfile;
        if (server.HomeUpdatedAt is null) server.RestoreHome();
    }
    private void SaveProfile(ServerProfile profile) => Servers.Save(profile);
    private void ExpireSession(MediaServer server)
    {
        if (!ReferenceEquals(server, Server)) return;
        Servers.Invalidate(server.Profile.Id); DisconnectServer(); SessionExpired?.Invoke();
    }

    public void DisconnectServer()
    {
        if (Server is { } server) { server.AuthenticationExpired -= ExpireSession; server.ProfileChanged -= SaveProfile; }
        Servers.Deactivate();
        Server = null;
    }

    public void TrackReports(Task task) { _reports.RemoveAll(x => x.IsCompleted); _reports.Add(task); }
    public async Task FinishReports()
    {
        if (_reports.Count == 0) return;
        try { await Task.WhenAll(_reports).WaitAsync(TimeSpan.FromSeconds(5)); }
        catch (TimeoutException) { /* Core.Dispose cancels unfinished network work after the exit budget. */ }
    }

    public void Dispose() => Client.Dispose();
}

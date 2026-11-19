using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OcPlayer.CoreAdapter;

public sealed record FileLibraryCapabilities(int SchemaVersion, string[] SourceKinds, string[] LibraryTypes,
    bool Aggregation, bool BackgroundScan, bool TmdbAccessValidation, bool TmdbScraping, bool RemoteProviders);
public sealed record FileLibrarySource(string SourceId, string Kind, string DisplayName, string? AccessRef, string RootPath, double CreatedAt);
public sealed record FileLibraryDefinition(string LibraryId, string SourceId, string Name, string RootPath, string Type, long Revision, double CreatedAt);
public sealed record FileLibraryItem(string SourceId, string LibraryId, string ItemId, string Kind, string Title,
    int? Year, string? ParentId, string? SeriesId, int? SeasonNumber, int? EpisodeNumber, double FirstSeenAt,
    JsonElement? Metadata, string MatchStatus, bool Playable);
public sealed record FileLibraryAsset(string SourceId, string AssetId, string RelativePath, long Size, bool Available);
public sealed record FileLibraryJob(string JobId, string SourceId, string LibraryId, long Generation, string Status,
    long FilesFound, long DirectoriesDone, long ErrorCount, string? LastError);
public sealed record FileLibraryProgress(string SourceId, string ItemId, double PositionSeconds, double? DurationSeconds,
    bool Played, bool Completed, double RecordedAt);
public sealed record FileLibraryValidation(string Status, string VerificationId, int ExpiresInSeconds);
public sealed record FileLibraryAccess(string AccessId, string RootPath);
public sealed record FileLibraryCreation(FileLibraryDefinition Library, FileLibraryJob Job);
public sealed record FileLibraryPage(FileLibraryItem[] Items, long TotalCount, long StartIndex);
public sealed record FileLibraryDetail(FileLibraryItem Item, FileLibraryAsset[] Assets, FileLibraryProgress? Progress);
public sealed record FileLibraryPlayback(string SourceId, string ItemId, string AssetId, string Uri,
    Dictionary<string, string> Headers, FileLibraryProgress? Progress);
public sealed record FileLibraryQuery(string SourceId, string? LibraryId = null, string? Type = null,
    string? ParentId = null, string Search = "", long StartIndex = 0, int Limit = 50);
public sealed record FileLibraryCreate(string DraftId, string VerificationId, string CredentialRevision, string ApiBase,
    string AccessId, string SourceName, string RootPath, string Name, string Type, string? SourceId = null)
{
    public string Kind => "localFolder";
}

/// Shared file-library commands. The host owns folder authorization and source
/// selection; there is no server impersonation or implicit multi-source query.
public sealed class OcpFileLibrary(OcpCoreClient client)
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public Task<FileLibraryCapabilities> CapabilitiesAsync(CancellationToken cancellation = default)
        => Invoke<FileLibraryCapabilities>("library.capabilities", new { }, cancellation);
    public async Task OpenAsync(string directory, CancellationToken cancellation = default)
        => _ = await Invoke<JsonElement>("library.open", new { directory }, cancellation).ConfigureAwait(false);
    public Task<FileLibraryValidation> ValidateAsync(string apiKey, string apiBase, string credentialRevision, string draftId,
        CancellationToken cancellation = default)
        => Invoke<FileLibraryValidation>("tmdb.access.validate", new { apiKey, apiBase, credentialRevision, draftId }, cancellation);
    public async Task InvalidateCredentialsAsync(CancellationToken cancellation = default)
        => _ = await Invoke<JsonElement>("tmdb.access.invalidate", new { }, cancellation).ConfigureAwait(false);
    public Task<FileLibraryAccess> PrepareAccessAsync(string rootPath, string? accessRef = null, CancellationToken cancellation = default)
        => Invoke<FileLibraryAccess>("library.access.prepare", new { rootPath, accessRef }, cancellation);
    public Task<FileLibraryCreation> CreateAsync(FileLibraryCreate input, CancellationToken cancellation = default)
        => Invoke<FileLibraryCreation>("library.create", input, cancellation);
    public async Task<FileLibrarySource[]> SourcesAsync(CancellationToken cancellation = default)
        => (await Invoke<Sources>("library.sources.list", new { }, cancellation).ConfigureAwait(false)).Values;
    public async Task<FileLibraryDefinition[]> LibrariesAsync(string sourceId, CancellationToken cancellation = default)
        => (await Invoke<Libraries>("library.libraries.list", new { sourceId }, cancellation).ConfigureAwait(false)).Values;
    public Task<FileLibraryPage> PageAsync(FileLibraryQuery query, CancellationToken cancellation = default)
        => Invoke<FileLibraryPage>("library.query.page", query, cancellation);
    public Task<FileLibraryDetail> DetailAsync(string sourceId, string itemId, CancellationToken cancellation = default)
        => Invoke<FileLibraryDetail>("library.query.detail", new { sourceId, itemId }, cancellation);
    public async Task<FileLibraryItem[]> ResumeAsync(string sourceId, int limit = 20, CancellationToken cancellation = default)
        => (await Invoke<Items>("library.query.resume", new { sourceId, limit }, cancellation).ConfigureAwait(false)).Values;
    public async Task<FileLibraryJob> ScanAsync(string sourceId, string libraryId, CancellationToken cancellation = default)
        => (await Invoke<Job>("library.scan.start", new { sourceId, libraryId }, cancellation).ConfigureAwait(false)).Value;
    public enum ScanAction { Pause, Resume, Cancel }
    public async Task<FileLibraryJob> ControlScanAsync(string sourceId, string jobId, ScanAction action, CancellationToken cancellation = default)
        => (await Invoke<Job>($"library.scan.{action.ToString().ToLowerInvariant()}", new { sourceId, jobId }, cancellation).ConfigureAwait(false)).Value;
    public async Task<FileLibraryJob[]> JobsAsync(string sourceId, CancellationToken cancellation = default)
        => (await Invoke<Jobs>("library.jobs.snapshot", new { sourceId }, cancellation).ConfigureAwait(false)).Values;
    public Task<FileLibraryPlayback> PreparePlaybackAsync(string sourceId, string itemId, string assetId, CancellationToken cancellation = default)
        => Invoke<FileLibraryPlayback>("library.playback.prepare", new { sourceId, itemId, assetId }, cancellation);
    public async Task<bool> RecordProgressAsync(FileLibraryProgress progress, CancellationToken cancellation = default)
        => (await Invoke<ProgressResult>("library.progress.record", progress, cancellation).ConfigureAwait(false)).Accepted;

    private async Task<T> Invoke<T>(string method, object input, CancellationToken cancellation)
    {
        var response = await client.CallJSONAsync(method, JsonSerializer.Serialize(input, Json), cancellation).ConfigureAwait(false);
        if (response.Code == 1003) throw new OperationCanceledException(cancellation);
        if (!response.Ok) throw new InvalidOperationException(response.Message);
        return response.DecodeData<T>(Json) ?? throw new JsonException("Core returned an empty file-library payload");
    }
    private sealed record Sources([property: System.Text.Json.Serialization.JsonPropertyName("sources")] FileLibrarySource[] Values);
    private sealed record Items([property: System.Text.Json.Serialization.JsonPropertyName("items")] FileLibraryItem[] Values);
    private sealed record Libraries([property: System.Text.Json.Serialization.JsonPropertyName("libraries")] FileLibraryDefinition[] Values);
    private sealed record Job([property: System.Text.Json.Serialization.JsonPropertyName("job")] FileLibraryJob Value);
    private sealed record Jobs([property: System.Text.Json.Serialization.JsonPropertyName("jobs")] FileLibraryJob[] Values);
    private sealed record ProgressResult(bool Accepted, FileLibraryProgress? Progress);
}

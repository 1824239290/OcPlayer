using System;
using System.Collections.Generic;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace OcPlayer.CoreAdapter;

public sealed record FileLibraryCapabilities(int SchemaVersion, string[] SourceKinds, string[] LibraryTypes,
    bool Aggregation, bool BackgroundScan, bool TmdbAccessValidation, bool TmdbScraping, bool RemoteProviders);
public sealed record FileLibrarySource(string SourceId, string Kind, string DisplayName, string? AccessRef, string RootPath, double CreatedAt);
public sealed record FileLibraryRoot(string RootId, string RootPath, string? AccessRef = null);
public sealed record FileLibraryDefinition(string LibraryId, string SourceId, string Name, string RootPath, string Type, long Revision, double CreatedAt, FileLibraryRoot[]? Roots = null);
public sealed record FileLibraryItem(string SourceId, string LibraryId, string ItemId, string Kind, string Title,
    int? Year, string? ParentId, string? SeriesId, int? SeasonNumber, int? EpisodeNumber, double FirstSeenAt,
    JsonElement? Metadata, string MatchStatus, bool Playable,
    string? SeriesTitle = null, string? SeriesBackdropPath = null, string? SeriesPosterPath = null,
    int? ChildCount = null, FileLibraryProgress? Progress = null);
public sealed record FileLibraryAsset(string SourceId, string AssetId, string RelativePath, long Size, bool Available);
public sealed record FileLibraryJob(string JobId, string SourceId, string LibraryId, long Generation, string Status,
    long FilesFound, long DirectoriesDone, long ErrorCount, string? LastError);
public sealed record FileLibraryScrapeRun(string RunId, string SourceId, string LibraryId, string Status, string Language,
    bool Refresh, long Total, long Completed, long Unmatched, long Failed, string? LastError, double? NextRetryAt);
public sealed record FileLibraryMatchCandidate(long Id, string MediaType, string? Title, string? OriginalTitle, int? Year, string? Overview, string? PosterPath);
public sealed record FileLibraryMatchCandidates(string InputVersion, FileLibraryMatchCandidate[] Candidates);
public sealed record FileLibraryProgress(string SourceId, string ItemId, double PositionSeconds, double? DurationSeconds,
    bool Played, bool Completed, double RecordedAt);
public sealed record FileLibraryValidation(string Status, string VerificationId, int ExpiresInSeconds);
public sealed record FileLibraryAccess(string AccessId, string RootPath);
public sealed record FileLibraryCreation(FileLibraryDefinition Library, FileLibraryJob Job);
public sealed record FileLibraryRootAddition(FileLibraryDefinition Library, FileLibraryRoot Root, FileLibraryJob Job);
public sealed record FileLibraryPage(FileLibraryItem[] Items, long TotalCount, long StartIndex);
public sealed record FileLibraryDetail(FileLibraryItem Item, FileLibraryAsset[] Assets, FileLibraryProgress? Progress);
public sealed record FileLibraryPlayback(string SourceId, string ItemId, string AssetId, string Uri,
    Dictionary<string, string> Headers, FileLibraryProgress? Progress, string? LeaseId = null);
public sealed record FileLibraryQuery(string SourceId, string? LibraryId = null, string? Type = null,
    string? ParentId = null, string Search = "", long StartIndex = 0, int Limit = 50,
    string? SortBy = null, bool? SortAscending = null, string? WatchState = null);
public sealed record FileLibraryCreate(string DraftId, string VerificationId, string CredentialRevision, string ApiBase,
    string AccessId, string SourceName, string RootPath, string Name, string Type, string? SourceId = null, string Kind = "localFolder");

public sealed record FileLibraryWebDavCredential(string Type, string? Username = null, string? Password = null, string? Token = null);
public sealed record FileLibrarySmbCredential(string Type, string? Username = null, string? Password = null,
    string? Domain = null, bool? RequireSigning = null, bool? RequireEncryption = null)
{
    public override string ToString() => "SMB credentials (redacted)";
}
public sealed record FileLibraryRemoteEntry(string RelativePath, bool IsDirectory, long Size, double ModifiedAt, string? Etag);
public sealed record FileLibraryRemoteDirectory(string RootPath, string RelativePath, FileLibraryRemoteEntry[] Entries);

/// Shared file-library commands. The host owns folder authorization and source
/// selection; there is no server impersonation or implicit multi-source query.
public sealed class OcpFileLibrary(OcpCoreClient client)
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };

    public Task<FileLibraryCapabilities> CapabilitiesAsync(CancellationToken cancellation = default)
        => Invoke<FileLibraryCapabilities>("library.capabilities", new { }, cancellation);
    public async Task OpenAsync(string directory, CancellationToken cancellation = default)
        => _ = await Invoke<JsonElement>("library.open", new { directory }, cancellation).ConfigureAwait(false);
    public Task<FileLibraryValidation> ValidateAsync(string apiKey, string apiBase, string credentialRevision, string draftId,
        CancellationToken cancellation = default, string language = "zh-CN")
        => Invoke<FileLibraryValidation>("tmdb.access.validate", new { apiKey, apiBase, credentialRevision, draftId, language }, cancellation);
    public async Task InvalidateCredentialsAsync(CancellationToken cancellation = default)
        => _ = await Invoke<JsonElement>("tmdb.access.invalidate", new { }, cancellation).ConfigureAwait(false);
    public Task<FileLibraryAccess> PrepareAccessAsync(string rootPath, string? accessRef = null, CancellationToken cancellation = default)
        => Invoke<FileLibraryAccess>("library.access.prepare", new { rootPath, accessRef }, cancellation);
    public Task<FileLibraryAccess> PrepareWebDavAsync(string rootUrl, FileLibraryWebDavCredential credential, string? accessRef = null, CancellationToken cancellation = default)
        => Invoke<FileLibraryAccess>("library.webdav.access.prepare", new { rootUrl, credential, accessRef }, cancellation);
    public Task<FileLibraryRemoteDirectory> BrowseWebDavAsync(string accessId, string relativePath = "", CancellationToken cancellation = default)
        => Invoke<FileLibraryRemoteDirectory>("library.webdav.browse", new { accessId, relativePath }, cancellation);
    public async Task RestoreWebDavAsync(string sourceId, string rootUrl, FileLibraryWebDavCredential credential, CancellationToken cancellation = default)
        => _ = await Invoke<JsonElement>("library.webdav.credentials.restore", new { sourceId, rootUrl, credential }, cancellation).ConfigureAwait(false);
    public Task<FileLibraryAccess> PrepareSmbAsync(string rootUrl, FileLibrarySmbCredential credential, string? accessRef = null, CancellationToken cancellation = default)
        => Invoke<FileLibraryAccess>("library.smb.access.prepare", new { rootUrl, credential, accessRef }, cancellation);
    public Task<FileLibraryRemoteDirectory> BrowseSmbAsync(string accessId, string relativePath = "", CancellationToken cancellation = default)
        => Invoke<FileLibraryRemoteDirectory>("library.smb.browse", new { accessId, relativePath }, cancellation);
    public async Task RestoreSmbAsync(string sourceId, string rootUrl, FileLibrarySmbCredential credential, CancellationToken cancellation = default)
        => _ = await Invoke<JsonElement>("library.smb.credentials.restore", new { sourceId, rootUrl, credential }, cancellation).ConfigureAwait(false);
    public async Task ReleasePlaybackAsync(string leaseId, CancellationToken cancellation = default)
        => _ = await Invoke<JsonElement>("library.playback.release", new { leaseId }, cancellation).ConfigureAwait(false);
    public Task<FileLibraryCreation> CreateAsync(FileLibraryCreate input, CancellationToken cancellation = default)
        => Invoke<FileLibraryCreation>("library.create", input, cancellation);
    public Task<FileLibraryRootAddition> AddRootAsync(string sourceId, string libraryId, string accessId, string rootPath, string kind = "localFolder", CancellationToken cancellation = default)
        => Invoke<FileLibraryRootAddition>("library.root.add", new { sourceId, libraryId, accessId, kind, rootPath }, cancellation);
    public async Task<FileLibraryDefinition> RenameLibraryAsync(string sourceId, string libraryId, string name, CancellationToken cancellation = default)
        => (await Invoke<LibraryResult>("library.rename", new { sourceId, libraryId, name }, cancellation).ConfigureAwait(false)).Library;
    public async Task DeleteLibraryAsync(string sourceId, string libraryId, CancellationToken cancellation = default)
        => _ = await Invoke<JsonElement>("library.delete", new { sourceId, libraryId }, cancellation).ConfigureAwait(false);
    public async Task<FileLibraryDefinition> RemoveRootAsync(string sourceId, string libraryId, string rootId, CancellationToken cancellation = default)
        => (await Invoke<LibraryResult>("library.root.remove", new { sourceId, libraryId, rootId }, cancellation).ConfigureAwait(false)).Library;
    public async Task DeleteSourceAsync(string sourceId, CancellationToken cancellation = default)
        => _ = await Invoke<JsonElement>("library.source.delete", new { sourceId }, cancellation).ConfigureAwait(false);
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
    public async Task<FileLibraryItem[]> NextUpAsync(string sourceId, int limit = 20, CancellationToken cancellation = default)
        => (await Invoke<Items>("library.query.nextUp", new { sourceId, limit }, cancellation).ConfigureAwait(false)).Values;
    public async Task<FileLibraryJob> ScanAsync(string sourceId, string libraryId, CancellationToken cancellation = default)
        => (await Invoke<Job>("library.scan.start", new { sourceId, libraryId }, cancellation).ConfigureAwait(false)).Value;
    public enum ScanAction { Pause, Resume, Cancel }
    public async Task<FileLibraryJob> ControlScanAsync(string sourceId, string jobId, ScanAction action, CancellationToken cancellation = default)
        => (await Invoke<Job>($"library.scan.{action.ToString().ToLowerInvariant()}", new { sourceId, jobId }, cancellation).ConfigureAwait(false)).Value;
    public async Task<FileLibraryJob[]> JobsAsync(string sourceId, CancellationToken cancellation = default)
        => (await Invoke<Jobs>("library.jobs.snapshot", new { sourceId }, cancellation).ConfigureAwait(false)).Values;
    public async Task<FileLibraryScrapeRun> ScrapeAsync(string sourceId, string libraryId, bool refresh = false, CancellationToken cancellation = default)
        => (await Invoke<ScrapeRun>("library.scrape.start", new { sourceId, libraryId, refresh }, cancellation).ConfigureAwait(false)).Value;
    public enum ScrapeAction { Pause, Resume, Cancel, Retry }
    public async Task<FileLibraryScrapeRun> ControlScrapeAsync(string sourceId, string runId, ScrapeAction action, CancellationToken cancellation = default)
        => (await Invoke<ScrapeRun>($"library.scrape.{action.ToString().ToLowerInvariant()}", new { sourceId, runId }, cancellation).ConfigureAwait(false)).Value;
    public async Task<FileLibraryScrapeRun[]> ScrapesAsync(string sourceId, CancellationToken cancellation = default)
        => (await Invoke<ScrapeRuns>("library.scrape.snapshot", new { sourceId }, cancellation).ConfigureAwait(false)).Values;
    public Task<FileLibraryMatchCandidates> CandidatesAsync(string sourceId, string itemId, string query, CancellationToken cancellation = default)
        => Invoke<FileLibraryMatchCandidates>("library.match.candidates", new { sourceId, itemId, query }, cancellation);
    public async Task<FileLibraryItem> BindAsync(string sourceId, string itemId, string inputVersion, long tmdbId, CancellationToken cancellation = default)
        => (await Invoke<BindResult>("library.match.bind", new { sourceId, itemId, inputVersion, tmdbId }, cancellation).ConfigureAwait(false)).Item;
    public async Task UnbindAsync(string sourceId, string itemId, CancellationToken cancellation = default)
        => _ = await Invoke<JsonElement>("library.match.unbind", new { sourceId, itemId }, cancellation).ConfigureAwait(false);
    public Task<FileLibraryPlayback> PreparePlaybackAsync(string sourceId, string itemId, string assetId, CancellationToken cancellation = default)
        => Invoke<FileLibraryPlayback>("library.playback.prepare", new { sourceId, itemId, assetId }, cancellation);
    public async Task<bool> RecordProgressAsync(FileLibraryProgress progress, CancellationToken cancellation = default)
        => (await Invoke<ProgressResult>("library.progress.record", progress, cancellation).ConfigureAwait(false)).Accepted;
    public async Task<FileLibraryProgress> MarkPlayedAsync(string sourceId, string itemId, bool played, double? recordedAt = null, CancellationToken cancellation = default)
        => (await Invoke<MarkPlayedResult>(played ? "library.progress.markPlayed" : "library.progress.markUnplayed",
            new { sourceId, itemId, recordedAt }, cancellation).ConfigureAwait(false)).Progress;

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
    private sealed record LibraryResult(FileLibraryDefinition Library);
    private sealed record Job([property: System.Text.Json.Serialization.JsonPropertyName("job")] FileLibraryJob Value);
    private sealed record Jobs([property: System.Text.Json.Serialization.JsonPropertyName("jobs")] FileLibraryJob[] Values);
    private sealed record ScrapeRun([property: System.Text.Json.Serialization.JsonPropertyName("run")] FileLibraryScrapeRun Value);
    private sealed record ScrapeRuns([property: System.Text.Json.Serialization.JsonPropertyName("runs")] FileLibraryScrapeRun[] Values);
    private sealed record BindResult(bool Bound, FileLibraryItem Item);
    private sealed record ProgressResult(bool Accepted, FileLibraryProgress? Progress);
    private sealed record MarkPlayedResult(FileLibraryProgress Progress);
}

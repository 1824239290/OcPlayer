# File-library Core contract, schema 3

The Core implements permanent storage, local enumeration, explicit movie/TV structure, authenticated creation receipts, durable TMDB scraping and native SDK projections from `docs/MEDIA-LIBRARY-IMPLEMENTATION-V3.md`. The macOS host connects source selection, folder/bookmark UI, classified browsing, TMDB artwork, manual matching and the existing player. WebDAV adds authenticated remote directory browsing, checkpointed scanning and leased loopback Range playback. Subtitles, offline artwork retention and SMB IO remain subsequent slices. `library.capabilities` reports `schemaVersion: 3`, `tmdbScraping: true`, `remoteProviders: true`, and `sourceKinds: ["localFolder", "webdav"]`; the existing server APIs keep their original behavior.

All commands use the existing `ocp_call` JSON response envelope and request cancellation ownership. No command requires `OCP_CORE_ENABLED`. Swift uses `OcpFileLibrary`; C# uses `OcpFileLibrary`. The host must detect capabilities from the actual bundled Core before exposing features.

## Creation sequence

1. Open the application data directory with `library.open { directory }`. Clients already configured with `dataDirectory` may use its default. The service opens **Library.sqlite**, not the disposable Media.sqlite cache. Corruption and unknown future schema versions produce an error; no automatic deletion/rebuild is permitted.
2. Hold the platform's authorized directory scope, then call `library.access.prepare { rootPath, accessRef? }`. The reply contains a short-lived opaque `accessId` and canonical root. `accessRef` refers to a host-owned bookmark; the Core does not decode or store bookmark bytes. The host must retain scope for background scans and each playback/subtitle consumer.
3. Call `tmdb.access.validate { apiKey, apiBase, credentialRevision, draftId, language? }`. Language defaults to `zh-CN`. API Key uses the existing query authentication; a read token uses Bearer authentication. The command requests `/configuration` and validates its JSON structure. Nonempty keys, invented booleans, HTML mirror pages and 401/403 responses do not grant creation. Successful validation also installs the credentials in this Core handle's memory for online work; no credentials are persisted by the Core.
4. On success, receive `{ status: "valid", verificationId, expiresInSeconds: 600 }`. Only the Core mints this receipt. It belongs to the draft, credential generation and endpoint. Receipts are process-local and are not restored after restart.
5. Call `library.create` with `draftId`, `verificationId`, `credentialRevision`, `apiBase`, `accessId`, `kind: "localFolder"`, `sourceId?`, `sourceName`, `rootPath`, `name`, `type: "movies" | "tvshows"`. The directory must belong to the authorized source root. An existing source can add nonoverlapping child directories with different types. The reply contains a persistent library and the initial scan job.
6. Enumeration runs on a Core-owned background worker and independent database connection. Observe `library.jobs.snapshot`. Creation queues TMDB work automatically; it waits for enumeration to finish, then identifies works and downloads locally present seasons. Observe `library.scrape.snapshot` separately. Reusing an unchanged `draftId` returns the same library and initial scan job, including after that scan finishes; it does not create another source or silently rescan.

Changing or clearing the host TMDB configuration calls `tmdb.access.invalidate`, which revokes receipts and pauses online work, including results still in flight. Starting validation with a changed key, revision, endpoint or language also revokes previous receipts before the request finishes. Key material never enters source records, job inputs, the permanent catalog or diagnostic snapshots. Revalidating after restart enables explicit continuation of interrupted queues; it does not gate catalog reads or undo user pauses.

At most two scans run per Core handle. Another new creation keeps its draft outside the database until a worker is available. Explicit scan requests may leave a queued job and return a capacity error; retry that request when capacity is available. Destroying the handle signals pause and joins its workers before native unload.

## Commands

| Command | Required scope/input | Result |
|---|---|---|
| `library.capabilities` | none | Actual source kinds, library types and implemented capabilities; no aggregation |
| `library.open` | application `directory` | Permanent database path |
| `library.access.prepare` | `rootPath`, optional `accessRef` | Short-lived directory receipt |
| `tmdb.access.validate` | Credential, endpoint, revision, draft | Authenticated creation receipt |
| `tmdb.access.invalidate` | none | Revokes all creation receipts |
| `library.create` | Valid receipts and explicit type | Source/library registration and initial scan job |
| `library.sources.list` | none | Saved file-source profiles; host combines profiles with saved media servers in its source selector |
| `library.libraries.list` | `sourceId` | Only that source's classified libraries |
| `library.query.page` | `sourceId`, optional `libraryId`, `type`, `parentId`, `search`, `startIndex`, `limit` | Scoped page and consistent total count; limit 1...500 |
| `library.query.detail` | `sourceId`, `itemId` | Item, its assets and saved progress |
| `library.query.resume` | `sourceId`, optional `limit` (1...100, default 20) | Playable movie/episode leaves with positive progress, unplayed and incomplete, sorted by recordedAt descending |
| `library.scan.start` | `sourceId`, `libraryId` | New job or existing resumable job |
| `library.scan.pause/resume/cancel` | `sourceId`, `jobId` | Job snapshot; active pause/cancel takes effect at the next checkpoint |
| `library.jobs.snapshot` | `sourceId` | Latest 100 jobs for that source |
| `library.scrape.start` | `sourceId`, `libraryId`, optional `refresh` | Durable run; a live/paused run is reused, otherwise a new run is created. Missing validated credentials leave online work waiting |
| `library.scrape.snapshot` | `sourceId` | Latest run per category, status, total/completed/unmatched/failed counts, safe error text and next retry time |
| `library.scrape.pause/resume/cancel/retry` | `sourceId`, `runId` | Pause/cancel at the online boundary; resume requires current validated credentials. Retry resets failed/unmatched/scheduled targets |
| `library.match.candidates` | `sourceId`, movie/series `itemId`, optional `query` | Type-scoped TMDB candidates and an opaque `inputVersion` |
| `library.match.bind` | `sourceId`, `itemId`, candidate `tmdbId`, `inputVersion` | Download checked metadata and save a manual lock; stale versions/configurations are rejected |
| `library.match.unbind` | `sourceId`, movie/series `itemId` | Remove the match and child projections, retire its pending online work; assets/progress remain |
| `library.webdav.access.prepare` | `rootUrl`, `credential`, optional host `accessRef` | Validated short-lived access receipt; PROPFIND must succeed |
| `library.webdav.browse` | `accessId`, decoded `relativePath` (default empty) | Validated selected root and immediate children, relative to source root |
| `library.webdav.credentials.restore` | Existing `sourceId`, original `rootUrl`, `credential` | Validate and install runtime credentials without TMDB; same root required |
| `library.playback.prepare` | `sourceId`, `itemId`, `assetId` | Checked local URI or loopback URI plus `leaseId`, original identities, headers and progress |
| `library.playback.release` | `leaseId` | Idempotently release the runtime resource after all native readers retire |
| `library.progress.get` | `sourceId`, `itemId` | Permanent progress or null |
| `library.progress.record` | Leaf identities, position, optional duration, explicit played/completed flags, recordedAt | Whether the event was accepted and current progress |

Unknown records return code 1604, database/IO errors return 1602, malformed arguments return 1002, cancellation retains 1003. TMDB transport errors retain existing domain error classification. A query cannot resolve a foreign library, item or asset by a bare ID.

## Catalog and scan semantics

Movies are leaf items with one physical asset before matching. TV files with reliable season/episode context form **series → season → episode → assets**. Same-episode variants in one structural series group share the episode; identical titles in distinct directories do not merge before identification. S0 remains a season. Bare numbers, unsupported multi-episode ranges and ambiguous filenames remain unidentified assets in the TV library.

The first parser accepts bracketed release years or dotted release-name years, explicit `S02E03` / `2x03`, and numbered files inside a known series/season directory. It intentionally retains numeric titles such as `1917` and `Blade Runner 2049`. NFO parsing, richer language rules, absolute numbering and confirmed movie variant grouping remain future parser/matching work.

Entry and item identities are stored UUIDs, independent of mutable paths/metadata. Same-path rescans keep identities. Rename detection is not implemented in this slice. Durable directory checkpoints survive restart; interrupted jobs resume explicitly. Failure or cancellation never marks unseen assets missing. A completely successful enumeration can mark missing assets while retaining their index and watching facts. A superseded scan generation cannot publish entries or perform deletion reconciliation. Symlinks are skipped; playback checks the real path stays inside the library root.

Progress belongs to the original source/item. Only strictly later timestamps replace a saved record; stop/near-end positions do not automatically set completed. Existing catalog reads, permanent metadata and watching facts do not depend on possessing a current TMDB credential.

## WebDAV provider and playback contract

Credentials are tagged JSON: `{ "type": "none" }`, `{ "type": "basic", "username": "...", "password": "..." }`, or `{ "type": "bearer", "token": "..." }`. They live only in Core memory. The host saves its credential under the source's stable `accessRef`; macOS uses the existing hardened credential-file store (0600, excluded from backups) in `LibraryCredentials.json`, matching the repository's ad-hoc signing policy. URLs with user info, queries or fragments are rejected; expiring signed URLs are not source identities.

For creation, validate TMDB for the current draft as above, prepare WebDAV access, browse the intended category, then call `library.create` with `kind: "webdav"` and the returned category `rootPath`. Access expires after ten minutes. Only explicitly opened category directories can be registered, and categories within one source cannot overlap. Restoring an existing source validates DAV separately; catalog reads need neither credential. New credential restoration uses an epoch so an older concurrent validation cannot reinstall obsolete access. It pauses existing scans while in-flight playback leases retain their original resource until native retirement.

`PROPFIND Depth: 1` parses the DAV namespace, successful propstat blocks, collection markers, 64-bit lengths, modification times and ETags. Response bodies are bounded at 8 MiB and 50,000 children. Self entries are verified and excluded. Foreign origins, parent traversal, encoded path separators, non-immediate children, duplicate identities and partial/failed properties are rejected as a whole. Relative asset paths use decoded UTF-8 segments and are encoded exactly once for requests. ETag participates in the scrape input fingerprint.

Remote scans use the same permanent directory checkpoints, asset ingestor and TMDB queue as local scans. An unsuccessful listing leaves its directory unfinished and the job in `waitingNetwork` or `waitingCredentials`; explicit resume retries it, including after restart. No partial attempt performs deletion reconciliation. A recovered attempt retains its earlier error count and ends `partialFailure`; a new error-free full scan can reconcile deletions. Pause/cancel interrupts network waiting. The host does not silently change media sources when the selected DAV source is offline.

Preparation performs an actual authenticated `GET Range: bytes=0-0`, requires 206 and a matching Content-Range/length, and consumes exactly one byte. `Accept-Ranges` alone is insufficient. A leased endpoint binds only to 127.0.0.1 with an unguessable capability path. GET/HEAD, a single closed/open/suffix byte range, Content-Length and 416 are supported. Upstream reads are at most 4 MiB each; streaming/backpressure avoids whole-video buffers. There are at most 32 leases per handle and eight concurrent readers per lease. Caller headers are not forwarded upstream; browser Origin requests and wrong Host/path are rejected. All successful responses use `Cache-Control: no-store` and close the connection.

Every upstream request keeps DAV auth within the configured origin and category root, with at most five redirects. Cross-origin, HTTPS downgrade, out-of-root and query-bearing redirects are rejected before another request. Signed CDN redirects are deliberately unsupported until a credential-free resource resolution contract is added. TMDB and its image CDN never receive DAV headers. Remote URIs/leases are never stored in Library.sqlite or treated as server playback sessions.

The Apple request, its retries/background reopen, and Erika's native presenter share a `PlaybackResourceLifetime`. The presenter releases it only after `erika_presenter_destroy`; UI dismissal or an in-flight cancelled open cannot retire the bridge early. Its final release calls `library.playback.release` and retains the Core permission owner until that call returns. Other hosts must implement the same native-reader lifetime rule.

Schema 3 atomically rebuilds the source kind constraint to admit WebDAV and adds asset ETag. Child FK targets and all IDs, matches, queues and watch facts are retained; migration checks foreign keys before commit. Source/library root paths are canonical directory URLs for WebDAV and absolute filesystem paths for local folders. Remote records never pass through filesystem canonicalization.

## Online queue semantics

Schema 2 migrates schema 1 in one transaction, preserving catalog, matches and watch state. It adds `scrape_run`, `scrape_target`, local season/episode metadata, and a monotonic match revision. All mutating multi-statement catalog transactions acquire the SQLite write lock before reading their input, preventing concurrent scan/scrape writes from dropping discovered files.

At most two category queues run per Core handle, with one in-flight request per queue. Network calls run on dedicated workers, outside playback state locks and SQLite transactions. Queue targets represent movies, whole series and locally present seasons; episodes reuse their season download. No absent TMDB episodes or fake playable assets are inserted. New locally discovered episodes can refresh the corresponding season.

Automatic matching retains the existing 0.85 threshold and additionally rejects near ties (confidence gap under 0.1). Missing years and ambiguous same-name works normally require manual selection; a failed match never removes the file. Manual refresh uses the already selected TMDB identity and keeps its lock. File-only checked TMDB methods validate search arrays, entity identities, explicit season numbers and episode identities; legacy server enrichment retains its existing wire tolerance.

401/403 pauses online queues and revokes creation access. Network/timeout/5xx and rate limits schedule up to three durable target attempts, honoring Retry-After where available; the underlying HTTP client's own 429 retry policy remains in effect. Exhausted or malformed targets remain failed for explicit retry. Queue states include `queued`, `running`, `paused`, `interrupted`, `waitingCredentials`, `waitingNetwork`, `completed`, `needsMatch`, `partialFailure`, `cancelled`, `failed`.

Each result checks library revision, scan generation, original parsed input, asset state and match revision in a short write transaction. A credential epoch gate serializes final writes with invalidation. Late results cannot replace a manual match, write after credential invalidation, or publish against a newer scan. Old metadata remains readable after failures; cached metadata is refreshed when older than 30 days or explicitly requested.

The macOS host starts online work after creation and offers continuation/retry plus manual movie/series matching. Artwork uses the existing image pipeline with a source-scoped cache and the configured TMDB image mirror, independently of Key availability. Artwork remains an evictable cache; permanent offline poster retention is not implemented.

## Validation

- Rust parser/store tests use temporary directories and cover numeric titles, TV hierarchy, source isolation, same-title directories, stable identities, manual locks, interrupted scans, stale generations, unavailable roots, corruption preservation and symlink escapes.
- Core integration tests use a local HTTP fixture to verify API Key/Bearer authentication, malformed mirror/401/403 rejection, real validation-to-playback command flow, idempotent creation and absence of credentials in database files.
- Scrape integration fixtures verify automatic movie/TV matching, near ties, S0, one download per season, no fabricated episodes, manual locks, stale input rejection, in-flight credential cancellation, 5xx scheduling/retry, revoked credentials and simultaneous enumeration/online writes. Store fixtures also upgrade a real schema-1 database containing matching metadata and watch state.
- Swift SDK tests exercise the actual native library for capabilities, access receipts and rejection of invented validation; typed fields retain 64-bit sizes and source identity.
- macOS host tests use the real native library with a local authenticated HTTP fixture. They cover movie/TV categories within one source, S0, durable bookmarks, canonical-path reauthorization, foreign-directory rejection, credential clearing, permanent resume and switching back to a server. The WebDAV host fixture embeds the shared Python service in its test code (`core/Scripts/sync-webdav-test-fixture.py --check` verifies synchronization), so the child process need not read repository files. It additionally generates a three-second video with ffmpeg and opens/seeks it through the actual liberika presenter and Core Range bridge. This confirms the local transport path; real NAS and device compatibility still need validation.
- Public command inventory/negative-boundary contracts include all new commands. C# SDK needs a .NET 10 host for build and platform integration validation.

- DAV contracts cover UTF-8/literal percent and special-character paths, DAV namespaces/multiple propstats, self exclusion, i64 sizes, traversal/foreign href rejection, HTTP 200 or wrong Content-Range rejection, same-origin redirects, a cross-origin credential trap, window/suffix reads, lease release, permanent metadata/progress across reopen, movie/TV/S0 categories and failed-directory checkpoints across restart.

# File-library Core contract, schema 1

The Core implements permanent storage, local enumeration, explicit movie/TV structure, authenticated creation receipts and native SDK projections from `docs/MEDIA-LIBRARY-IMPLEMENTATION-V3.md`. The macOS host now connects source selection, folder/bookmark UI, classified browsing and the existing player. Online scraping, artwork, subtitles and SMB/WebDAV IO remain subsequent slices. `library.capabilities` explicitly reports those limits; the existing server APIs keep their original behavior.

All commands use the existing `ocp_call` JSON response envelope and request cancellation ownership. No command requires `OCP_CORE_ENABLED`. Swift uses `OcpFileLibrary`; C# uses `OcpFileLibrary`. The host must detect capabilities from the actual bundled Core before exposing features.

## Creation sequence

1. Open the application data directory with `library.open { directory }`. Clients already configured with `dataDirectory` may use its default. The service opens **Library.sqlite**, not the disposable Media.sqlite cache. Corruption and unknown future schema versions produce an error; no automatic deletion/rebuild is permitted.
2. Hold the platform's authorized directory scope, then call `library.access.prepare { rootPath, accessRef? }`. The reply contains a short-lived opaque `accessId` and canonical root. `accessRef` refers to a host-owned bookmark; the Core does not decode or store bookmark bytes. The host must retain scope for background scans and each playback/subtitle consumer.
3. Call `tmdb.access.validate { apiKey, apiBase, credentialRevision, draftId }`. API Key uses the existing query authentication; a read token uses Bearer authentication. The command requests `/configuration` and validates its JSON structure. Nonempty keys, invented booleans, HTML mirror pages and 401/403 responses do not grant creation.
4. On success, receive `{ status: "valid", verificationId, expiresInSeconds: 600 }`. Only the Core mints this receipt. It belongs to the draft, credential generation and endpoint. Receipts are process-local and are not restored after restart.
5. Call `library.create` with `draftId`, `verificationId`, `credentialRevision`, `apiBase`, `accessId`, `kind: "localFolder"`, `sourceId?`, `sourceName`, `rootPath`, `name`, `type: "movies" | "tvshows"`. The directory must belong to the authorized source root. An existing source can add nonoverlapping child directories with different types. The reply contains a persistent library and the initial scan job.
6. Enumeration runs on a Core-owned background worker and independent database connection. Observe `library.jobs.snapshot`. Reusing an unchanged `draftId` returns the same library and initial job, including after that scan finishes; it does not create another source or silently rescan.

Changing or clearing the host TMDB configuration calls `tmdb.access.invalidate`, which revokes receipts, including validations still in flight. Starting validation with a changed key, revision or endpoint also revokes previous receipts before the request finishes. Key material never enters source records, job inputs, the permanent catalog or diagnostic snapshots.

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
| `library.playback.prepare` | `sourceId`, `itemId`, `assetId` | Checked local file URI, original identities, headers and progress |
| `library.progress.get` | `sourceId`, `itemId` | Permanent progress or null |
| `library.progress.record` | Leaf identities, position, optional duration, explicit played/completed flags, recordedAt | Whether the event was accepted and current progress |

Unknown records return code 1604, database/IO errors return 1602, malformed arguments return 1002, cancellation retains 1003. TMDB transport errors retain existing domain error classification. A query cannot resolve a foreign library, item or asset by a bare ID.

## Catalog and scan semantics

Movies are leaf items with one physical asset before matching. TV files with reliable season/episode context form **series → season → episode → assets**. Same-episode variants in one structural series group share the episode; identical titles in distinct directories do not merge before identification. S0 remains a season. Bare numbers, unsupported multi-episode ranges and ambiguous filenames remain unidentified assets in the TV library.

The first parser accepts bracketed release years or dotted release-name years, explicit `S02E03` / `2x03`, and numbered files inside a known series/season directory. It intentionally retains numeric titles such as `1917` and `Blade Runner 2049`. NFO parsing, richer language rules, absolute numbering and confirmed movie variant grouping remain future parser/matching work.

Entry and item identities are stored UUIDs, independent of mutable paths/metadata. Same-path rescans keep identities. Rename detection is not implemented in this slice. Durable directory checkpoints survive restart; interrupted jobs resume explicitly. Failure or cancellation never marks unseen assets missing. A completely successful enumeration can mark missing assets while retaining their index and watching facts. A superseded scan generation cannot publish entries or perform deletion reconciliation. Symlinks are skipped; playback checks the real path stays inside the library root.

Progress belongs to the original source/item. Only strictly later timestamps replace a saved record; stop/near-end positions do not automatically set completed. Matching snapshots and manual locks already have a separate permanent storage boundary, but online matching/scraping commands are not exposed yet. Existing catalog reads do not depend on possessing a current TMDB credential.

## Validation

- Rust parser/store tests use temporary directories and cover numeric titles, TV hierarchy, source isolation, same-title directories, stable identities, manual locks, interrupted scans, stale generations, unavailable roots, corruption preservation and symlink escapes.
- Core integration tests use a local HTTP fixture to verify API Key/Bearer authentication, malformed mirror/401/403 rejection, real validation-to-playback command flow, idempotent creation and absence of credentials in database files.
- Swift SDK tests exercise the actual native library for capabilities, access receipts and rejection of invented validation; typed fields retain 64-bit sizes and source identity.
- macOS host tests use the real native library with a local authenticated HTTP fixture. They cover movie/TV categories within one source, S0, durable bookmarks, canonical-path reauthorization, foreign-directory rejection, credential clearing, permanent resume and switching back to a server. These are catalog/playback-preparation tests, not real video-decoder validation.
- Public command inventory/negative-boundary contracts include all new commands. C# SDK needs a .NET 10 host for build and platform integration validation.

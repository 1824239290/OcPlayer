# Shared media cache contract

Configure Core with `dataDirectory` (opens `Media.sqlite` in that directory) or
`mediaDatabasePath` (opens that exact existing database). The explicit path wins.
The database uses the current Apple `grdb_migrations` ledger and four media
migrations. Apple GRDB and Core may open the same file; Core uses SQLite's busy
timeout and immediate write transactions to serialize read/modify/write operations.
Locale-only settings/import operations keep the existing store open.

All `cache.*` commands use the standard API envelope. `data` is the result
itself, rather than an extra named wrapper. Missing persistence is code 1401,
invalid arguments are 1002, and database failures are 1402. A database failure
is an error, not an empty cache. Times are Unix seconds; `now` and progress
boundaries accept fractional seconds. Indexed freshness timestamps retain the
existing integer-second representation. Payload version remains 1.

## Commands

| Command | Arguments beyond `tenantId` | Result in `data` |
| --- | --- | --- |
| `cache.touchTenant` | `kind`, optional `serverName`, `now` | null |
| `cache.hasContent` | — | boolean |
| `cache.saveItems` | `items`, optional `rail`, `now`, `requestStartedAt`, optional `progressFresh` (default true) | reconciled item array |
| `cache.item` | `itemId` | cached item row or null |
| `cache.items` | `ids` | cached rows in requested order, missing entries skipped, repeated IDs retained |
| `cache.posterCandidates` | `limit` | cached movie/series rows with primary image tags |
| `cache.updatePlayState` | `itemId`, `state`, optional fallback `item`, `now` | `{state,newerRecord}` |
| `cache.recordPlaybackProgress` | `item`, `positionSeconds`, optional `durationSeconds`, `now` | `{state,newerRecord}` |
| `cache.saveLibraries` | `libraries`, `now` | null; atomically replaces the tenant's complete library list |
| `cache.libraries` | — | cached library rows in stored position order |
| `cache.saveRail` | `rail`, `items`, `now` | null |
| `cache.rail` | `rail` | cached snapshot row or null |
| `cache.home` | — | `{libraries,rails}` for resume/nextUp/latest from one read transaction |
| `cache.savePage` | `key`, `payload`, `now` | null |
| `cache.page` | `key` | cached page row or null |
| `cache.pages` | `key` without pagination window | cached page rows ordered by start index and limit |
| `cache.saveMediaFileInfo` | `itemId`, `payload`, `now` | null |
| `cache.mediaFileInfo` | `itemId` | cached file-info row or null |
| `cache.seasons` | `seriesId` | item payloads ordered by season number, missing numbers last |
| `cache.episodes` | `seriesId`, `seasonId` | episode payloads, including unknown season IDs, ordered by episode number |
| `cache.itemCount` | optional `kind`; `tenantId` is also optional | integer |
| `cache.evictItems` | `maxItems`; no tenant scope | number removed globally, oldest first |
| `cache.clear` | — | null; clears tenant media cache and local progress |
| `cache.clearAll` | no arguments | null; clears all media cache and local progress |
| `cache.vacuum` | no arguments | null |
| `cache.saveTMDbPayload` | `entityKey`, `language`, `kind`, `tmdbId`, optional `seasonNumber`, `payload`, `lifetime`, `now`; no tenant scope | null |
| `cache.tmdbPayload` | `entityKey`, `language`; no tenant scope | cached entity/season payload, including expired data, or null |
| `cache.saveTMDbLink` | `itemId`, `entityKey`, `source`, `confidence`, `now` | null |
| `cache.tmdbLink` | `itemId` | `{entityKey,source,confidence,linkedAt}` or null |
| `cache.removeTMDbLink` | `itemId` | null |
| `cache.tmdbLinkCount` | — | integer |
| `cache.evictExpiredTMDb` | `now`; no tenant scope | number deleted, expiry boundary inclusive |
| `cache.clearTMDb` | — | null; removes tenant links then globally unreferenced entities |

`cache.evictItems` does not require `tenantId`; it applies to all tenants.
A page key uses `parentID`, `kinds`, `sortKey`, `watchState`, `searchTerm`,
`startIndex`, `limit`. The Apple caller retains its existing sorted-kind and
sort/filter key normalization. A page payload is `{items,totalRecordCount}`;
a rail payload is `{items}`. Cached rows contain `payload` and `fetchedAt`, with
`progressFetchedAt` for items, `startIndex`/`limit` for pages, and `expiresAt`
for TMDB payloads. Library and technical-info payloads retain the existing
Apple Codable JSON schema. Invalid JSON/object payloads and unknown versions
are cache misses; the Apple decoding boundary additionally rejects invalid
platform enum/type fields without poisoning other rows.

## Progress and eviction invariants

Metadata merging, canonical item writes, local-progress observation and an
optional rail update commit in one transaction. An unconfirmed final playback
position protects against remote responses until a later-started request
observes the same state, or a completed playback is reported as watched.
Requests started before confirmation remain protected, even if they finish
later. Explicit watched/unwatched operations store a confirmed boundary.
Older queued local writes cannot overwrite a newer operation. Completion and
watched state remain distinct.

Rail/page reads overlay canonical progress in the same transaction while
retaining the snapshot's metadata, order and timestamps. Independent progress
records survive item eviction. Confirmed evicted records are compacted;
unconfirmed records retain metadata needed to restore missing resume entries.
Expired TMDB data remains readable offline until explicit maintenance removes
it. Shared TMDB entities are removed only after deleting links and checking
references across all tenants. Media-cache clear and TMDB clear retain their
existing separate scopes.

Apple `MetadataStore` selects this complete path when Core is enabled or an
explicit library is injected. Its native GRDB implementation remains available
for clients without Core and for bidirectional compatibility verification. A
selected Core operation never replays through GRDB after a command failure.

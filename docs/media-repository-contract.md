# Shared media repository state and database opening

`mediaRepository.*` retains all five production projection buckets and refresh
ownership in one Core handle per native repository. Swift retains native task
handles and executes network/database effects. The native implementation remains
available with `useSharedCore: false` for independent comparison.

## Projection and refresh protocol

`open` accepts `itemLimit`, `detailLimit`, `episodeListLimit`, `pageLimit` with
native defaults 1024/40/80/24. Every limit is at least one; home has one slot.
`get`/`put` take a bucket and textual `payloadJSON` containing a typed key and
optional entry `{value,fetchedAt}`. A null entry deletes. Keys may be structured
page/episode identities. `all` returns key/entry rows without touching recency.
`clearBucket` and `clear` invalidate projections without cancelling or retiring
active refreshes. Gets and writes touch recency; eviction removes the least
recently accessed entry. Invalid entries leave existing data unchanged.

Lookup identity follows Swift String canonical equivalence recursively through
structured keys. NFC is used only for lookup; original keys and complete payloads
are preserved. Array ordering, nil/empty differences, recursive queries and
sort/filter/search fields retain native identity. Typed original-byte response
decoding preserves signed integer fields and arbitrary metadata across snapshots.
Memory timestamps retain the existing platform Codable Date representation;
Foundation supplies the exact age used for freshness comparisons.

`claim` takes refresh kind home/item/detail/episodes/page plus the normalized
native request key and returns owner plus UInt64 ticket. Same-key calls join the
actor's retained Swift task. Only the owner calls `finish` after awaiting success
or failure; cancellation of a waiter and memory invalidation do not retire work.
Page ownership uses the existing PageKey, while page projections use the full
MediaPageDescriptor. Detail kind hints retain the first owner's behavior.
`stats` reports flight count, bucket limits/counts and recency.

`freshness` preserves the distinct native boundaries: non-disk snapshots are
fresh when age is strictly below TTL; progress is stale when missing or age is
strictly greater than TTL. Negative ages/TTLs retain the native comparison rules.
No freshness result prevents an offline cache read.

## Disposable media database protocol

`metadataDatabase.open` takes a non-empty directory path, creates parent
folders, opens Media.sqlite in WAL mode, enables foreign keys, best-effort sets
the writer journal limit to 8 MiB and applies the four native GRDB ledger
migrations. On opening or migration failure it removes only Media.sqlite and its
WAL/SHM sidecars, then attempts opening once more. Symlinks themselves are removed;
an incorrectly placed directory at a sidecar path follows native recursive
removal. Individual removal failures are ignored; a second open failure is an
error. Valid existing caches and unrelated files are retained.

The returned `{path,rebuilt,firstError}` adopts the opened Store and its explicit
configured media path. `metadataDatabase.size` counts the file and both sidecars
without creating folders, returning zero for missing files. `remove` releases the
handle's current Store and performs the same fixed-file, best-effort removal.
Invalid arguments are code 1002; filesystem/SQLite failures are 1402. Core
`dataDirectory` cache opening uses this recovery path; an explicit existing
`mediaDatabasePath` retains its non-destructive opening behavior.

Production MetadataCache/MetadataDatabaseFactory delegates this complete
opening/migration/recovery decision to Core when enabled. A compatible GRDB pool
is opened after successful shared migration, without replaying migrations or
recovery. A selected Core error is returned to the app's existing memory-mode
fallback and setup-error presentation. Native-only opening remains independent.

## Evidence and remaining migration

Five memory/ownership/Unicode Rust cases and five database Rust cases cover this
state. Six direct C ABI cases include 32 concurrent claims, every bucket/command,
freshness/preflight boundaries and actual file recovery. Six native differential
cases include 6000 LRU operations over four limits and five buckets, full public
memory-only home/detail/page/progress projections, typed structured identities,
waiter cancellation, migration/rebuild/file accounting and unrecoverable paths.

The next retained session stage is specified in
[media-repository-progress.md](media-repository-progress.md): local progress,
observation, confirmation/revision barriers, all projection updates and shutdown
state now run in Core. Home/detail/page reductions are specified in
[media-repository-composition.md](media-repository-composition.md). Pagination,
home deduplication/restoration, detail planning and progress composition now run
in Core; complete effect sequencing, cache restoration and failure/fallback assembly
now use [retained workflows](media-repository-flow.md). Neither cohort completes the repository or the
full parity goal. Projection/database raw records are retained under
`validation/2026-11-14-media-repository/`.

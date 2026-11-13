# Shared danmaku cache

Each `DanmakuCache` actor retains a Core handle with one `danmakuCache.open`
cache. The production actor delegates mapping, revision barriers, comments,
saved intro hints and purge to Core when enabled with the default FileManager.
An explicitly injected FileManager or disabled Core retains the native path.
After successful activation, cache operations do not replay through Swift.

`danmakuCache.open` accepts an absolute `directory`, optional finite
`commentsTTL` (default 3600 seconds) and non-negative `commentsMemoryCapacity`
(default 2; zero disables comment memory). Reopening replaces the handle's
cache and its in-memory state. Directory creation is best effort, retaining
native write-through memory behavior during temporary disk failures.

All operations below return `data.payloadJSON`, a JSON string decoded directly
into the host's domain type. This avoids converting Int64 IDs and UInt64
revisions through Swift's generic Double JSON representation.

| Operation | Arguments | Decoded result |
| --- | --- | --- |
| `episodeMatch` | `mediaID` | Optional saved match |
| `allEpisodeMatches` | None | All saved matches, unordered |
| `setEpisodeMatch` | `mediaID`, `payloadJSON`, optional `revision` | Write success |
| `removeEpisodeMatch` | `mediaID`, optional `revision` | Mutation accepted |
| `claimRevision` | `mediaID`, required `revision` | Barrier accepted |
| `claimedRevision` | `mediaID` | Optional highest claimed revision |
| `comments` | `episodeID`, optional `now` | Optional comment array |
| `setComments` | `episodeID`, `payloadJSON`, optional `now` | Write success |
| `introHint` | `episodeID` | Optional saved hint |
| `setIntroHint` | `episodeID`, `payloadJSON` | Write success |
| `memoryCount` | None | Number of cached comment episodes |
| `stats` | None | Memory count/capacity and lifetime write-failure count |
| `purge` | None | True after best-effort clearing/recreating the cache folder |

`payloadJSON` accepts a JSON string or domain JSON object/array. Match fields
are `episodeID`, required `shiftSeconds`, optional `animeID`, `animeTitle` and
`episodeTitle`. IDs and shifts are signed 64-bit integers. Comments retain the
original `cid`, `p` and `m`. Intro hints retain optional `startSeconds`, required
`endSeconds` and `evidenceCount`, and source `danmaku`, `aniskip`, `animeSkip`,
`theIntroDB` or `learned`; missing/null sources default to `danmaku`.

Files retain OcPlayer's `mapping.json`, `comments-<episodeID>.json` and
`intro-hints.json`. Comment files use `{fetchedAt,comments}` with a numeric
Swift reference-date timestamp (seconds since 2001-01-01 UTC). Optional `now`
uses the same epoch and exists for deterministic host/ABI tests.

Legacy integer-only mappings migrate on the next successful write. Mapping
read/decode failures are retried without replacing recoverable files. Higher
revisions reject stale writes/removals; a mutation without a revision clears
the media's barrier. Barriers remain in memory. Corrupt intro hints can be
replaced, matching native recovery behavior.

Comments use true LRU eviction from memory only, with TTL checked on every
read. A timestamp at the TTL boundary remains valid. Expired memory falls
through to disk and checks the disk entry's own timestamp before deleting an
expired file, preserving another cache instance's fresh write. Disk writes use
same-directory temporary files and atomic rename. Failed writes retain the
native write-through memory semantics and increment `writeFailures`.

Unconfigured caches return 1401; malformed arguments return 1002. Ordinary
cache read failures return misses, and write failures return false rather than
triggering a second host write. Operations use the normal Core response envelope.

Six direct C ABI cases cover exact large IDs/revisions, legacy formats, recovery,
TTL boundaries, LRU, multi-instance refresh, purge, zero capacity and failed
atomic writes. Three macOS interoperability cases require active Core and
verify bidirectional files, corrupted/legacy mappings and UInt64.max barriers.
Existing DanmakuKit cache/load tests also run with shared cache enabled.
Shared resolver scheduling and intro detection/learning/provider policies remain
separate, unfinished migration work.

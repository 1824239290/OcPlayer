# Shared AniList identity and ID persistence

Production AniSkip ID resolution now runs in Core: title normalization, SHA-256
cache keys, direct-ID/cache plans, ordered AniList requests, candidate matching,
negative-cache expiration and `aniskip-ids.json` persistence. The macOS store
and provider share one retained Core handle and one in-memory record map.
Custom URLProtocol transports still use Swift requests with the shared plan and
matching policy. Core-disabled implementations remain independent test oracles.

## Commands

Typed results use `payloadJSON` to preserve signed 64-bit IDs through the Apple
binding. Identity input is `payloadJSON` containing `malID`, `anilistID`, `title`,
`alternativeTitles`, `seasonNumber` and `year`.

| Command | Other arguments | Result inside `payloadJSON` |
| --- | --- | --- |
| `introIdentity.searchTitles` | Identity | Ordered, trimmed, comparable-title-deduplicated titles |
| `introIdentity.cacheKey` | Identity | Native-compatible SHA-256 key |
| `introIdentity.bestMatch` | `payloadJSON` candidate array, `title` | Optional candidate index and rule |
| `introIdentity.plan` | Identity, optional `recordJSON`, `forceRefresh`, `now` | Cache key, ready IDs or ordered lookup/search work |
| `introProvider.resolveIDs` | Optional `anilistID`, `searchTitles`, `baseURL`, transport options | IDs, selected title/rule and attempted-request diagnostics |
| `introIDs.open` | Absolute `directory` | `{opened:true}` (ordinary JSON envelope) |
| `introIDs.record` | `key` | Optional cached record |
| `introIDs.write` | `key`, `payloadJSON` record | Write accepted; disk persistence is best effort |
| `introIDs.plan` | Identity, optional `forceRefresh`/`now` | Plan from the shared record map |
| `introIDs.stats` | None | Loaded flag and record count; does not force disk loading |
| `introIDs.resolve` | Identity, transport options, optional `forceRefresh`/`now`/`commit`/`resolvedAt` | IDs, cache key, `needsCommit`, optional network resolution |

`now` and stored `resolvedAt` use Foundation reference-date seconds. The default
clock is sampled by Core; macOS supplies its injected clock. With `commit:false`,
macOS samples its clock after the awaited request and writes through the same
store. Default `commit:true` samples Core's clock after fetching; an explicit
finite `resolvedAt` can override the commit time for fixtures.

## Preserved behavior

A positive supplied MAL ID returns immediately without loading the cache or
creating a network client. With no AniList ID or usable title, resolution also
returns immediately. The key hashes the UTF-8 string
`v2|<AniList ID or ->|<trimmed lowercase primary title>|<season or ->|<year or ->`.
MAL ID and alternative titles do not affect it. Lowercasing preserves Swift's
scalar Greek-sigma mapping; title matching also preserves the native grapheme
boundary and full-width normalization.

A record with either ID present is permanent, including zero/negative cached
IDs. Records with both IDs absent expire at exactly seven days: `now-resolvedAt < 604800` is
valid, and a future timestamp remains valid. Forced refresh bypasses records,
but the supplied positive MAL ID still wins.

Any supplied AniList ID, including zero/negative values, triggers one direct
lookup. Its string GraphQL variable is exact at Int64 limits. Missing Media
retains that supplied AniList ID; malformed fields or HTTP/transport errors
produce empty IDs. Otherwise each search title is attempted once in order.
The first exact match wins over an earlier contained candidate within that
response; containment requires at least six comparable graphemes. A current
title match returns immediately. Across unmatched titles, the first candidate
having a MAL ID is retained as fallback; a later matching title wins over it.
Attempts retain status/error diagnostics. No failed request is replayed natively.

The JSON file remains interoperable with the native store, including legacy
records missing AniList IDs, integral floating JSON IDs, Int64 boundaries and
Foundation dates. Missing, corrupt or unreadable files cache an empty map once.
Atomic-write failure leaves the new record available in memory. Cancellation
drops pending network work and checks again before commit; a cancelled miss does
not create a negative cache record. The store mutex is released during HTTP.

## Validation and remaining scope

Eight Swift cases compare 900 Unicode title/key inputs and 900 matching corpora,
native/Core file interoperability, cached-empty recovery, failed disk writes,
ordered HTTP resolution, post-request clocks, cache/force activation and
cancellation followed by a successful retry. Six C ABI cases independently
cover the same wire/storage boundaries with a real local server. Initial failed
Unicode and compilation outputs are preserved with final verification logs.

Complete shared Danmaku load/manual/promotion orchestration and the broader
macOS acceptance rows remain active. Idle/resource deadline distinctions,
redirect/TLS/streaming fidelity and Windows runtime testing are not closed here.

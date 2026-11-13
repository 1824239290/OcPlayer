# Shared TMDB enrichment

Production TMDbEnricher now drives `tmdbEnrichment.*` continuations for ordinary
refresh, collection resolution, direct season refresh, manual binding, series
season iteration and complete batch contributions. Core retains authority,
freshness, member limits, sequencing, single-flight tickets and the four-worker
batch window; the actor performs database, injected client and Swift task effects.
Explicit `useSharedCore: false` retains the original native oracle. Dispatched
Core work is not replayed through native writes on an error.

The batch awaits each progress callback before admitting a replacement, so
callback cancellation stops refill while already-entered workers drain. Initial
pre-cancelled children process no items. Airing freshness keeps the existing
Foundation/local-calendar date conversion and delegates the strict daily/seven-
day decisions to Core. Unstructured fetch tasks remain shared until the owning
waiter retires them; completion records errors independently of retirement.
Manual/provider link authority, stale payload retention, the three-member
collection budget, specials and post-effect language sampling match native.

All RustMetadataStore reads now use original-byte typed decoding, preserving
Int.max-range fields across nested snapshots, local progress, technical file
information and TMDB payloads. Invalid payloads remain cache misses. TMDB treats
HTTP 500/503 as final while retaining rate-limit/transport retries and the shared
connection pool; other domains retain their retry defaults.

Six new native cases compare independent GRDB/native HTTP/native enrichment
against shared storage/transport/enrichment using real HTTP request traces, full
results and 320 date/age combinations. A further cache case exercises both write
directions and all typed read entry points, including corrupt-row tolerance.
The Core verifier checks identical fixture files and retains complete initial
failure and final verification logs in `docs/validation/2026-11-14-tmdb-enrichment/`.
The exported protocol is documented in OcPlayer-Core's
`docs/tmdb-enrichment-contract.md`.

Repository memory/freshness, broader account/playback coordination and complete
release parity remain active. Windows execution is deferred by the user.

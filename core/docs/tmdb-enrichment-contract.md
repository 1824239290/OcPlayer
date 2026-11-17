# Shared TMDB enrichment contract

`tmdbEnrichment.*` is a synchronous, retained continuation protocol. Core owns
refresh authority, cache freshness, collection resolution, season iteration,
single-flight ownership and the four-worker batch window. The Apple actor
executes yielded database, injected client and task effects. Enabling Core
activates this path in production; explicit `useSharedCore: false` preserves the
independent native implementation for comparison and fallback when Core is absent.
A dispatched shared operation never replays writes in the native path.

## Flow lifecycle

`begin` accepts a caller-owned `flowID` and textual `payloadJSON` containing
`mode`, `configured`, optional item/series link/entity key/season number, members
and cancellation. Modes are `refresh`, `collection`, `season`, `bind`, `seasons`
and `contribution`. Each reply contains a step and either an effect with typed
arguments or an outcome. `advance` supplies that step and textual
`{value, cancelled}`. `close` releases abandoned state. Invalid or stale replies
leave the active continuation unchanged. At most 256 flows and 256 fetches, and
64 batches, are admitted; active work is never evicted to admit another caller.
`stats` exposes active flows/batches/fetches, started/finished counts and bounds.

Ordinary refresh checks the linked payload before rematching. Fresh payloads
skip work, including newly supplied provider IDs. For stale search links, a
valid movie/series provider ID can replace the guess; provider/manual links
retain authority. Confident matches (at least 0.85) attempt link persistence
before fetching, with native ignored-write-error semantics. Fetch success is
whether the selected payload is present after awaiting the task, so a failed
refresh with an existing stale payload still reports fetched and retains data.

Collections first reuse a fresh collection link/payload. Manual links retain
authority. Otherwise the first three valid movie provider IDs, in member order
including duplicates, are queried without writing member caches or falling
back to names. The first collection ID wins and a provider link is attempted
before fetching. Any successful member response without membership yields
noMatch; all failed member responses yield failed. Manual binding persists its
link even without configured credentials, then attempts fetching.

Season refresh uses only a parent TV link. Series enrichment reads that linked
TV payload, walks its stored season numbers sequentially (including specials),
and checks cancellation between seasons. No independent parent search is added.
The language is sampled at the same points as the native path: manual and direct
season fetches read the preference after prior effects, while ordinary flows
retain their selected language.

## Freshness and fetch ownership

The adapter converts date strings with the existing Foundation formatter and
provides parsed optional timestamps, current time and local start-of-today.
Core owns the resulting policy: empty seasons, unknown dates, today/future
releases and the strict seven-day last-release grace period count as airing.
Airing payloads are fresh while fetched age is strictly below 86400 seconds,
independent of ordinary expiry. Other payloads require current time below expiry.
The persisted lifetime remains the user preference so daily maintenance does
not delete usable airing-season data prematurely.

`fetch.claim` takes entity key and language and returns owner plus an exact
UInt64 ticket. Same-key callers join the actor's existing unstructured task;
waiter cancellation does not cancel the shared fetch. `fetch.record` records
the typed completion failure or clears it on success without releasing ownership.
Only the owner retires via `fetch.finish` after awaiting task completion.
Retirement cannot overwrite a newer completion's reported failure. `failure`
retains native notConfigured/unauthorized/notFound/rateLimited/http/transport/
decoding categories and their status/message/retry-after values.

## Batch lifecycle

`batch.begin` validates all items and dispatches up to four indices. Empty or
unconfigured batches emit no progress callbacks. Pre-cancelled batches still
admit the initial window, but child entry guards return notEntered and process
zero items. Unsupported kinds count as processed without an outcome category.
Movie/series outcomes update exactly one counter; series fetched/skipped
outcomes can add season counts.

`batch.complete` consumes one active index and updates progress without
refilling. The host awaits its progress callback before `batch.refill` samples
cancellation and optionally admits one replacement. Cancellation is sticky and
drains already-entered workers; no group cancellation is added. Final progress
clears currentTitle. `batch.close` releases abandoned state. Out-of-order worker
completion, invalid receipts, duplicate completion and premature refill are
covered through the actual C ABI.

## Response fidelity and verification

Every RustMetadataStore typed read now decodes directly from original ABI
response bytes, including individual/batch items, poster candidates, home/rail/
page snapshots, season/episode lists, local-progress results, technical file
information and TMDB payloads. Signed Int fields retain their complete range;
malformed payloads remain individual cache misses. Both GRDB-to-Core and
Core-to-GRDB writes are verified against the same database.

TMDB retries rate limits and transport failures, while HTTP 500/503 are final,
matching the native TMDbError policy. The shared HTTP pool is retained and other
domains keep their existing retry defaults. A domain-isolation Rust test and
actual HTTP request-trace comparison protect this distinction.

Ten Rust continuation tests, eight direct C ABI tests, six native differential
HTTP/date cases and a broad cache regression cover this cohort. The fixture
copies are checked by `Scripts/verify-macos.sh`. Initial failures and complete
passing records are retained under `validation/2026-11-14-tmdb-enrichment/`.
This closes the enrichment/batch coordinator scope; the full parity goal,
repository scheduling, account/playback orchestration and delivery work remain
open. Windows runtime testing is deferred as requested.

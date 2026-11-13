# OcPlayer Core FFI contract

The public ABI is the C header in `include/ocplayer_core.h`. Calls use UTF-8 JSON
strings and return heap allocated strings owned by the caller. Every returned
string must be released with `ocp_string_free`.

Persistent executor/connection-pool ownership, MoviePilot cookie isolation,
`moviepilot.clearSessions` and stream timeouts are specified in
[network-contract.md](network-contract.md).

`ocp_call` returns this envelope:

```json
{"ok":true,"code":0,"retryable":false,"message":"","data":{}}
```

The Apple SDK exposes `OcpResponse.decodeData` to decode typed `data` directly
from the original response bytes. Use this path for exact integer identifiers;
the older generic `JSONValue` projection represents numbers as Double. TMDB
response fields, signed request ranges and native wire decoding are specified in
[tmdb-wire-contract.md](tmdb-wire-contract.md).

Creating a core enqueues `core.ready`. Retained events are consumed in
FIFO order with `ocp_poll_event`; the function returns `1` for an event, `0`
when the queue is empty, and `-1` on an invalid call.

Notification delivery is bounded to 256 events and 1 MiB of serialized JSON.
Unconsumed `render.tick` and `playback.position` events keep only the latest
update of each kind. `moviepilot.searchProgress` keeps the latest complete
projection for each request ID. Replacements move to the tail, so retained
sequences remain ordered. Sequence numbers increase for every produced event;
coalescing and overflow can leave gaps. Hosts must not assume contiguous delivery.

At either limit, the queue evicts the oldest telemetry before a control or error
event. New telemetry is dropped if only control/error events occupy the budget;
control/error overflow drops the oldest retained event. A single event larger
than 1 MiB is dropped without discarding an earlier usable projection. Command
responses and snapshots remain available independently of notifications; final
MoviePilot search responses retain complete results even if an incremental
projection exceeds the budget. `diag.snapshot` exposes `core.eventQueue` with
`depth`, `bytes`, `capacity`, `byteCapacity`, `lastSequence`, `coalesced` and
`dropped`. Counters cover the lifetime of the core and polling releases queued
bytes. The existing `eventQueueDepth` field remains compatible.

Implemented commands include `ping`, `core.getVersion`, `request.prepare`,
`request.cancel`, `settings.get`, `settings.schema`, `config.export`,
`config.validate`, `config.import`, `diag.snapshot`, `diag.export`,
`settings.set`, `server.probe`, `server.login`, `server.loginQuickConnect`,
`server.quickConnect.initiate`, `server.quickConnect.state`,
`server.quickConnect.wait`, `server.list`,
`server.libraries`,
`server.markPlayed`, `server.markUnplayed`, `browse.home`, `browse.latest`,
`browse.resume`, `browse.nextUp`, `browse.random`, `browse.played`,
`browse.library`, `browse.detail`, `browse.chapters`, `browse.seasons`,
`browse.episodes`, `browse.similar`, `playback.info`, `media.segments`,
`media.subtitles`, `media.fileInfo`, `server.avatarTag`, `report.start`,
`report.progress`, `report.stopped`, `progress.save`, `progress.get`,
`danmaku.parseFilename`, `danmaku.canonicalMatchName`, `tmdb.match`,
`tmdb.search`, `tmdb.entity`, `tmdb.season`, `danmaku.load`,
`bangumi.subject`, `bangumi.search`, `bangumi.episodes`, `bangumi.calendar`,
`bangumi.collections`, `bangumi.updateEpisode`,
`server.imageURL`, `server.streamURL`, and playback lifecycle commands.
Anonymous authentication and Quick Connect request, polling, cancellation and
error semantics are specified in [media-login-contract.md](media-login-contract.md).
The lifecycle surface also includes `playback.position` for throttled native-player
position telemetry; it updates the same session timeline as `playback.seek` while
emitting a separate event kind.
MoviePilot commands use the `moviepilot.*` namespace and accept the `baseURL`
plus an optional `accessToken`: `moviepilot.login`, `moviepilot.request`, `moviepilot.currentUser`,
`moviepilot.mediaSearch`, `moviepilot.sites`, `moviepilot.torrentSearch`,
`moviepilot.download.add/list/start/stop/remove`, and
`moviepilot.subscription.list/add/update/delete/deleteByMedia/refresh/search`.
Search and list results preserve the server's raw JSON fields so platform
adapters can round-trip MoviePilot request objects without losing snake_case
keys. SSE torrent events are parsed incrementally and deduplicated by enclosure
(or title). `moviepilot.searchProgress` events contain the current full `items`
projection, `progress`, and `requestId`; hosts can poll while the command is
running. Unconsumed search updates are coalesced within each request. Hosts
sharing a core must route polled events to the matching request ID.
Network commands execute through the Rust HTTP clients and return the same
error envelope, including retryability classification. `progress.save/get`
use the existing `Media.sqlite` migration ledger when `data_directory` is set
in the core configuration.

`browse.library` accepts `parentId`, `kinds` (domain names such as `movie`),
`recursive`, `startIndex`, `limit`, `sort: {field, ascending}`, `watchState`,
and `searchTerm`. Sort fields are `name`, `dateAdded`, `year`, `rating`,
`runtime`, and `random`; watch states are `all`, `watched`, and `unwatched`.
Each home rail also has an independent command so one failed request does not
turn another rail into an empty success. `browse.home` returns per-rail failures.

`progress.save` takes `tenantId`, `itemId`, `positionSeconds`, optional
`durationSeconds`, `played`, `recordedAt`, `confirmedAt`, `completed`, and an
optional Swift-compatible `item` object for uncached media. Timestamps use Unix
**seconds**, retaining fractional precision for local progress. A write older
than the stored record is ignored and returns the retained record. The payload
in `local_progress` is a `MediaItem`, matching Swift, while timestamps and
completion remain table columns. Updating cached progress updates both its JSON
and projection columns without replacing metadata or its fetch timestamp.
`completed` describes reaching the end and is distinct from `played`.

HTTP retries are restricted to idempotent operations. Ordinary creation POST/PATCH
requests are not automatically replayed after transport or server errors. MoviePilot authentication
failures use `1503`, permission failures use `1504`, and invalid arguments use
`1002`. An adapter may fall back before dispatch when the library is unavailable;
after dispatch it must propagate failure rather than replaying the operation.
Token issuance and read-only search POSTs explicitly opt into safe retries.
`moviepilot.request` always executes once and returns raw status/headers/Base64
bytes; the caller owns retry and authentication. `moviepilot.login` optionally
accepts `validateUser:false` for token-only refresh. Complete arguments, failure
categories and native integration are in [moviepilot-contract.md](moviepilot-contract.md).

Playback transitions are `idle -> ready -> playing <-> paused -> stopped`.
Ready sessions may pause before their first play, matching a native engine
opened while paused. Ready/end notifications require an existing source.
`playback.open` requires a non-null `source`; `playback.play` and
`playback.pause` reject invalid states. `playback.setRate` accepts `0.25..=4.0`,
`playback.setVolume` accepts `0.0..=1.0`, and `playback.seek` requires a finite,
non-negative `positionSeconds`. `playback.position` has the same position
validation but is intended for throttled telemetry updates from a platform
player; it emits a distinct `playback.position` event. Contract errors use code
`1002`; invalid state transitions use code `1101`.
Optional `durationSeconds` must be null or a finite non-negative number; position
updates accept revised durations and clamp to that duration. Missing duration
retains the known value. Rates, volume and selected tracks belong to the session
and survive position and lifecycle updates. Track IDs must be strings or null;
null clears a selection. Invalid playback arguments leave session state intact.

Network commands block their calling worker. For cancellation, pass a unique
`requestId` in command arguments and call `request.cancel` with the same ID from
another thread. Call `request.prepare` before dispatch when cancellation can
race with worker startup. Every prepared request must eventually be dispatched,
even after cancellation, to consume its reservation. Cancellation returns `1003`
and drops the network future, including streaming reads and retry waits. It does
not undo mutations already accepted by a server. Request IDs are released when
the command finishes; duplicate concurrent IDs are rejected. The Swift async
wrapper performs this lifecycle and propagates `CancellationError`.
CPU-only commands remain synchronous; cancellation does not interrupt an
already-executing SQLite transaction or session mutation.
Surface calls record platform surface metadata only; the platform adapter owns
the actual renderer and player-engine binding.

`config.export` and `config.import` use schema version `1` and carry the
platform-neutral `CoreConfig`. Credential material remains owned by the host's
Keychain/Credential Manager integration. `diag.snapshot` (aliased by
`diag.export`) returns a versioned core/playback/config snapshot, event queue
depth, and a Unix timestamp; `redact` defaults to `true` and masks paths and
credential-shaped fields before export.


TMDB results retain snake_case domain fields. Detail results include genres,
cast (at most the first 20 entries), season summaries, original language,
IMDb ID, content rating, and collection ID. Missing localized title or overview
triggers one optional `en-US` fetch; only missing fields are filled. Optional
malformed fields and list entries are ignored, while a missing entity ID is a
decoding failure. Season numbers missing from the response use the requested
number, and each whole season is fetched in one request.
TMDB HTTP failures use `1600 + HTTP status` (401 = `2001`, 404 = `2004`,
429 = `2029`, 500 = `2100`); decoding failures use `1514`. The general
`retryable` field remains authoritative for transport/retry policy.

`bangumi.request` carries a complete HTTP exchange for the host-owned OAuth
credential lifecycle. Arguments are `url`, `httpMethod` (default GET), optional
`headers` and JSON `body`. The successful command envelope carries
`{status, headers, body}` even when the HTTP status is 4xx/5xx; `body` is the
unmodified UTF-8 response text. HTTP status failures therefore retain collection
lookup markers, gateway error codes, Retry-After and request IDs. Transport
failures use `1521` (timeout), `1522` (connect) and `1523` (other transport).
Cancellation uses the standard request ID lifecycle.

The same Rust retry policy owns this exchange: idempotent methods and the known
read-only POST `/p1/search/subjects` may retry; OAuth token exchange/refresh,
collection POST and episode PATCH do not automatically replay. Apple chooses
credentials/mirrors and handles generation checks. Signing out cancels in-flight
authorized Rust requests and rejects retired credential responses. After Core
has been selected, failure cannot fall through to URLSession.

Bangumi named commands use current OcPlayer p1 routes: subject detail is
`/p1/subjects/{id}`, search POST contains `keyword`, `sort: match`, and an integer
array `filter.type`, with `limit`/`offset` query parameters. Episode updates use
PATCH and accept an empty 204 response. `bangumi.subjectCollection` requires an
actual `username` (not `-`) and percent-encodes it as one path segment;
`bangumi.updateSubject` takes the complete JSON `body`. Both use v0 collection
routes. Named-command HTTP failures use `1600 + HTTP status`. Pagination and
integer arguments are checked before dispatch, including overflow.

The Rust media-server facade only replaces concrete production HTTP adapters.
Injected in-memory servers, fixed SDK clients and custom URLProtocol transports
remain caller-owned unless explicitly opted into the Core library for a test.

The complete shared Media.sqlite cache API is specified in
[media-cache-contract.md](media-cache-contract.md), including transactional
progress reconciliation, offline snapshots, expiry and clearing scopes.

Bangumi persistence and progress/sync-target policy are specified in
[bangumi-store-contract.md](bangumi-store-contract.md), independently of the
Bangumi HTTP exchange commands.

Shared media-server address policy, probe transport, failure codes and native
dynamic-profile integration are specified in
[endpoint-contract.md](endpoint-contract.md).

The shared request-chain and report reducer commands are specified in
[playback-contract.md](playback-contract.md). They preserve recovery across
platform engine replacement and reject stale source adoptions.

The `danmaku.exchange` raw gateway transport, route constraints, response and retry ownership are documented in [danmaku-contract.md](danmaku-contract.md).

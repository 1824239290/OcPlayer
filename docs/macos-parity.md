# macOS parity acceptance

The goal is the complete platform-neutral OcPlayer core with the macOS client
at the current OcPlayer feature level. Passing the checks below is evidence
for the covered behavior, not completion of that goal. Windows execution is
explicitly deferred by the user; Windows implementation/delivery is still in
scope. Native decoding, rendering, windows, audio sessions and credential storage
remain platform adapters.

Reference Apple checkout during this migration:
`/Users/jumusu/Documents/project/OcPlayer`.

## Acceptance scope and current evidence

| Area | Required behavior | Evidence and remaining work |
| --- | --- | --- |
| C ABI | JSON envelopes, owned strings, concurrent calls, events, cancellation, snapshots, surface lifecycle | Rust and Swift native-library tests pass. Event delivery now has count/byte bounds, per-request telemetry coalescing and control priority, verified under concurrent pressure and native C ABI polling. Full public-command argument coverage remains. |
| Jellyfin / Emby | Login/probe, address selection, libraries and all home rails, filtering, pagination, detail, seasons/episodes, images, subtitles, resource selection, reports, watched state | Public-info probes, anonymous password login, Quick Connect polling and endpoint selection/cache/generation policy now run in Core. Login retains native device identity, response tolerance, Emby/reverse-proxy prefixes and cancellation. The media facade resolves before dispatch, reads current addresses and native identity/preferences, switches reads after transport failure and forwards 401 reauthentication notifications. Both server flavors pass real HTTP failover/status/mutation fixtures, and probe connection reuse/timeout/cancellation are verified. Remaining platform transport fidelity and broad endpoint/data mapping coverage remain. |
| Playback | Existing native engine and surface quality, pause/resume/seek/rate/volume, track selection, progress, resource failover, end-of-playback, next episode and background behavior | macOS app builds; bundled Core passes local H.264/AAC playback and controls with synchronized Rust snapshots. Session rate/volume/tracks now survive timeline and lifecycle callbacks; revised duration, null track clearing and paused-open behavior are verified across the native ABI. Source recovery now runs in a shared request chain retained across engine replacement; report heartbeat/pause/terminal/natural-end decisions also run in Core. Native fixtures assert shared activation and cancellation/adoption guards. Engine event folding/EOF and stale-generation validation now run in Core, along with foreground resume decisions and mute/volume state. Actual native EOF and controller event integration pass. Complete source/track preference and recovery orchestration acceptance remains. |
| Metadata / persistence | Existing Media.sqlite schema, tenant isolation, cached metadata/home rails/pages, offline reads, local-progress conflict handling | The complete MetadataStore path now delegates SQL, transactional progress reconciliation, offline snapshots, TMDB cache and maintenance to Core. Bidirectional GRDB/Core fixtures and shared storage integration tests pass with Core activated. Retained memory projections, freshness comparisons, five refresh ownership maps and complete native cache opening/recovery now run in Core. Session-local progress reconciliation, confirmation/revision barriers, projection updates and shutdown state now run in Core. Home/detail/page pagination, home deduplication/restoration and detail/progress composition policy now run in Core. Full effect sequencing and failure/fallback assembly remain migration work. |
| TMDB | Mirror changes without restart, v3/v4 auth, searches, movie/TV/collection detail, per-field language fallback, whole seasons, mapping and cache policy | Rust-backed TMDbClient fixture verifies requests, fallback, fields, malformed optional entries, auth, status categories and no Swift replay. Entity/season cache, links, expiry and clearing now run in Core and retain GRDB compatibility. Native TMDbMatcher now delegates provider/parent identity, search fallback, ranking and Unicode character policies to Core, with independent native/C ABI differential coverage. Network DTOs now preserve exact signed integer fields through original-byte typed decoding and match native optional-array/numeric/encoding behavior in complete model comparisons. Refresh/collection/season/manual-bind flows, single-flight ownership and the complete four-worker batch now run in Core with real HTTP/native differential coverage, callback cancellation and exact typed cache reads. Repository scheduling and broader metadata acceptance remain. |
| Danmaku | Match/search/comments, hashes, filename/episode/alias matching, multi-source/cache/manual selection, cancellation, intro hints, overlay behavior | All four production gateway HTTP paths now run through Core with raw response and header fidelity. The macOS client uses the complete native automatic/manual/cache/intro flow, replacing the incomplete Rust shortcut. Native DanmakuKit 232 and direct C ABI 4 cases pass. Core now owns filename/canonical/episode/special parsing, Unicode comparable titles, candidate identity scoring and batch selection; differential and C ABI strategy fixtures cover these policies. Core also owns mapping/comment/saved-intro persistence, TTL, LRU and revision barriers with native file compatibility. Core now also owns intro detection, cross-episode learning persistence/consensus, manual-seek decisions and community/sibling interval aggregation. AniSkip/AnimeSkip/TheIntroDB request and response policies plus all four intro-provider HTTP transports now run in Core. AniList ordered identity resolution, negative-cache policy and native-compatible ID persistence also run in Core. Automatic/manual resolver scheduling, cache branches, payload conversion and intro precedence now run in a resumable Core flow. Manual-seek confirmation, event recording, consensus promotion and source-protected cross-episode propagation now run in one shared cache/learning Core operation. The standalone data loader now executes that same complete flow, including cache/ID stores, provider reads and production payload conversion. Broader end-to-end acceptance remains. |
| Bangumi | Public/authorized API, mirrors, OAuth refresh/generation safety, collections, episodes/progress, search/calendar, sync and persistence | Native BangumiAPIClient now dispatches all public, authorized and gateway OAuth requests through Core; complete raw responses, p1 routes, PATCH mutations, pagination, generation cancellation and single-flight refresh are covered by real Rust/Swift and C ABI fixtures. All BangumiDatabaseOperator entry points now dispatch to shared SQLite, merge, progress-window and sync-target policy; complete chapter sync uses one transactional replacement. Native account/scheduling lifecycle and broader end-to-end shared sync orchestration still need migration/audit. |
| MoviePilot | Login, silent relogin, raw media/torrent fields, SSE progress, downloads and subscriptions, cancellation/session retirement | All native HTTP paths now dispatch through Core, including first/token-only login and raw byte-preserving exchanges. Real C ABI/native fixtures cover login races, atomic credential commit, Cookie retention, shared refresh, mutation routes, raw fields and non-replay. Platform credential persistence, refresh coordination/generation and native notifications remain in the actor; broader shared account lifecycle orchestration remains. |
| Configuration / diagnostics | Existing settings/export/import compatibility, redaction, bounded events, actionable errors and native diagnostics | Core schema/diagnostic commands and redaction tests pass. Bounded event count/bytes and lifetime coalescing/drop counters are available in diagnostics. Full native settings mapping and aggregate diagnostic export remain. |
| Apple delivery | Reproducible library + adapter + embedded/signed app; clean-checkout build; macOS native regression | Host dylib and app embedding/signing verified. XCFramework script exists but all slices are not yet verified. Standalone Apple binding is now delivered in `bindings/apple/OcPlayerCore`, with source-equivalence and native-library package checks; release acceptance remains. Complete macOS AppTests and explicit Core activation tests now pass; the inherited macOS-only skips are recorded in raw output. |
| Windows | Stable DLL/C# binding and equivalent business API with native adapter | Binding exists; native adapter remains unfinished. Runtime testing can wait per user instruction. |

## Verified run: 2026-11-13

The anonymous media-login run is retained in
`validation/2026-11-13-media-login/`. Production Jellyfin/Emby login now keeps
one Core handle from public-info probe through authentication, preserving the
platform's stable device identity, live user-agent preference, reverse-proxy
prefix and Emby API prefix. Required token/user ID validation and tolerant
optional name/avatar parsing match native LoginResult.parse. Public-info probes
retain transient retries; password exchange and Quick Connect issuance never
replay. Shared polling owns its consecutive-failure reset/budget, timeout and
cancellation. Dedicated pairing errors 2401/2402 remain distinct from HTTP
410/411. Native credential/profile commit, UI session identity and injected
URLProtocol transport remain intact. See [media-login-contract.md](media-login-contract.md).

The final run passed Rust 79; OcPlayerCore 14, JellyfinKit 255, MetadataKit 306,
MoviePilotKit 124, BangumiKit 99 and PlaybackKit 96. The exported binding passes
14; direct C ABI fixtures pass Bangumi 4, network 7, MoviePilot 10 and media
login 10. macOS AppTests execute 1008: 989 passed, 19 platform skips, zero
failures. Core-disabled JellyfinKit executes 255: 242 passed and 13 explicit
library-only fixture skips. An independent 41-file Rust/source/schema copy
passes all 79 locked offline tests. The embedded/signed application passes
its playback controls and natural EOF with zero render/audio failures; this
run reaches ended at the clip's complete 5.066667-second duration. All 14
runtime Mach-O sections match the built library. Earlier failures, the initial
complete passing run and final verification are preserved. This closes the
stated anonymous login/pairing scope; the remaining acceptance rows stay open.

Complete raw output and machine-readable counts are in `validation/2026-11-13/`.
The Swift counts include XCTest and Swift Testing, with no skipped tests:
OcPlayerCore 4, JellyfinKit 240, MetadataKit 304, MoviePilotKit 108.
Rust workspace: 42 passed. Native macOS Debug application: build successful,
core embedded with architecture/export checks and ad-hoc signature verification.

The ten-second application selftest uses a generated twenty-second H.264/AAC
file and exercises pause, resume, seek, 2x/1x speed, and window resize. The log
shows the Rust session loaded from the application bundle, synchronized state
and position, hardware decode/zero-copy frames, and zero render/audio failures.
This verifies only that format and control path; it does not certify HDR,
subtitles, remote servers, every native engine, or the complete acceptance scope.

`Scripts/verify-macos.sh` automates the Rust checks, dylib build, six Swift
package checks and native AppTests, native app build and embedding. It preserves full raw output.

Shared network lifetime, connection pools, MoviePilot cookie isolation and stream
timeouts are specified and tested in [network-contract.md](network-contract.md).

The network ownership run is retained in `validation/2026-11-13-network/`:
Rust 77; native packages OcPlayerCore 14, JellyfinKit 245, MetadataKit 306,
MoviePilotKit 111, BangumiKit 99 and PlaybackKit 96, all passed. Seven direct
network C ABI cases and four Bangumi C ABI cases passed. The complete native
macOS run executed 1008 tests: 989 passed, 19 platform skips, zero failures.
MoviePilot's Core-disabled run passed 102 cases with nine library-only fixture
skips. An independent source copy including SQL schemas passed 77 locked offline
Rust tests; all 14 runtime Mach-O sections matched the embedded library. The newly
embedded application passed both playback controls and natural EOF with zero
render/audio failures. These checks close the stated network ownership paths;
the broader acceptance items above remain open.

The subsequent MoviePilot authentication run is retained in
`validation/2026-11-13-moviepilot-auth/`. First login, token-only silent issuance
and all low-level HTTP exchanges now dispatch through the same retained Core.
Thirteen new native fixtures prove default production activation, atomic
credential commit, login cancellation/retirement, Cookie retention, raw binary
fidelity, sole retry ownership, typed errors and concurrent refresh/fuse behavior.
Ten direct MoviePilot C ABI cases cover the raw/auth protocol and every named
download/subscription mutation route. A malformed-token fixture found and fixed
an old parser category that could retain expired credentials and resubmit a
password on a later call; both the failure and passing rerun are preserved.

The complete run passed Rust 77; OcPlayerCore 14, JellyfinKit 245, MetadataKit
306, MoviePilotKit 124, BangumiKit 99 and PlaybackKit 96. The exported binding
passes 14; Bangumi C ABI 4 and shared network C ABI 7 also pass. macOS AppTests
again executed 1008: 989 passed, 19 platform skips, zero failures. Core-disabled
MoviePilot passed 102 with 22 explicitly native-library fixture skips. The
independent Rust source/schema copy remains hash-identical and passes 77 locked
offline tests. Final embedded Mach-O runtime sections match the built Core;
both control playback and actual natural EOF pass with zero render/audio
failures. Native credential persistence, generation/refresh coordination and
notifications remain platform-owned; these tests do not close the broader shared
account/sync orchestration or other open acceptance rows.

## Bangumi migration verification

Bangumi now uses Core for the complete HTTP path, including gateway OAuth,
with credential persistence and refresh-generation ownership retained in the
platform layer. The Core preserves arbitrary domain fields and complete error
bodies. Named commands now use the same p1 subject/search and PATCH episode
routes as the current Apple client. Four direct C ABI fixture tests verify wire
routing, request shape, username escaping, empty 204 mutation responses, and
argument overflow rejection. Five native Swift fixture tests plus the existing
89 Bangumi package cases verify response parity, OAuth and single-flight refresh,
permission envelopes, mutation non-replay, task cancellation and sign-out.

Application regression discovered and fixed an unrelated integration boundary:
Core must not replace injected in-memory servers or custom/fixed native HTTP
transports. The full macOS AppTests run then executed 999 cases with 980 passed,
19 skipped and zero failed. Two subsequently added Core activation tests passed
with zero skips, proving that the test host loaded the requested Rust library
and retained injected server implementations. These counts are from XCTest
summary lines; they describe distinct checks, not a claim of release completion.

The production transport gate also checks Foundation's default protocol list.
macOS supplies built-in protocol classes on default/ephemeral configurations;
these must permit Core. Only a caller-injected protocol or fixed SDK client
retains the native transport. The same gate is shared by TMDB, MoviePilot and
the Jellyfin/Emby facade, and production configuration activation is asserted
in the native-library fixture checks.

The final unified verification runs the five domain packages with
`OCP_CORE_ENABLED=1`, direct C ABI fixtures, and the full native macOS AppTests.
The final application run executes 1001 tests: 982 passed, 19 platform skips,
zero failures. Its two Core activation tests do not skip. The standalone Apple
binding is source-identical to the application's adapter and passes the same
five native-library tests. Full final outputs are retained in
`validation/2026-11-13-bangumi/`.

## Shared media cache verification

All media-store operations now dispatch through Core when enabled, including
transactional item/rail merging, standalone progress, snapshot projection,
filtered pages, technical info, offline genealogy, tenant-scoped clearing,
TMDB entities/seasons/links and expiry maintenance. Read and write payloads use
the unchanged four-migration Media.sqlite schema. New native fixtures explicitly
prove production-factory activation, bidirectional GRDB/Core reads and atomic
batch rollback. Existing metadata/warehouse tests run against this path.

The complete unified run passed: Rust 47, OcPlayerCore 5, JellyfinKit 240,
MetadataKit 306, MoviePilotKit 108, BangumiKit 94; direct Bangumi C ABI 4 and
source-equivalent exported Apple binding 5. macOS AppTests executed 1001 with
982 passed, 19 platform skips and zero failures. The newly embedded/signed
application passed the ten-second H.264/AAC control selftest with Core loaded
from its bundle and zero render/audio failures. Original and final raw output
are retained in `validation/2026-11-13-media-cache/`. This does not close the
remaining acceptance items in the table above.

## Bangumi repository verification

Every BangumiDatabaseOperator persistence/query entry point now dispatches to
Core when enabled. The unchanged Bangumi.sqlite migration ledger and BLOB DTO
format remain bidirectionally readable with GRDB. Shared policy includes full
and slim metadata merges, authoritative collection clears, episode updates,
progress windows and sorting, counts/pagination, retry/cooldown selection and
single-snapshot synchronization targets. Chapter sync uses atomic replacement
and checks cancellation before committing remote results.

Both implementations now prune against the complete keep set, fixing deletion
of retained chapters when more than 900 IDs were split into NOT IN batches.
The five native-library repository fixtures cover automatic activation, both
database directions, 1905 chapters, fractional batch thresholds, watched-count
monotonicity, slim defaults and malformed JSON BLOB fallbacks. Four Rust store
cases additionally exercise replacement rollback and overlapping sync targets.

The final unified run passed Rust 51, OcPlayerCore 5, JellyfinKit 240,
MetadataKit 306, MoviePilotKit 108 and BangumiKit 99, plus direct Bangumi C ABI
4 and source-equivalent Apple binding 5. macOS AppTests executed 1001: 982
passed, 19 platform skips, zero failures. The embedded/signed application
passed the ten-second playback/control selftest from its bundled Core with
zero render/audio failures. All final output and retained earlier outputs are
in `validation/2026-11-13-bangumi-store/`. Full shared account/sync lifecycle,
playback authority and the other acceptance rows remain open.

## Event backpressure and session verification

Notifications now retain at most 256 events and 1 MiB of serialized JSON.
Render ticks, playback position and per-request MoviePilot search projections
coalesce to their latest unconsumed value. Overflow preserves control/error
events before telemetry; diagnostics expose depth/bytes, limits and lifetime
coalescing/drop counters. Polling releases queued bytes. Concurrent Rust stress
produced 50000 ticks across four threads and 1000 position updates, retaining
seven events with ordered sequences, complete controls and the latest position.
Byte overflow, oversized projections and separate search requests are covered.
The native Swift adapter also exercises coalescing and control overflow through
the exported C ABI.

Rate, volume and track changes now update the session reducer itself instead of
only its temporary projection. This fixes settings reverting on a position or
lifecycle callback. Duration telemetry is honored and validated, seek clamps
to revised duration, null clears tracks, and a ready source may pause before
play. Invalid duration/track arguments do not change playback state.

The complete run passed Rust 57, OcPlayerCore 7, JellyfinKit 240, MetadataKit
306, MoviePilotKit 108 and BangumiKit 99. Exported Apple binding 7 is the same
source/cases as the application's adapter; direct Bangumi C ABI 4 also passed.
macOS AppTests executed 1001: 982 passed, 19 platform skips, zero failures.
The embedded/signed application passed its ten-second real playback/control
selftest with zero render/audio failures. Complete output is preserved in
`validation/2026-11-13-events/`. Shared playback authority, media endpoint
switching and the remaining acceptance rows are still open.

## Shared endpoint verification

Address stickiness, pinning, unreachable/failure cooldowns, cache freshness and
generation checks now run in Rust. The existing native directory fixtures run
with shared policy explicitly asserted. New concurrency and profile-deletion
cases prove one probe round is shared and a removed address cannot return via
an in-flight result. The native fallback also receives the deletion-generation
fix and passes its own regression.

Production public-info probes run through Core with a persistent connection
pool and an executor owned by the Core handle. Shutdown completes before a
host can unload the library. The probe fixture observes five sequential calls
on the same TCP connection, checks identity/malformed payloads, and verifies
timeout/cancellation without URLSession fallback. Custom URLProtocol transports
and injected probe scripts retain their test transport.

The media facade now reads live profiles and resolves before async dispatch.
Jellyfin and Emby fixtures verify failure of the first address, selection of
the alternate and a successful Rust read there, preserved base prefixes and
native authentication identity, immediate user-agent changes, a single failed
mutation POST, HTTP status classification, 401 account notifications, and no
address reprobe on 503. Other network clients' connection ownership and full
payload/transport fidelity remain acceptance work.

`Cargo.lock` is now included in source delivery. An independent Rust source
copy with the schemas and locked manifest passes offline workspace tests,
proving compilation does not depend on the original workspace path or an
unshipped generated lockfile. Full final evidence is recorded in
`validation/2026-11-13-endpoints/`.

Final counts: Rust 63, OcPlayerCore 7, JellyfinKit 245, MetadataKit 306,
MoviePilotKit 108 and BangumiKit 99, all with zero failures/skips. Exported
Apple binding 7 repeats the same adapter cases; direct Bangumi C ABI 4 passes.
The native fallback run executes 245 with 241 passed and four library-dependent
skips. The independent locked/offline Rust source copy passes 63 tests.
macOS AppTests execute 1001: 982 passed, 19 platform skips, zero failures.
The embedded/signed application also passes its ten-second playback/control
selftest with zero render/audio failures. These checks cover this migration;
the outstanding acceptance rows remain part of the active goal.

## Shared request recovery and report verification

The application now uses Core for its source failover chain, text error
classification/capabilities, and report heartbeat/pause/terminal/natural-end
policy. The shared chain survives engine replacement, retains the ordered
failed-source history, limits replacements to three, and requires a fresh
request with the alternate's own session context. A pending replacement must
be acknowledged for the same Core generation; cancellation or a new play
invalidates it. Core-enabled native failure projections use recordOnly and
cannot request a second independent retry. Exhausting a short candidate chain
now produces its full failure summary; single-source errors remain unchanged.

The reporting coordinator executes shared decisions while preserving native
Start/Progress/Stopped ordering, timeouts and terminal callback guards. A
failed open retaining a tail position cannot trigger autoplay. Tests explicitly
assert shared activation, verify history across replacement and reject malformed
flow commands without mutation. See [the command contract](playback-contract.md).

The complete run passed Rust 70, OcPlayerCore 10, JellyfinKit 245, MetadataKit
306, MoviePilotKit 108 and BangumiKit 99, all without failures or skips. The
exported binding repeats the same ten adapter cases and direct Bangumi C ABI
four cases pass. macOS AppTests executed 1006: 987 passed, 19 platform skips,
zero failures. Forty-five focused native playback compatibility tests also pass
with Core disabled. An independent locked/offline Rust source copy passes all
70 tests. The bundled application passes its ten-second playback/control test
with zero render/audio failures. All raw output and counts are preserved in
`validation/2026-11-13-playback-flow/`.

Engine event folding/EOF, foreground rebuild/resume, mute/track preferences and
the other open acceptance rows remain required work in the active goal.

## Shared engine event verification

Core now owns native engine event generation, state/failure folding and error
identity. The existing PlaybackKit event fixtures explicitly assert shared
activation. A controller fixture proves its event reducer, request flow and
playback session share the same Core handle; actual cached state enters ended
or failed immediately and retains rate, volume/mute and track choices. Old
engine generations cannot mutate state, acquire a new generation or publish
notifications. Native event cancellation, track refresh, Observation publishing,
elapsed playing/buffering statistics, rendering and actual suspension remain
platform execution operations.

The current tail-EIO rule is preserved, including localized av_read_frame (-5)
matching, one-time folding and paired state-error suppression; a previously
visible real failure remains an error. Nil and empty error messages share the
reference client's deduplication key. Unknown-duration streams retain their
position and clearing a duration removes the old clamp. Telemetry cannot
replay an older engine phase over a newer pause control. Mute is stored
separately from the user's volume. Foreground intent/error/state decisions also
run in Core. A late request failure cannot republish old history after a new
play resets the native projection.

The final full run passed Rust 76, OcPlayerCore 14, JellyfinKit 245,
MetadataKit 306, MoviePilotKit 108, BangumiKit 99 and PlaybackKit 96,
without failures/skips. The exported binding repeats the same 14 adapter
cases; direct Bangumi C ABI four cases also pass. Final macOS AppTests
executed 1008: 989 passed, 19 platform skips, zero failures. An independent
locked/offline source copy passes all 76 Rust tests. Core-disabled playback
compatibility checks pass; exact executed/pass/skip counts are in summary.json.

The final embedded/signed application passes its control selftest and actual
natural EOF. The five-second H.264/AAC clip stops at approximately 4.933 seconds
and Core reports ended, with zero render/audio failures. Runtime Mach-O sections
of the embedded library match the built library; its install name and signature
account for whole-file hash changes. All raw output, earlier build/test runs,
code equivalence and machine-readable evidence are preserved in
`validation/2026-11-13-engine/`. The full goal remains active; remaining rows in
the acceptance table are not certified by these playback checks.

## Danmaku gateway and flow verification

The production client now retains Core across match, anime/episode search and
comments. Core returns complete bytes/status/headers with one network attempt;
the existing typed decoder and configured retry loop keep their semantics.
Native fixtures verify activation, injected-session isolation, complete comment
IDs/modes and match shift, cache headers, TCP reuse, typed business/HTTP errors,
exact retry counts and prompt cancellation. The macOS coordinator now always
uses its complete cache/search/manual/intro orchestration; the old Core fast
path that bypassed those policies has been replaced at the transport boundary.

DanmakuKit executes 232 tests with no failures or skips, including four native
Core fixtures. Four real HTTP C ABI checks pass. Full outputs, earlier compile
errors and final verification are retained in `validation/2026-11-13-danmaku/`.
See [danmaku-contract.md](danmaku-contract.md). Shared orchestration/persistence
for Windows and the other acceptance rows remain open.

The complete Danmaku verification passes Rust 79; OcPlayerCore 14, JellyfinKit
255, MetadataKit 306, MoviePilotKit 124, BangumiKit 99, PlaybackKit 96 and
DanmakuKit 232. Exported Apple binding 14 and C ABI Bangumi 4, network 7,
MoviePilot 10, media login 10 and danmaku 4 pass. macOS AppTests execute 1008:
989 passed, 19 platform skips, zero failures. The Core-disabled DanmakuKit run
passes 228 with four explicit native-library fixture skips. The newly embedded
and signed application passes pause/play/seek/speed/resize with zero render or
audio failures. Natural EOF reaches Core ended with the same native timeline;
at persisted 2x speed both end at 4.966666s for metadata duration 5.066667s.
That 100ms difference is recorded as an open rate/EOF acceptance issue, rather
than claiming exact complete-duration playback. Summary and all raw logs are
retained with this run. Build scripts also retain executable Git modes so
clean-checkout command invocations work.

## Shared danmaku matching verification

Filename parsing, canonical names, episode and special tokens, special keyword
classification, Unicode comparable titles, candidate identity scoring and batch
selection now run in Core in the production Apple client. Native policy bodies
remain independent for disabled-Core and differential comparison. Matching
retains the gateway's original candidate DTO by index, preserving IDs larger
than 2^53 and shifts larger than 32 bits. Global search order, threshold/ties,
final/season conflicts, special namespace preferences, OVA fallback and hard
movie-vs-episode identity gates match the existing native policy.

Native differential fixtures compare 960 filenames, 3840 scores, 270 keyword
boundary combinations, Unicode/episode/canonical edge cases and 1500 candidates.
Four additional direct C ABI policy cases cover ranking, identity gates, exact
large episode strings, validation and a 2000-candidate tie. Two failures involving
canonical trailing dots were found and fixed; the initial and first unified
outputs are retained. Final focused and complete package checks pass.

The complete run passes Rust 79; OcPlayerCore 14, JellyfinKit 255, MetadataKit
306, MoviePilotKit 124, BangumiKit 99, PlaybackKit 96 and DanmakuKit 237. Exported
Apple binding 14 passes; C ABI Bangumi 4, network 7, MoviePilot 10, media login
10, danmaku gateway 4 and matching policy 4 pass. macOS AppTests execute 1008:
989 passed, 19 platform skips, zero failures. Core-disabled DanmakuKit passes
228 with nine explicit native-library fixture skips. A hash-verified independent
44-file source/lock/schema/fixture copy passes all 79 locked offline Rust tests.
Raw output and source hashes are retained in `validation/2026-11-13-danmaku-policy/`.
Shared resolver scheduling, cache persistence and complete intro/load policies
remain open; see [danmaku-contract.md](danmaku-contract.md).

The newly embedded/signed application also passes pause/play/seek/speed/resize
from its bundled Core, with zero render/audio failures. Natural EOF reaches
Core ended at the same native position (5.033333s for metadata duration
5.066667s at 1x in this run). This 33ms gap and the earlier 100ms gap at 2x
remain open exact-duration engine/EOF acceptance items.

## Shared danmaku cache verification

Mapping/comment/saved-intro persistence, revision barriers, TTL and bounded LRU
memory now run in Core through each native DanmakuCache actor's retained handle.
Native JSON filenames, Swift reference-date timestamps and legacy mappings/hint
sources remain compatible. Corrupt mappings are preserved and retried; expired
memory rechecks disk freshness before removing a file. Six C ABI cases cover
these behaviors, disk failure, purge and exact 64-bit values. Three native
fixtures require Core activation and prove bidirectional files and UInt64.max
revision protection against stale writes.

The complete run passes Rust 79; OcPlayerCore 14, JellyfinKit 255, MetadataKit
306, MoviePilotKit 124, BangumiKit 99, PlaybackKit 96 and DanmakuKit 240.
Exported binding 14 and all 45 C ABI cases pass. macOS AppTests execute 1008:
989 passed, 19 platform skips, zero failures. Core-disabled DanmakuKit executes
240: 228 passed and 12 explicit library-only fixture skips. A hash-verified
independent 45-file source/lock/schema/fixture copy passes all 79 locked offline
Rust tests. The macOS app builds and Core embedding/signature checks pass. The
newly embedded/signed app also passes pause/play/seek/speed/resize controls with
zero render/audio failures.

Summary, source hashes and full raw output, including the initial inaccessible
Swift error-initializer compilation failure and its verified repair, are retained
in `validation/2026-11-13-danmaku-cache/`. See
[danmaku-cache-contract.md](danmaku-cache-contract.md). Shared resolver scheduling,
intro detection/learning/provider policies and the other acceptance rows remain
open; this cohort does not certify completion of the goal.

## Shared intro policy and learning verification

DanmakuIntroDetector, cross-episode learning/confirmation, learning persistence,
community interval selection and sibling aggregation now execute in Core on the
production macOS path. The native seek coordinator delegates eligibility and
confirmation decisions while retaining platform actions and async generation
handling. Native implementations remain independent comparison oracles.

Seven native cases compare 676 timestamp combinations and numeric/UID edges,
700 detector corpora, 3000 consensus decisions, 600 source/sibling comparisons,
seek/source boundaries, learning file interoperability and a 10000-comment batch.
Six direct ABI cases cover exact signed-64-bit IDs/reference dates, bounded 200
events, corrupt-file cached-empty recovery, write-through memory on disk failure,
source/cluster ties and validation. The representative batch measures about
141ms in native Debug Swift and 30ms including JSON/ABI with release Rust; this
records that configuration, not a general release-performance certification.

The complete run passes Rust 79; OcPlayerCore 14, JellyfinKit 255, MetadataKit
306, MoviePilotKit 124, BangumiKit 99, PlaybackKit 96 and DanmakuKit 247.
Exported binding 14 and all 51 direct ABI cases pass. macOS AppTests execute
1008: 989 passed, 19 platform skips, zero failures. Core-disabled DanmakuKit
executes 247: 228 passed, 19 explicit library-only fixture skips. A verified
independent 47-file final-source/lock/schema/fixture copy passes 79 locked offline
Rust tests.

An additional hex-float tail probe found a one-ULP parsing difference. The final
repair uses correctly rounded CRT conversion with an immutable C numeric locale.
Full app verification precedes that isolated repair; the final code then passes
locked Rust, all ABI, exported binding and complete DanmakuKit checks. The rebuilt
Core is embedded and signed in the same verified native app. Initial failures,
successful runs, precision evidence and final code hashes are preserved in
`validation/2026-11-13-intro-policy/`.

See [intro-contract.md](intro-contract.md). Intro provider transport/identity
resolution, complete shared async load/manual/promotion orchestration and the
remaining acceptance rows stay open. Windows runtime testing remains deferred.

The first bundled control probe's seek labels assumed a five-second clip,
although its actual calls seek to fractions 0.7 and 0.2. Source inspection
resolved the apparent seconds mismatch: for the 20-second file the expected
positions are 14 and 4 seconds. Labels now state 70% and 20%. The rebuilt and
re-signed app's final probe verifies both expected Core positions, pause/play,
rate changes and resize with zero render/audio failures. Original logs and the
initial summary remain preserved alongside the corrected verification.

## Shared intro provider verification

AniSkip, AnimeSkip, TheIntroDB and AniList production HTTP exchanges now use
retained Core clients. The first three also share request assembly, decoding and
interval policies. Seven native cases include 600 hint/clamp/timestamp corpora
and real HTTP calls for all four providers; six new exported ABI cases verify
request/response fidelity, Int64 variables, validation, pooling and cancellation.
Their native retry/error rules, lazy JSON string decoding and timestamp ties are
documented in [intro-provider-contract.md](intro-provider-contract.md).

The complete final verification passes Rust 83, exported Apple binding 14 and
all 57 ABI cases. Swift packages pass OcPlayerCore 14, JellyfinKit 255,
MetadataKit 306, MoviePilotKit 124, BangumiKit 99, PlaybackKit 96 and
DanmakuKit 254. AppTests execute 1008: 989 pass, 19 platform skips, zero failures.
Core-disabled DanmakuKit executes 254: 228 pass and 26 Core-only skips. A
hash-verified independent copy of 50 source/lock/schema/fixture files passes 83
locked offline Rust tests.

The signed app containing the final Core passes a ten-second control probe with
the twenty-second media file: pause/play, 70% seek to 14 seconds, 20% seek to
4 seconds and window resize. Its saved initial rate is 2.0 and the scripted
final rate is 1.0; render/audio failures remain zero. Complete raw results,
source hashes, initial failures and the final summary are retained in
`validation/2026-11-13-intro-providers/`.

The first full run used the Backup volume for Swift caches and failed on index
file renames. Local `/tmp` build output resolves that environment issue. An
existing source-scanning AppTest briefly stalled inside a system directory-open
call, then resumed and passed; its sample and full test log remain available.
Neither event is reported as a passing initial run.

Complete shared async loading/manual
selection/promotion, native idle/resource deadline and broader transport fidelity,
and the other acceptance rows remain open. Windows runtime testing is deferred.

## AniList identity and ID persistence follow-up

AniList lookup/search orchestration, title deduplication, candidate matching,
SHA-256 cache keys, positive/negative-cache plans and `aniskip-ids.json` now run
in Core. The macOS resolver and store share one handle and cached record map.
Injected transport fixtures retain Swift requests with shared policy; native
resolver/matching/storage paths remain independent comparison oracles. A
cancelled miss does not write a negative record. Native file compatibility,
legacy partial IDs, seven-day expiration, forced refresh, ordered fallbacks,
post-request clock sampling and failed atomic-write memory behavior are covered.

Eight new Swift cases include 900 Unicode title/key and 900 matching corpora.
They exposed a Greek final-sigma lowercase difference, now fixed to preserve
Swift behavior. Initial failures are retained alongside the passing rerun. Six
new C ABI cases independently exercise resolution, persistence and cancellation.

The complete verification passes Rust 87, exported Apple binding 14 and direct
ABI 63. Native packages pass OcPlayerCore 14, JellyfinKit 255, MetadataKit 306,
MoviePilotKit 124, BangumiKit 99, PlaybackKit 96 and DanmakuKit 262. Application
tests pass 1008 total: 989 passed, 19 skipped, zero failures. Core-disabled
DanmakuKit passes 262 total: 228 passed, 34 skipped, zero failures. A 52-file
hash-verified source copy independently passes all 87 locked/offline Rust tests.

The rebuilt signed application with embedded Core passes a ten-second playback
control smoke on a twenty-second clip: pause/play, 70% seek to fourteen seconds,
window resize, rate changes and 20% seek to four seconds. Rendering/audio
failure counters remain zero. Exact raw output and the saved initial rate are
recorded in `validation/2026-11-13-intro-identity/`. The application source scan
paused in system directory enumeration and resumed; its diagnostic sample and
complete passing run are preserved.

See [intro-identity-contract.md](intro-identity-contract.md). Complete shared
Danmaku async load/manual/promotion orchestration, transport deadline/TLS/redirect/
streaming fidelity and the broader parity rows remain active. Windows runtime
testing remains deferred as requested; this cohort does not complete the goal.

## Shared automatic/manual Danmaku loading follow-up

Production loading now drives a resumable Core flow for all four matching tiers,
per-query budgets, candidate ranking, mapping/comment-cache branches, rendering,
readiness/injection ordering and complete intro-source precedence. The host
executes requested file/network/cache/player effects; Core retains continuation
state and decisions. Only renderer payloads remain in the adapter between effects.
Native retry/typed HTTP wrappers retain injected-session behavior on the shared
network pool. Manual mode itself guarantees forced intro resolution, and Core's
omitted matching budget defaults to the native thirty seconds.

Core now also generates production overlay and Erika payloads with the native
numeric/Unicode field rules. Overlay time ordering is stable, Erika JSON retains
source ordering without synthesized IDs, and the count remains the raw comment
count. A revision change while awaiting readiness prevents injection into the
same UUID; cancellation after injection prevents later ID resolution or intro
cache persistence. Original control-flow/rendering implementations remain test
oracles, and all initial failures/discovery outputs are retained.

Six additional Rust and six C ABI cases cover complete eight-request waterfalls,
budgets, first/ranked matches, exact Int64 IDs, cache/source plans, cancellation,
stale replies, default semantics and bounded continuation admission. All 29
existing loading cases pass. Four new Swift cases compare 1200 numeric/Unicode
corpora across three formats, manual/cached control flow and the post-await races.

The unified run passes Rust 93, direct ABI 69 and exported Apple binding 14.
Native packages pass OcPlayerCore 14, JellyfinKit 255, MetadataKit 306, MoviePilotKit
124, BangumiKit 99, PlaybackKit 96 and DanmakuKit 266. After the portable-default
fixes, final Rust, flow ABI, DanmakuKit, exported binding and application regressions
also pass. Both application runs execute 1008 tests: 989 passed, 19 skipped and
zero failures. Core-disabled DanmakuKit passes 266 total: 228 passed, 38 shared-only
skips and zero failures. A 55-file hash-verified source copy independently passes
all 93 locked/offline Rust tests. Final source hashes and all raw logs are retained
in `validation/2026-11-13-danmaku-flow/`.

See [danmaku-flow-contract.md](danmaku-flow-contract.md). App learning-promotion
propagation and replacement of the legacy standalone loader remain open, alongside
metadata/account scheduling, transport fidelity, configuration/diagnostics,
Apple release delivery and Windows adapter implementation. The full goal remains
active; Windows runtime testing remains deferred as requested.

The final library is embedded and ad-hoc signed in the rebuilt application.
Its ten-second control smoke on a twenty-second clip verifies pause/play, seek
at 70% (fourteen seconds), resizing, rate changes and seek at 20% (four seconds),
with zero rendering/audio failures. Raw output, the saved initial rate and final
bundle hash are retained in the flow validation summary.

## Manual-seek learning verification: 2026-11-14

Confirmation, event recording, consensus promotion and cross-episode propagation
now execute in one Core operation sharing the service's live mapping/hint cache.
The app retains its diagnostic messages, playback request ID and source-ranking
boundary. Six new native workflow fixtures compare the independent fallback and
cover interval retention, exact Int64 identities/dates, protected sources,
duplicate/explicit anime mappings, same-episode evidence limits, one-time
concurrent confirmation and pre-entry cancellation. Three new C ABI cases cover
the complete path, preflight validation and failed-write memory retention.
See [intro-contract.md](intro-contract.md).

The affected regression passes Rust 93; direct C ABI intro 9, cache 6 and loading
flow 6; DanmakuKit 272 with zero skips/failures. The Core-disabled package executes
272: 228 passed, 44 explicit Core-fixture skips, zero failures. The rebuilt macOS
application executes 1008: 989 passed, 19 platform skips, zero failures. Binding
source equivalence, library embedding and deep signature verification pass.
The signed application passes the ten-second playback control selftest on the
twenty-second clip with zero render/audio failures. Complete raw output, source
hashes and failed preliminary checks are retained in
`validation/2026-11-14-intro-learning/`.

This closes the manual-seek learning coordinator scope. The legacy standalone
loader, metadata/account scheduling, transport fidelity, configuration/diagnostics,
Apple release delivery and Windows adapter implementation remain open. Windows
runtime testing remains deferred as requested.

## Standalone Danmaku loading verification: 2026-11-14

The exported `danmaku.load` command now drives the same retained flow used by
native automatic/manual loading. Its data delivery completes the full matching
waterfall, one-candidate selection, cache and intro-source decisions without
player readiness or injection effects. Shared typed gateway decoding, retry
ownership, payload conversion, exact 64-bit identifiers and cancellation/revision
checks replace the former standalone shortcut. The Apple loader exposes the
complete options and directly decodes the textual payload. See
[standalone-danmaku-contract.md](standalone-danmaku-contract.md).

Two new Rust flow cases, ten direct C ABI cases and three public Apple loader
cases cover cached/manual delivery, the eight-query waterfall, retry/fallback,
aliases and community consensus, learning/sibling precedence, exact identifiers,
native numeric decoding, budget outcomes and cancellation/stale writes. The
complete matrix passes Rust 95, direct ABI 82 and exported Apple binding 17.
Native packages pass OcPlayerCore 17, JellyfinKit 255, MetadataKit 306,
MoviePilotKit 124, BangumiKit 99, PlaybackKit 96 and DanmakuKit 272, with zero
failures. The macOS application executes 1008 tests: 989 passed, 19 platform
skips, zero failures. Core-disabled DanmakuKit executes 272: 228 passed, 44
explicit Core-fixture skips, zero failures. A 52-file hash-verified independent
source copy passes all 95 locked/offline Rust tests.

The rebuilt application embeds the new library and passes deep signature
verification. Its ten-second control selftest on a twenty-second clip confirms
pause/play, seek to fourteen seconds, window resize, rate changes and seek to
four seconds. The saved initial rate is 2.0 and final rate is 1.0; rendering and
audio failure counters remain zero. The application build reuses existing Xcode
DerivedData. Raw preliminary and final logs, source hashes and the bundled
library hash are retained in `validation/2026-11-14-standalone-load/`.

This closes the legacy standalone-loader scope. Metadata/account scheduling,
playback orchestration, native deadline/TLS/redirect/streaming fidelity,
configuration/diagnostics, Apple release delivery and Windows adapter
implementation remain active. Windows runtime testing remains deferred as
requested; this cohort does not complete the full goal.

## Shared TMDB matcher verification: 2026-11-14

Native matching now delegates provider/parent identity, search planning, original
title fallback, scoring and stable manual alternatives to `tmdb.matcher`.
The host retains its injected search effect. The original implementation remains
an independent oracle/fallback, and typed request/textual-result decoding
preserves exact Int identifiers at this boundary. See
[tmdb-matcher-contract.md](tmdb-matcher-contract.md).

Three Rust cases, four direct C ABI cases and four native differential cases
verify complete identity/query/ranking behavior. The native corpus includes
numeric, case, width, punctuation, whitespace and combining-mark scalars,
900 nine-candidate score/ranking sets, 90 complete injected-search flows and
provider/parent/disabled-search boundaries. It exposed and fixed numeric
grapheme suffix/year handling and character-boundary containment differences.
The preliminary ID-field and test-helper failures are also retained separately.

The final unified run passes Rust 98, direct C ABI 86 and exported Apple binding
17. Native packages pass OcPlayerCore 17, JellyfinKit 255, MetadataKit 310,
MoviePilotKit 124, BangumiKit 99, PlaybackKit 96 and DanmakuKit 272, with zero
failures. macOS AppTests execute 1008: 989 passed, 19 platform skips and zero
failures. Core-disabled MetadataKit executes 310: 301 passed, nine explicit
shared-fixture skips, zero failures. A hash-verified 54-file independent source
copy passes all 98 locked/offline Rust tests.

The rebuilt application embeds the current library and passes deep signature
verification. Its ten-second control selftest on the twenty-second H.264/AAC
clip confirms pause/play, seeks to fourteen and four seconds, resizing and rate
changes from the saved 2.0 to 1.0, with zero rendering/audio failures. Xcode
DerivedData is reused. Complete preliminary/final logs, source hashes and the
bundle hash are retained in `validation/2026-11-14-tmdb-matcher/`.

An independent run of the actual SDK JSON decoder confirms that TMDB's existing
network DTO adapter can round integers above 2^53 or fail near Int.max. This is
separate from the exact matcher boundary and is recorded in `network-id-audit.log`
as required follow-up. Enricher/batch scheduling, repository memory/freshness,
account orchestration, playback orchestration, transport fidelity,
configuration/diagnostics, Apple release delivery and Windows adapter work
remain active. Windows runtime testing remains deferred; the full goal remains
incomplete.

## Shared TMDB response verification: 2026-11-14

The network DTO exact-ID audit is now closed. The Apple SDK retains original
ABI response bytes and exposes typed `decodeData`; all shared TMDB DTOs use that
path. IDs, season/episode numbers, counts, runtimes and request years retain the
native signed Int range. Request year suppression for episode/season searches
and short-date parsing also match the native client. Core response projection
now follows native JSONObject optional-array, numeric, cast-prefix and content
rating behavior, plus its UTF-8/UTF-16/UTF-32 encoding/BOM rules. Corrupt numeric
overflows are discarded safely. See [tmdb-wire-contract.md](tmdb-wire-contract.md).

Two Rust cases, five direct C ABI cases and two public SDK cases verify exact
nested integers, signed requests, response encoding, malformed fields and
preflight rejection. Three native cases compare complete entity, season and
search models across 14 HTTP scenarios (42 full model comparisons), then check
malformed-wire errors and actual request paths. The shared fixture copies are
verified before native tests.

The final unified run passes Rust 100, direct C ABI 91 and exported Apple
binding 19. Native packages pass OcPlayerCore 19, JellyfinKit 255, MetadataKit
313, MoviePilotKit 124, BangumiKit 99, PlaybackKit 96 and DanmakuKit 272, with
zero failures. macOS AppTests execute 1008: 989 passed, 19 platform skips and
zero failures. Core-disabled MetadataKit executes 313: 301 passed, 12 explicit
shared-fixture skips and zero failures. A hash-verified 55-file independent
source copy passes all 100 locked/offline Rust tests.

The Debug application builds with reused Xcode DerivedData and embeds/signs
the current Core. Its ten-second selftest on a twenty-second clip confirms
pause/play, seeks to fourteen and four seconds, resizing and rate changes from
the saved 2.0 to 1.0, with zero rendering/audio failures. Full initial/final
logs, source hashes and library hashes are
retained in `validation/2026-11-14-tmdb-wire/`. Enricher/batch scheduling,
collection/repository orchestration, account and playback coordination,
transport fidelity, configuration/diagnostics, Apple release delivery and
Windows adapter work remain active. Windows runtime testing remains deferred;
this cohort does not complete the full goal.

## Shared TMDB enrichment verification: 2026-11-14

Refresh authority, collection member resolution, direct/manual binding, airing
freshness, series season iteration, single-flight completion/retirement and the
complete four-worker batch now execute in retained Core continuations. The host
executes database, injected HTTP and Swift task effects. Callback cancellation
stops refill while already-entered workers drain, and completion error records
remain independent of fetch retirement. Typed cache reads retain full Int ranges
across all nested snapshots; TMDB retries rate limits/transport while keeping
other HTTP failures final. See [tmdb-enrichment-contract.md](tmdb-enrichment-contract.md).

The unified run passes Rust 111, direct C ABI 99 and exported SDK 19. Seven native
packages pass 1185 cases, including MetadataKit 320. The final complete MetadataKit
rerun after test-only skip/fixture-teardown fixes also passes all 320. macOS
AppTests execute 1008: 989 passed, 19 platform skips, zero failures. Core-disabled
MetadataKit executes 320: 301 passed, 19 explicit Core-fixture skips, zero failures.
An independent 56-file hash-verified source/schema copy passes all 111 locked/
offline Rust tests. Complete initial failures, corrected runs and source hashes
are retained in `validation/2026-11-14-tmdb-enrichment/`.

The Debug app builds with reused DerivedData, embeds the current Core and passes
deep signature verification. Its ten-second control selftest on the twenty-second
H.264/AAC clip verifies pause/play, seeks to fourteen and four seconds, resizing
and rate changes from the saved 2.0 to 1.0, with zero render/audio failures.
Repository memory/freshness, account/playback orchestration, native transport
fidelity, configuration/diagnostics, Apple release delivery and Windows adapter
implementation remain active. Windows runtime testing remains deferred; this
cohort does not complete the full goal.

## Retained repository progress and composition: 2026-11-14

Session-local progress, confirmation/revision barriers, all projection updates
and shutdown now run in the retained repository Core. This includes explicit
owned final writes after shutdown and foreign disk confirmation. Pagination
recovery/append/replace, home restoration/deduplication, default-season/detail
planning and protected progress composition also run in that same handle.
Native hosts retain asynchronous effects and section failure/fallback assembly.
See [media-repository-progress.md](media-repository-progress.md) and
[media-repository-composition.md](media-repository-composition.md).

The final unified run passes Rust 129, actual C ABI 112 and exported SDK 19.
Seven native packages pass 1197 cases, including MetadataKit 332. AppTests execute
1008: 989 passed, 19 platform skips and zero failures. Core-disabled MetadataKit
executes 332: 301 passed, 31 explicit Core-only skips, zero failures. The
hash-verified independent source/schema copy passes all 129 locked/offline Rust
tests. Complete raw output, initial assertion/skip-helper failures and corrected
runs are retained in `validation/2026-11-14-repository-composition/`. The prior
progress cohort's full raw verification is retained separately in its original
validation directory.

The rebuilt Debug app embeds/signs the current Core, passes deep signature
verification and matches all fourteen runtime library sections. Without any
library or feature override, its ten-second H.264/AAC control selftest verifies
pause/play, seeks, resizing and rate changes with zero render/audio failures.
Full repository effect sequencing and failure/fallback assembly, account/sync,
playback preferences/recovery, transport fidelity, settings/diagnostics, Apple
release delivery and Windows adapter implementation remain active. Windows
runtime testing remains deferred; this run does not complete the full goal.

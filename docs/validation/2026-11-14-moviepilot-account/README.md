# Retained MoviePilot account validation — 2026-11-14

MoviePilot login/authentication generations, configuration receipts, single-flight
refresh ownership, the 15-second watchdog policy, refresh fuse and logout/clear
decisions now use retained `moviepilotAccount.*` policy on the HTTP Core handle.
Secrets, physical storage/revision locks, tasks, cookie retirement and UI
notifications remain platform effects. Initial adoption imports native counters
once and cannot switch account owners during native login/refresh work.

Initial login is authorized before the asynchronous platform credential commit
and revalidated after that handoff. Logout or a newer login prevents an old
successful storage operation from publishing a user or advancing the replacement
generation. The independent native implementation has the same guard.

The final unified run passes Rust 147, C ABI 133, exported Apple SDK 19 and seven
native packages totaling 1216. MoviePilotKit passes 129 without skips. Full macOS
AppTests execute 1008: 989 pass, 19 platform skips, zero failures. The Core-disabled
MoviePilot run executes 129: 104 pass, 25 explicit library-only skips, zero
failures. A hash-verified independent 65-file source/schema copy passes all 147
locked/offline Rust tests. Source/native input hashes remain unchanged across
verification. `summary.json`, input manifests and `verify-provenance.py` retain
the exact counts, source copy path and binary runtime-section hashes.

Four added Rust tests and five real C ABI cases verify concurrent claims, late
cleanup/commit, generation/configuration retirement, successful and rejected
refresh, transient/cancelled preservation, fuse/missing credentials, exact large
unsigned counters and transactional invalid input/overflow. Five new native cases
verify original-byte integer decoding plus sign-out/replacement during the real
credential commit in both Core and independent native modes. Existing real HTTP
fixtures continue to verify production selection, cookie/connection retention,
raw/named/late expiry sharing, token retry, malformed/rejected refresh and
notification counts.

`full-verification/` preserves complete raw output from all gates, including
Core-disabled regression, signature verification and bundled playback controls
plus natural EOF. The fourteen file-backed runtime Mach-O sections match the
built dylib; full library hashes differ after signing as expected. Deep signature
verification passes. Both H.264/AAC self-tests finish with zero render/audio
failures and no feature/library environment override. The natural-EOF clip reaches
`core=ended` at 5.133333 seconds. Products remain at
`/tmp/ocp-moviepilot-account-macos`; its Xcode DerivedData reuses the previous
verified tree. These debug checks do not certify remaining codecs/subtitles/HDR,
remote recovery or all Apple release targets.

Preliminary logs are preserved unchanged. `native-final.log` records four Swift
concurrency compile errors from sending the test instance into a MainActor
helper; making the helper static corrects those errors. `native-corrected.log`
records a fixture-only SIGTRAP: its mock URLProtocol callback inherited MainActor
isolation and ran on a URLSession queue. Moving that callback into a nonisolated
static function corrects the fixture; `native-race-final.log` and the unified
MoviePilot log pass all 129 tests. The orphaned fixture process was stopped to
release the failed test runner's inherited output pipe. No production failure
was hidden. `native-initial.log` and `abi-initial.log` preserve earlier passing
implementation checks.

See [the account contract](../../moviepilot-account-contract.md) and
[remaining project acceptance](../../macos-parity.md). The outer raw-request
retry/auth replay and named-command replay sequence still need retained flows.
Detailed Bangumi subject/progress and profile effects, broader playback/transport,
settings/diagnostics, Apple release and Windows adapter delivery remain active.
Windows runtime execution remains deferred; the complete project goal is active.

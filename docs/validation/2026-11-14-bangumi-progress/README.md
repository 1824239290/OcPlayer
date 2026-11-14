# Retained Bangumi subject/progress validation — 2026-11-14

The macOS subject and progress entry points now use retained bangumiProgress
flows on their database Core. Core sequences subject presence/fetch, tri-state
collection reconciliation, complete chapter paging/replacement, watching
preparation, single/batch progress writes, completion promotion, collection type
and rating writes, failure recovery and progress/membership notifications.
Native services retain HTTP, original-byte typed decoding, persistence and UI
adapters. SQL derives from retained state and applies under the receipt/retirement
lock. Account operation begin immediately retires database work; native fallback
writes validate a locked work revision inside their complete transaction.

The final unified run passes Rust 155, C ABI 149 across 24 suites, exported Apple
SDK 19 and seven native packages totaling 1227. BangumiKit passes 114 without
skips. Full macOS AppTests execute 1008: 989 pass, 19 platform skips, zero failures.
Core-disabled Bangumi executes 114: 90 pass, 24 explicit library-only skips,
zero failures. A hash-verified independent 67-file source/schema copy passes all
155 locked/offline Rust tests. The 67 Core sources, 755 native build/test inputs
and 49 gate/binding inputs remain unchanged. summary.json and complete manifests
retain exact counts and independent source location.

Four added Rust cases and nine public C ABI cases cover tri-state/state matrices,
complete paging and empty tails, signed integer IDs, SQL receipt non-replay,
transaction rollback, optimistic batch writes and failed readback, rating/type
validation, nonempty all-watched mains and confirmed-doing completion, promotion
failure, account/configuration retirement, idempotent cancellation and the 1024
active-flow bound. Six added native cases use real local HTTP and independent
GRDB comparisons to verify full paging, request/body order, large IDs, failed
watching/batch reads, completion after read failure, cancellation and late remote
receipts after clear/retirement without writes or notifications. A Core-disabled
case verifies every guarded fallback write rejects an old revision while current
writes still work. Existing full collection, episode sync, auth/network/database
and all other package regressions pass.

full-verification/ preserves complete raw gate output, disabled regression,
signature checks and bundled playback/EOF logs. Deep strict signature verification
passes. All fourteen file-backed runtime Mach-O sections match the built dylib;
full file hashes differ after signing. Both bundled H.264/AAC self-tests finish
with zero render/audio failures and no feature/library environment override.
Natural EOF reaches core=ended at the clip's full 5.133333-second duration. These
Debug checks do not certify all media formats, subtitles/HDR, remote recovery or
Apple release slices. Products remain in /tmp/ocp-bangumi-progress-macos; its
DerivedData reuses /tmp/ocp-moviepilot-flow-macos/DerivedData. verify-provenance.py
checks the frozen inputs, independent copy, counts and runtime section hashes.

Preliminary output is preserved unchanged. Initial Rust compilation exposed a
Counts name collision and three incomplete Option patterns; fixing the type name
and matches passes the complete workspace. The first native adapter build used
an unavailable cancellation property; explicit CancellationError/ignore checks
compile and pass. The initial ABI fixture used an unknown configure method;
using the actual settings.set and config.import commands passes retirement tests.
The report helper's first final-print still referenced the preceding MoviePilot
field name; correcting it makes the provenance command exit successfully. No
failed run is counted as a passing check.

See [the progress contract](../../bangumi-progress-contract.md) and
[remaining project acceptance](../../macos-parity.md). This closes the existing
subject/progress effect sequence migration. Complete account/profile effects,
broad live-account, playback/transport/settings acceptance, Apple release delivery
and Windows adapter completion remain active. Windows runtime testing is deferred;
the entire project goal remains active.

# Retained Bangumi sync validation — 2026-11-14

Collection paging, complete episode paging/replacement, sliding bounded episode
reconciliation and full incremental refresh now run in retained Core flows.
Core owns their sequencing, counts, failure policy, 300-second overlap, start-time
timestamp selection and job ownership. The database Core applies retained DTOs
with single-use SQL receipts under its state lock; clearing/reconfiguring the
account database retires pending writes and descendants. Login/profile/logout
operation begin also immediately invalidates the native database sync directory.
Transparent token refresh preserves the account identity and active sync scope.

The final unified run passes Rust 143, actual C ABI 128, exported Apple SDK 19
and seven native packages totaling 1211. BangumiKit passes all 108 with no skips.
macOS AppTests execute 1008: 989 pass, 19 platform skips, zero failures. The
Core-disabled Bangumi regression executes 108: 89 pass and 19 library-only skips,
zero failures. A hash-verified independent 64-file Rust/source/schema copy passes
all 143 locked/offline tests. Machine-readable counts, source manifests, binary
hashes and fourteen matching runtime Mach-O sections are retained in this folder.

Five added Rust cases and six actual C ABI cases verify paging, exact signed
identifiers/times, single-use receipts, failed-page transaction rollback,
empty successful episode replacement, sliding slots, child ownership,
account-operation retirement and conditional lifecycle behavior. `abi-final.log`
also asserts successful subject count for standalone reconciliation and an
out-of-order partial batch; full refresh retains its collection-count result.
Five native fixtures use real Core HTTP and independent native GRDB model
comparisons for complete records, multi-page reads, partial HTTP failures,
bounded concurrency, cancellation and writes arriving after account clear.
The exact Int64 episode identity also validates original-byte typed account/store
decoding. Production activation and identity preservation across real token
refresh are asserted alongside the existing transport/database/application tests.

Native Core-disabled pagination/grouping remains available and now checks the
database actor's revision before collection/episode writes. Timestamp adoption
uses the MainActor account-operation barrier. Physical credentials, transport
tasks, UserDefaults and notifications remain platform adapters. Detailed subject
loading, watched-state mutation chaining, complete shared account/profile effects
and broader live-account acceptance remain open in the project parity ledger.

`full-verification/` preserves complete raw output from the unified verifier.
Build products remain at `/tmp/ocp-bangumi-sync-macos`; Xcode DerivedData is reused.
The embedded app passes deep signature validation and bundled playback controls
(pause/play, seek, speed and resize) plus natural EOF, with zero render/audio
failures and no library/feature environment override. These checks certify those
H.264/AAC clips and controls, not all remaining media formats, subtitles, HDR,
remote resource recovery or release targets.

Preliminary logs are preserved unchanged. `abi-initial.log` records three fixture
queries using `id` instead of the existing `subjectId` protocol key; correcting
the fixture makes all six cases pass in `abi-corrected.log`. No runtime mismatch
was hidden. The remaining initial, guarded, compact and final build/native/Rust
logs show passing implementation checks as the full account-retirement path was
completed. See [the sync contract](../../bangumi-sync-contract.md) and the
[remaining macOS acceptance scope](../../macos-parity.md). Windows execution
continues to be deferred by the user; the complete project goal remains active.

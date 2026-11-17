# Complete repository workflow validation — 2026-11-14

All ten cached/refresh home/item/detail/episodes/page workflows, prefetch,
collection query construction and page/disk-query identity now run as retained
Core continuations. Core owns section error/fallback assembly and post-await
progress reconciliation; hosts execute typed effects and retain task handles.
The repository workflow migration scope is closed. Broader project acceptance
remains active in the parity ledger.

The final unified run passes Rust 134, actual C ABI 117, exported Apple SDK 19
and seven native packages totaling 1202. MetadataKit passes all 337 without skips.
macOS AppTests execute 1008: 989 pass, 19 platform skips, zero failures. The
native-only MetadataKit regression executes 337: 301 pass, 36 Core-only skips,
zero failures. A hash-verified independent source/schema copy passes all 134
locked/offline Rust tests. Counts, final binary hashes and fourteen matched
runtime Mach-O sections are in `summary.json`.

Five new Rust, five actual C ABI and five native differential tests run alongside
the existing complete repository/cache/progress/concurrency suites. They cover
single-use receipts, nil/memory/disk results, all-row timestamp minima, Unicode
identity, signed query windows, primary failure cleanup, cancelled waiters sharing
one request, auxiliary fallback, page publication/persistence progress races,
complete disk/memory model comparisons without network traffic and prefetch or
collection convenience behavior. The entire native app regression runs with
Core enabled and includes explicit Core activation tests.

`full-verification/` keeps complete raw output for all unified gates. Large build
products remain at `/tmp/ocp-repository-flow-macos`; Xcode DerivedData is reused.
The rebuilt app embeds the current Core and passes deep signature validation.
The ten-second bundled H.264/AAC playback selftest exercises pause/play, seeks,
rate changes and resizing with zero render/audio failures. The separate eight-
second test reaches natural EOF and Core ended state on a copied short clip,
also without render/audio failures. Neither run uses a library/feature override.
These tests certify those clips/control paths, not all remaining playback formats,
tracks, subtitles, HDR, remote servers or recovery orchestration.

All preliminary output is retained unchanged. `build-initial.log` records a Rust
helper returning an &str error instead of String; the corrected builds pass.
`native-cache-differential.log` records a test helper being called with an
unsupported seasonID argument; `native-cache-corrected.log` fixes only the fixture
construction and passes all cache comparisons. No runtime mismatch was hidden or
converted into a passing record. Core's production sequencing and response
boundaries are documented in [the workflow contract](../../media-repository-flow.md).

Windows runtime testing is deferred by the user. Shared account/sync, playback,
transport fidelity, settings/diagnostics and release/Windows delivery remain
broader requirements in [the parity ledger](../../macos-parity.md).

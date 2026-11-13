# TMDB enrichment validation — 2026-11-14

This cohort closes ordinary refresh, collection resolution, season refresh,
manual binding, series season iteration, single-flight completion/retirement and
complete batch scheduling. It also fixes typed cache integer fidelity and the
TMDB-specific HTTP retry policy. The complete goal remains active.

The unified run passes Rust 111, direct C ABI 99, exported Apple SDK 19 and seven
native packages totaling 1185. MetadataKit executes 320 with no skips/failures.
The macOS application executes 1008: 989 passed, 19 platform skips, zero failures.
Core-disabled MetadataKit executes 320: 301 passed, 19 Core-fixture skips, zero
failures. A hash-verified 56-file source/schema copy independently passes all 111
locked/offline Rust tests. The signed application passes the ten-second playback
control selftest with zero rendering/audio failures.

`full-verification/` holds the complete unified run. `metadata-corrected.log`
revalidates all 320 MetadataKit tests after the test-only skip/teardown fixes;
`disabled-corrected.log` is the corresponding complete native-only regression.
`independent-final.log` is the successful independent build. Source manifests
record the final Rust/schema and native source/test/fixture hashes. Binary hashes
are in `summary.json`; large build products remain in the documented /tmp path.

All preliminary logs are retained unchanged, including actual differences that
found the collection receipt naming, cached Int.max decoding and HTTP 500 retry
issues. Initial Swift test helper compilation failures are separate from passing
runtime evidence. `disabled-final.log` records XCTSkip incorrectly wrapped in
XCTUnwrap; `disabled-corrected.log` records the fix. `native-final.log` and
`native-sample.log` preserve an interrupted focused run held by Foundation
Process.waitUntilExit in asynchronous fixture teardown; the final full package
pass uses asynchronous fixture termination. `independent-initial.log` preserves
the first copy's omitted root schemas. No failure record is rewritten as success.

The complete protocol and covered behavior are specified in
[tmdb-enrichment-contract.md](../../tmdb-enrichment-contract.md). Windows runtime
execution remains deferred by the user. Broader parity rows remain open in
[macos-parity.md](../../macos-parity.md).

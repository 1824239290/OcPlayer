# Repository composition validation — 2026-11-14

The retained repository now delegates pagination recovery/append/replace,
home restoration/deduplication, default-season and detail planning, and protected
progress composition to Core. Existing local progress/revision/shutdown changes
are included in this unified regression. Native network/database effects,
section failure/fallback assembly and complete effect sequencing remain follow-up.
The broader project goal remains active.

The final unified run passes Rust 129, actual C ABI 112, exported Apple SDK 19
and seven native packages totaling 1197. MetadataKit passes 332 with no skips.
macOS AppTests execute 1008: 989 pass, 19 platform skips, zero failures. The
native-only MetadataKit run executes 332: 301 pass, 31 Core-only skips, zero
failures. The independent source/schema copy passes all 129 locked/offline Rust
tests. Source hashes and final counts are recorded in the JSON manifests.

Three new Rust, three actual ABI and three native differential tests cover
composition. Native comparisons cover 500 page arrangements, sixteen home
partial-success/failure/cancellation combinations, and six complete series or
collection flows. Missing kind hints and season numbers, canonical Unicode
identities, full signed integers, empty/duplicate pages, gaps, totals, offset
boundaries and existing protected playback progress are exercised. Request
counts are compared to the independent native implementation.

`full-verification/` retains every unified gate's raw output; large build products
remain at `/tmp/ocp-repository-composition-macos`. Xcode DerivedData is reused from
the previous verified run. The rebuilt app embeds the new Core, passes deep
signature validation and matches all fourteen runtime Mach-O sections with the
built library (whole-file hashes differ after signing). Its ten-second bundled
H.264/AAC selftest without library/feature overrides performs pause/play, seeks,
rate changes and resizing with zero render/audio failures. This validates that
clip and control path, not the entire remaining playback acceptance scope.

Preliminary records remain unchanged. `rust-initial.log` and `rust-second.log`
record assertion-only test errors involving JSON integer/Double comparison and
an incorrectly assumed empty repository after beginning progress. Passing Rust
results are in `rust-tests.log`. `disabled-tests.log` records a skip thrown inside
XCTUnwrap being misreported as failure; `disabled-corrected.log` fixes the test
helper by resolving its library path first. `native-corrected.log` revalidates
all new native differential tests after that test-only fix. Production behavior
was unchanged by these fixes. No failure record is presented as a passing run.

See [the composition contract](../../media-repository-composition.md) and
[the parity acceptance ledger](../../macos-parity.md). Windows runtime execution
remains deferred by user instruction.

# Media repository and cache recovery validation — 2026-11-14

This cohort moves the five memory projection buckets, LRU identities/limits,
freshness predicates, five refresh ownership maps and the complete disposable
Media.sqlite opening/migration/recovery/size/removal policy into Core. Native task
handles and network/database effects remain in Swift. The complete parity goal
remains active: home/detail/page effect composition and actor-local progress,
observation, revision and lifecycle coordination still need migration.

The unified run passes Rust 121, direct C ABI 105, exported Apple SDK 19 and
seven native packages totaling 1191. MetadataKit executes 326 without skips or
failures. The macOS application executes 1008: 989 passed, 19 platform skips,
zero failures. Core-disabled MetadataKit executes 326: 301 passed, 25 Core-only
skips, zero failures. The independent locked/offline Rust copy passes all 121.
The ten-second bundled playback/control selftest has zero rendering/audio
failures. Final measured gate counts and binary hashes are in `summary.json`.
`full-verification/` retains the complete unified run, including all direct C ABI
contracts, exported SDK, native packages and the macOS build/application tests.
The signed bundled application playback/control evidence is recorded separately.
`independent-tests.log` retains a hash-verified 58-file locked/offline Rust source
and schema copy. `disabled-tests.log` retains the native-only MetadataKit run.
The final native production/test/fixture source hashes are recorded separately.

Five new memory/ownership Rust cases include canonical Unicode identity; five
new database cases use actual files and migrations. Six C ABI cases include
32 concurrent claims, invalidation, typed wide integer payloads, preflight and TTL
boundaries, cache adoption/recovery and non-cache file preservation. Six native
cases include 6000 LRU operations over all buckets/four limits, native Unicode
key equality, page/episode identity, public projections, local progress,
waiter cancellation, actual WAL/migration/writer journal configuration and
unrecoverable parent paths. Tests assert that Core is active.

All preliminary records are preserved unchanged. They include a first build
failure, a run using an old dylib without the new database commands, a Swift
assertion compilation error, and the actual composed/decomposed Unicode
mismatch/duplicate-key crash. The corrected Core normalizes lookup identity
while retaining original keys and payloads. The initial journal-limit assertions
queried a reader connection (32768 in both implementations); the passing test
queries the production writer and verifies its native 8 MiB setting.

`native-initial.log` and `native-sample.log` retain the enrichment fixture's
asynchronous teardown stall. `initial-full-verification/MetadataKit-tests.log`
and `verifier-metadata-sample.log` retain the wire fixture's same blocking wait.
Both final fixtures terminate without blocking the cooperative executor.
The historical TMDB enrichment report claimed this cleanup was already applied,
but source inspection showed its blocking call remained. This cohort applies
and directly verifies the source correction. Historical reports remain intact;
only that earlier cleanup claim is superseded. Disabled-Core tests skip these
Core-dependent fixture bodies and are unaffected by the cleanup-only change.

`abi-initial.log` includes imported base-class tests accidentally discovered by
the first runner; the corrected runner and the final unified run select exactly
the six repository cases. Initial Rust logs precede the Unicode regression case;
the final/independent runs include it. No preliminary failure or interrupted run
is presented as completed passing evidence.

Reproduce the unified run with `Scripts/verify-macos.sh /path/to/OcPlayer /tmp/out`.
Build products and reused Xcode DerivedData remain in the paths in `summary.json`;
large binaries are not committed. Windows runtime testing is deferred by the user.
See [media-repository-contract.md](../../media-repository-contract.md) and
[macos-parity.md](../../macos-parity.md) for protocol and remaining parity scope.

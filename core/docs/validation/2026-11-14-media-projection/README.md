# Core file/subtitle projection parity — 2026-11-14

Core now owns media metadata source priority/isolation, track filtering and
complete file-info projection. The native facade consumes canonical payloads
and retains subtitle namespace/identity/download effects. Existing raw Items,
source/stream fields and plugin properties stay in the public replies. See
[the contract](../../media-projection-contract.md).

The explicit missing subtitle source no longer falls back. Direct-play source
priority now precedes direct-stream priority. File track titles retain Title
only; external subtitles keep DisplayTitle fallback. Frame-rate validity uses
the native Float32 semantics for Jellyfin and Double semantics for Emby,
including Float32 rounding, overflow and nonzero-underflow rejection. Strict
source/stream scalar decoding, native flavor enum handling, full HDR/track/file
fields and exact Int64 size are covered. Metadata requests never create a
playback session or send the selected source as a server filter.

| Final evidence | Result |
| --- | --- |
| Rust workspace and independent locked/offline source copy | 196 passed each |
| Public C ABI | 185 passed in 29 suites; 6 new projection HTTP cases |
| Exported Apple SDK | 26 passed |
| Seven native packages | 1281 passed; JellyfinKit 288 includes 8 new projection HTTP cases |
| macOS AppTests | 1013 executed: 994 passed, 19 platform skips, zero failures |
| Core disabled JellyfinKit | 288 executed: 273 passed, 15 Core-only skips |
| Core disabled app preparation/continuation/failover | 23 executed: 22 passed, 1 Core-only skip |
| Frozen inputs | 72 Core source + 781 native + 61 gate/binding files unchanged |
| SDK reference | 3 entity files unchanged at recorded SDK commit |
| Signed bundled app | Deep strict signature passes; all 14 runtime sections match |
| Actual bundled controls + natural EOF | Both processes exit zero; no rendering/audio failures |

Eight native HTTP cases compare explicitly activated Core and the original
native facades across both server flavors. Complete encoded file-info equality,
exact size, requested source and null ID behavior, codec/flag/title filtering,
Float32/Double bounds, basename variants, malformed scalars, flavor enums and
actual GET query/no-POST records are checked. Six C ABI cases independently
assert canonical output, retained plugin payloads and error/argument behavior.
Eight Rust cases exercise the shared policy and projections. The existing eight
nullable HTTP cases also pass alongside the new tests. Disabled runs exercise
native paths and do not claim Core activation.

Original failures remain in `preliminary/targeted`. The first test compiler error
used a nonexistent subtitle mediaSourceID property; assertions now compare the
actual download path. An early test indexed an empty track array after asserting
its count; that test-only crash was removed before collecting the safe baseline.
The safe old-adapter run `ocp-media-projection-native-before-3.log` records eight
tests with 79 failing assertions. Initial canonical comparison then exposed four
Jellyfin Float32 precision differences. The first boundary extension additionally
exposed native rejection of nonzero Float32 underflow (`1e-50`), which was fixed
before final freeze. All final targeted and complete gate logs pass. These
failures are historical evidence, not failures of the final implementation.

Final source copy: `/var/folders/07/f4r9g1zd0jbg1c2sh6b4vsg80000gn/T/ocp-media-projection-source-final-np1um205`. Cargo uses a shared warm target and locked/offline
dependencies; this proves independent source results, not a cold-cache build.
App DerivedData uses this run's dedicated non-symlink directory
`/tmp/ocp-media-projection-macos/DerivedData`. The first gate passed AppTests
but embedding failed after the older reused DerivedData target disappeared.
Its inputs/logs and artifact-failure details remain in
`preliminary/before-derived-data-loss`; the full gate was rerun with independent
DerivedData before final acceptance. The source and
ad-hoc signed embedded dylib whole-file hashes may differ; all 14 runtime
sections match. Natural EOF observes ended at 5.1s for the 5.133333-second
fixture. Complete process logs, metrics, hashes and verifier scripts are retained.

The selected subtitle-source and metadata projection defects identified in the
previous report are closed. Remaining product requirements include broad schema/
transport and public ownership/argument coverage, settings/aggregate diagnostics,
Apple release and all framework slices, and Windows adapter implementation.
Windows runtime testing remains deferred. The complete OcPlayer-Core goal stays
active; these checks establish the covered behavior rather than total completion.

# Retained playback track validation — 2026-11-14

The macOS controller now delegates complete existing automatic/manual track
selection, import/sidecar attachment, selected removal, display-name accounting
and identified subtitle batches to Core. Decoder operations, file/security scope,
source-generation validation, UI and successful playback-session mirroring remain
native adapters. The retained workflow and public effects are documented in
[the track contract](../../playback-tracks-contract.md).

The final consolidated result passes:

| Gate | Result |
| --- | --- |
| Rust workspace | 168 passed |
| Independent locked/offline source copy | 168 passed, identical 69 source/schema files |
| Public C ABI | 164 passed in 26 suites; 7 dedicated track cases |
| Exported Apple SDK | 21 passed |
| Seven native packages | 1243 passed; PlaybackKit 102, OcPlayerCore 21 |
| macOS AppTests | 1008 executed: 989 passed, 19 platform skips, zero failures |
| Core-disabled PlaybackKit | 102 executed: 100 passed, 2 explicit Core-only skips |
| Core-disabled subtitle AppTests | 18 passed; preference/removal controller classes |
| Signature | Deep strict codesign verification exit 0 |
| Runtime identity | All 14 runtime sections identical between built and embedded library |
| Bundled playback | Controls and natural EOF processes exit 0; render/audio failures 0 |

Seven added Rust cases, seven dedicated ABI cases and two SDK cases cover effect
order, signed ID limits, non-reused receipt IDs, malformed/stale acknowledgements,
reset, reentrant refresh, batch retirement, removal guards and field-trust/tie
behavior. Six added PlaybackKit cases exercise actual host call order and failures,
manual suppression, selected removal, current batches, reentrant engine callbacks,
audio mirroring only after success, and display-name Observation. The differential
case compares Core and the independent native selector across 3,600 combinations
of field trust, script contradictions, preferences, current choices, combining
suffixes and signed ID limits. Audio/subtitle numeric IDs may coincide.

Core-disabled PlaybackKit skips only the new Core/native differential case and the
existing shared-event-generation case. Its other tests and the 18 disabled App
controller tests pass. The disabled App configuration is generated from the final
build-for-testing xctestrun; both runner and testing environment dictionaries
explicitly contain OCP_CORE_ENABLED=0 and omit the library override. The constrained
test-without-building invocation uses that configuration. Its paths and target
selection are retained in disabled-app-environment.json and the raw logs.

The original unified gate is retained. Evidence review found that the new ABI
runner also discovered five imported account tests; its fixture import was changed
to a module reference. The runner was frozen again and its seven track cases rerun
against the same final dylib. Only that ABI log is replaced in the consolidated
result. Earlier mixed-suite output and its gate-input manifest are preserved in
preliminary/initial-gate. The earlier interrupted gate and SDK integer projection
failure are also preserved; typed effects now decode original wire bytes.

All 69 Core, 765 native and 53 final gate/binding hashes pass provenance verification.
The source copy is independent of repository build artifacts. Source/native inputs
remain unchanged throughout final validation; the corrected ABI runner is frozen
before its final invocation. Summary/manifests include the copied-source path and
runtime hashes. DerivedData is reused from the previous authentication cohort;
final build/test, embedding and signature logs belong to this source set.

The built app is /tmp/ocp-tracks-macos/DerivedData/Build/Products/Debug/OcPlayer.app.
Core library and feature environment overrides are removed for both app launches.
The control run lasts ten seconds and the EOF run eight seconds. Natural ended is
observed at 5.1 seconds for the 5.133333-second clip; no exact last-duration timestamp
is claimed. Process exit status and original rendering/audio metrics are retained.
verify-provenance.py checks the frozen inputs, copy, counts, final signatures,
process results and embedded runtime sections while these local artifacts remain.

Complete source preparation/recovery orchestration, broad decoder/media-format
coverage, native transport/settings/diagnostics and Apple release acceptance remain
active, as does Windows adapter implementation. Windows runtime testing remains
deferred by the user. This cohort completes the covered track flow, not the whole
project goal; see [the parity ledger](../../macos-parity.md).

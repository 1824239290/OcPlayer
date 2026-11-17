# Retained playback continuation and recovery intent — 2026-11-14

Core now retains the existing next-episode window workflow and supplies complete
manual retry/background rebuild intent. The App keeps full native objects and
active playback identity. Media retries reacquire playback info/source/session
context under a new request ID; local background rebuild retains its complete
request and identity. Existing macOS background noops stay unchanged.
See [the contract](../../playback-continuation-contract.md).

| Final evidence | Result |
| --- | --- |
| Rust workspace and independent locked/offline source copy | 182 passed each |
| Public C ABI | 175 passed in 27 suites; 11 preparation/continuation cases |
| Exported Apple SDK | 26 passed |
| Seven native packages | 1265 passed; JellyfinKit 272, OcPlayerCore 26 |
| macOS AppTests | 1013 executed, 994 passed, 19 platform skips, zero failures |
| Core-disabled JellyfinKit | 272 executed, 257 passed, 15 explicit Core-only skips |
| Core-disabled App continuation/collection/source failover | 23 executed, 22 passed, 1 Core-only skip |
| Signature | Deep strict verification exit 0 |
| Embedded library | All 14 runtime sections match |
| Bundled controls and natural EOF | Both processes exit 0; render/audio failures 0 |

Three new Rust continuation cases cover the six-item window, first-current anchor,
server order, specials, played candidates, empty/noop outcomes, malformed and
retired receipts, final-ready leases and saturated-capacity noops. Three recovery
cases cover manual 30-second threshold, original request fallback, source-position
trust during background rebuild, local reopen and argument validation. Immediate
noops consume no active flow slot even at the 128-flow bound.

Three SDK cases cover typed window effects, retry/rebuild plans and original-wire
UInt64.max generation/token and signed error-code decoding. All direct typed SDK
envelope decoders now use original bytes, including request-chain initialization,
engine-event snapshots and the loader's string envelope. Generic JSON APIs retain
their existing interfaces. The native wrappers keep their main-actor owner model;
this report does not establish general concurrent ownership of mutable SDK caches.

Four new native workflow cases verify complete opaque successor metadata, first
anchor/no-successor guards, original error types, task cancellation and retired
leases. Two new real HTTP cases cover Jellyfin/Emby continuation through the actual
endpoint, limit/startItemId and interstitial specials, preserving overview, season,
episode and resume metadata. Five App cases verify the 768-case recovery decision
matrix, complete active successor publication, stale old-window completion,
loading retry suppression and a fresh playback-info/session retry with retained
resume and exact source size. Public ABI recovery independently checks the same
768-case matrix plus separately reset wrong-mode/type/unknown-field arguments.

The initial full gate passed. API inspection then found additional direct typed
SDK initialization/event envelope decoders still using the Double projection.
These were corrected, frozen again and the entire gate rerun. Initial source,
manifest and complete raw logs are retained in preliminary/before-wire-completion.
An earlier ABI argument test reused its previous invalid mode; its inputs were
reset independently and all eleven cases rerun. The original runner/manifests/logs
are retained in preliminary/abi-argument-correction. The final complete gate uses
the corrected runner and final SDK. All production inputs stay unchanged during
the final gate. Final provenance verifies 71 Core source, 775 native and 57 gate/
binding inputs and the independent source copy; final documentation hashes are
also checked. Runtime identity compares Mach-O runtime section hashes.

DerivedData is reused through /tmp/ocp-preparation-macos/DerivedData. Fresh final
build/test, embedding and deep signing logs belong to this cohort. Disabled App
xctestrun is generated from final build-for-testing and explicitly sets Core off
in both runner/testing environments, omitting the library override. Both bundled
app launches omit Core/library overrides. Controls last ten seconds; EOF eight.
Ended is observed at 5.1 seconds for the 5.133333-second clip, without an exact
last-duration timestamp claim. Full process results and rendering/audio metrics
are retained. The verifier checks local source/copy hashes, counts, signatures,
process results and embedded runtime sections while local artifacts remain.

A final read-only A/B probe found an open server-data defect: MediaStreams: []
is accepted but MediaStreams: null is rejected for both server flavors. Native
Emby declares this array optional. The probe and complete output are retained in
audit-null-streams.py and open-null-streams-probe.log; fixing nullable source/data
mapping is the next audit action. This is outside the covered continuation and
recovery decision cases and remains required for full parity.

Broad decoder/media and recovery acceptance, remaining endpoint/transport and
public binding ownership/argument coverage, settings/diagnostics, Apple release
and Windows adapter implementation remain active. Windows runtime tests are
deferred by the user. The full goal remains active; this report closes the covered
continuation and retry/rebuild decision paths.

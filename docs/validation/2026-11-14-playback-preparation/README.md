# Complete retained playback preparation — macOS, 2026-11-14

Core now owns the existing complete leaf-resolution and source-negotiation policy:
collections/series, current home preference, episode selection, title/resume,
primary/alternate URLs, direct fallback and final presentation leases. The host
retains full native metadata/source/context objects and performs HTTP and decoder
presentation. Retired HTTP results cannot present or cancel a newer preparation.
The independent native path remains active when Core is disabled.
See [the contract](../../playback-preparation-contract.md).

Real HTTP tests exposed and corrected three existing transport/data gaps: episode
requests used a nonrecursive Items route instead of Shows/{seriesId}/Episodes;
continuation requests fetched/sorted a full list instead of preserving the server
window; typed facade responses lost Int64.max source sizes through Double
projection. Playback source HDR now comes from the first Video stream and stream
metadata survives serialization. No coarse VideoRange substitution is made.

| Final evidence | Result |
| --- | --- |
| Rust workspace and independent locked/offline source copy | 176 passed each |
| C ABI | 172 passed in 27 suites; 8 preparation/episode endpoint cases |
| Exported Apple SDK | 23 passed |
| Seven native packages | 1256 passed; JellyfinKit 266, OcPlayerCore 23 |
| macOS AppTests | 1008 executed, 989 passed, 19 platform skips, no failures |
| Core-disabled JellyfinKit | 266 executed, 252 passed, 14 explicit Core-only skips |
| Core-disabled preparation/failover AppTests | 18 executed, 17 passed, 1 Core-only skip |
| Deep strict signature | Exit 0 |
| Embedded runtime identity | All 14 runtime sections match |
| Bundled control and natural EOF runs | Both exit 0; render/audio failures 0 |

Seven new Rust preparation cases and one source-wire regression verify selection,
source ordering/duplicate IDs, original-error fallback, signed limits, bounded
leases, nonconsuming malformed/stale receipts and sequence exhaustion. Two SDK
cases verify exact UInt64 receipts and retired leases. Eleven new JellyfinKit
cases exercise full opaque native objects, fresh home after await, cancellation,
source contexts and both protocols over real HTTP. Episode fixtures verify full
ordering with missing/Int32.max numbers and continuation server order including
interstitial specials. URI parameter names are compared case-insensitively while
source/session values, authentication and absence of URL API keys stay strict.

The original full gate passed. Core-disabled fixture validation then found a
missing SDK-required UserData.Key and a repeated-parameter image-type encoding
assumption. These test-only inputs were corrected and frozen again; full enabled
and disabled JellyfinKit plus all eight preparation ABI cases were rerun against
the same final binary. The original manifests, fixture/test sources and initial
outputs remain in preliminary/fixture-correction. Other targeted failures,
including the incorrect build-script invocation, endpoint, integer and HDR
failures, remain in preliminary/targeted. Production Core/native inputs did not
change during the full gate. The final correction affects only the fixture and
its test assertions; final hash verification covers 70 Core, 773 native and 57
gate/binding inputs and the independent source copy.

DerivedData is reused through /tmp/ocp-tracks-macos/DerivedData. All final build,
AppTests, embedding and signature logs belong to this cohort. The disabled App
xctestrun is generated from a fresh build-for-testing result; runner and testing
environments explicitly set Core off and omit the library override. Both bundled
app launches omit Core/library overrides. Controls last ten seconds and EOF eight;
ended is observed at 5.1 seconds for the 5.133333-second clip. No exact last-frame
duration timestamp is claimed. Local paths, input hashes and process outputs are
retained in summary.json, manifests and raw logs.

Broad decoder/media and recovery acceptance, remaining native endpoint/transport
fidelity, settings/diagnostics and Apple release delivery remain active. Windows
adapter implementation remains in scope; Windows runtime tests are deferred by
the user. This report closes the covered preparation workflow, not the full goal.

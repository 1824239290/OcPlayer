# macOS/Core completion audit — 2026-11-14

The requested remaining main work 1 is complete for the currently exposed
macOS/Core business surface. Windows implementation and runtime acceptance are
handed to the user. This is a finite source and behavior audit; it does not claim
acceptance of every file, server version, network condition or Windows adapter.

The initial existing work was checkpointed as `7ab7749`. The final changes cover
public argument/request boundaries, Apple ABI ownership and JSON precision,
runtime preference ownership, compressed HTTP/SSE fidelity and MoviePilot's
newer current-user permission-map response. See
[the change audit](../../completion-audit.md) and the native checkout's
`Docs/SHARED-CORE-COMPLETION.md` for integration details.

## Source coverage

- [Production command inventory](../../public-command-inventory.json): 370
  commands, regenerated from routing source by
  [the scanner](../../../Scripts/audit-core-surface.py).
- [Native command audit](native-command-audit.json): all 70 literal command or
  family references resolve, including composed wrapper suffixes. This counts
  references, not unique methods or successful network operations.
- [Central settings ownership](settings-ownership.json): 43 entries.
  [Domain storage-key declarations](domain-storage-key-inventory.json) and
  [their ownership](domain-storage-key-ownership.json): 38 declarations, with
  overlap against central settings. UI, credentials, persistence, identity and
  device effects have explicit native ownership; shared runtime rules run in Core.
- All 29 runtime playback/subtitle/danmaku preferences use Core when enabled.
  The native test compares 18 full projections (522 getter comparisons), retaining
  the original disabled branch as the reference and requiring 29 successful Core
  resolutions for every enabled projection. Existing preference tests also run.
- The public boundary suite applies six invalid argument roots and seven invalid
  request IDs to all 370 commands: 4,810 pre-dispatch rejection cases. This proves
  boundary validation; it is not a substitute for domain state/SQL/HTTP tests.

## Final validation

The frozen gate ran the current source's Rust, ABI, exported Apple SDK and eight
native packages, then built the macOS app. A full AppTests retry and final embedded
playback checks completed the same source validation. Complete logs are retained
here; [machine-readable counts](test-counts.json) identify each summary source.

| Runner/scope | Unique cases established | Executed | Passed | Skipped | Failed |
| --- | ---: | ---: | ---: | ---: | ---: |
| Rust workspace | Not independently counted | 212 | 212 | 0 | 0 |
| C ABI, 33 Python suites | Not independently counted | 216 | 216 | 0 | 0 |
| Exported Apple SDK | Not independently counted | 41 | 41 | 0 | 0 |
| Eight native Swift packages, XCTest + Swift Testing | Not independently counted | 1,393 | 1,393 | 0 | 0 |
| macOS AppTests | 1,027 | 1,027 | 1,008 | 19 | 0 |

Counts are executions in the final run, from complete runner summary blocks.
The native package count includes Swift Testing's 89 Bangumi, 34 Metadata,
20 MoviePilot and 2 Playback cases. Exported SDK and native OcPlayerCore runs
contain overlapping cases and are not added into a claimed unique grand total.
AppTests' 1,027 distinct case names/outcomes independently match both the
all-tests summary and [xcresult summary](app-tests-xcresult-summary.json).
The 19 skips are existing macOS platform conditions; this audit did not run iOS.

AppTests evidence includes [the complete retry log](macos-app-tests-retry.log),
[the complete test tree](app-tests-xcresult-tests.json) and
[the original xcresult archive](AppTests-Retry.xcresult.zip).
Build, ABI fixture equivalence, SDK equivalence, Rust format and embedded
signature verification logs are adjacent. `frozen-gate.sh` records the exact
gate script that was executed.

The [frozen source manifest](frozen-source-inputs.json) contains 935 source,
script, test and configuration inputs across both repositories.
[The gate-time comparison](frozen-input-check.json) found no changed inputs.
After successful validation, one trailing blank line in the HTTP crate's TOML
was removed; [the byte receipt](manifest-trailing-whitespace-cleanup.json)
records both hashes. No TOML values changed. Final formatting, locked Cargo
metadata and Git source whitespace checks pass. Raw runner logs retain their
original whitespace.

## HTTP and actual service acceptance

[Transport tests](transport-fidelity-contract-tests.log) exercise a real local
HTTP server and an independently compiled URLSession probe. They compare decoded
gzip, zlib/deflate and Brotli bodies, retained headers/status/final URL, first-member
gzip behavior, rejected stacked encoding, compressed domain/probe paths, redirects,
corrupt-body handling without replay, immediate gzip SSE events, permission-map
extensions and an integer ID above JavaScript's exact-integer range. Each fixture
server and its worker thread closes when the test finishes.

[The live read-only run](live-readonly-results.json) passes all 22 checks:
Jellyfin 8, Emby 8, TMDB search 1, Bangumi calendar 1, MoviePilot reads 3 and
MoviePilot current-user field-type inspection 1. Saved credentials are read only
inside the runner; the report contains outcomes, timing and field types rather
than tokens, server URLs or response values. Emby initially timed out, the user
authorized skipping it, and the existing endpoint later recovered during the
bounded read attempts. No temporary Emby deployment was started. Remote writes
and OAuth renewal are covered by isolated fixtures rather than changing the
user's real accounts or library.

## Final bundled playback

[Five final playback runs](final-bundled-playback-results.json) use the app built
above, with the final optimized Rust library embedded, ABI exports checked and
the complete app signature verified. Core environment overrides are removed,
so the app's embedded enable flag/library discovery is exercised. Isolated
storage is enabled and every process exits automatically.

HEVC Main10/AAC MKV, VP9/Opus WebM, AV1/Opus MKV and a separate H.264/AAC MP4
reach Core `ended` naturally. H.264 also completes six control steps covering
pause, play, seek, rate changes and window resize, with matching Core snapshots.
The control run is not counted as an EOF run. All five report an attached surface,
positive decoded/rendered/audio frame counts and zero render/audio failures.
Complete selftest and process logs, file/library hashes and generation commands
are retained. Decoding/rendering remain the native engine's responsibility.
Earlier debug-library playback samples and original release artifacts retain
their own provenance; this audit does not relabel them as a new release.

## Preserved preliminary failures

`preliminary/` retains the first gate interrupted by editing its running shell
script, the complete earlier gate before HTTP fixes, and unsuccessful live
attempts that exposed credential encoding, URL normalization and the MoviePilot
permission-map mismatch. These are not counted as final passing executions.

The final gate's first AppTests attempt stalled in Foundation's source-directory
enumeration during an existing glass-layout test. The
[process sample](app-test-stall.sample.log), lsof report and original stalled log
are preserved. Only this audit's test process was stopped. An independent native
enumeration completed normally; a fresh full run then completed in about 78
seconds with all 1,027 outcomes. No test was changed or skipped to obtain the pass.
The precise cause of that transient filesystem stall was not established.

No extra deployment or test service remains running. Temporary playback and
fixture processes terminate; the user's existing application was not stopped.

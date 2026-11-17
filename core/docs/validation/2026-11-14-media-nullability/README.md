# Media DTO nullability and native projection parity — 2026-11-14

Missing/null media collections now preserve playable sources, sessions and
browse results. Core detail and similar items retain the native image hierarchy,
season identity, cast defaults, stable missing identity and nullable play state.
MAL now reads its own provider aliases rather than TVDB. Raw media arrays reject
malformed non-null containers. Emby segments derive from chapter markers, using
the legacy user detail route. Detail requests explicitly ask for native fields,
including People. See [the contract](../../media-nullability-contract.md).

| Final evidence | Result |
| --- | --- |
| Rust workspace and independent locked/offline source copy | 188 passed each |
| Public C ABI | 179 passed in 28 suites; 4 new media HTTP cases |
| Exported Apple SDK | 26 passed |
| Seven native packages | 1273 passed; JellyfinKit 280 includes 8 new HTTP cases |
| macOS AppTests | 1013 executed: 994 passed, 19 platform skips, zero failures |
| Core disabled JellyfinKit | 280 executed: 265 passed, 15 Core-only skips |
| Core disabled app preparation/continuation/failover | 23 executed: 22 passed, 1 Core-only skip |
| Frozen inputs | 71 Core source + 778 native + 59 gate/binding files unchanged |
| Signed bundled app | Deep strict signature passes; all 14 runtime sections match |
| Actual bundled controls + natural EOF | Both processes exit zero; no rendering/audio failures |

The native and public ABI HTTP tests use the same fixture; the macOS gate checks
fixture equivalence. Native tests compare explicitly activated Core and original
native facades for both flavors. Entire encoded item/file-info equality covers
image and season mapping; Int64.max source size and null-stream preparation
retain source/session identity. Missing/null/empty query and chapter containers,
invalid arrays, library filtering and Emby marker variants are covered. Disabled
runs use native paths and do not claim Core activation.

The earlier continuation report's `open-null-streams-probe.log` is preserved as
historical failure evidence. Original targeted compiler/test failures remain in
`preliminary/targeted`: initial native API assumptions, provider mismatch, raw
array behavior and ABI field-name assumptions were corrected before the final
freeze. `preliminary/before-detail-route` contains the first gate inputs/logs and
independent copy evidence. That gate was intentionally stopped with exit 143
after auditing the permissive fixture's missing endpoint/field checks. The
strict fixture rejects modern Emby detail paths and detail requests without
People. `ocp-nullable-strict-before-detail.log` demonstrates the old library's
failures under that fixture; final targeted and full gate logs pass.

Final source copy: `/var/folders/07/f4r9g1zd0jbg1c2sh6b4vsg80000gn/T/ocp-nullable-source-final-kikq8nf5`. The copy uses a shared warm Cargo target and locked,
offline dependencies; it is an independent source check, not a cold-cache build.
The app DerivedData reuses `/tmp/ocp-continuation-macos/DerivedData`. Source and
ad-hoc signed embedded dylib whole-file hashes may differ; their 14 runtime
sections match. Natural EOF observes ended at 5.133333s for the 5.133333-second
fixture. Full process outputs, metrics, hashes and verifier scripts are retained.

This closes the covered nullability, detail route and Emby segment defects.
Broad schema/transport, remaining ownership/argument coverage, settings and
aggregate diagnostics, Apple release/XCFramework slices and Windows adapter
implementation remain active. Windows runtime testing remains deferred. The
complete OcPlayer-Core goal is not marked complete by these results.

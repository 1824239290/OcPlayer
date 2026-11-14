# macOS/Core completion audit — 2026-11-14

This closes the requested macOS/Core audit and fixes for the current exposed
business surface. Windows implementation and Windows runtime acceptance are
handed back to the user. Native decoding/rendering, UI, device identity,
credential persistence, system services and preference storage remain adapters.

## Finite surface and ownership

`public-command-inventory.json` records 370 production command names and their
routing source. `Scripts/audit-core-surface.py` regenerates it from production
routing, excludes test modules and emitted event names, and records each
composition-root delegate. The public contract suite compares the checked-in
inventory against that source and applies six non-object argument forms and
seven invalid request-ID forms to every command: 4,810 negative boundary cases.
These cases verify pre-dispatch rejection; valid stateful/domain behavior is
covered by the existing domain/SQL/native suites, not inferred from empty calls.

The native call audit resolves all 70 literal command/family references, including
account and enrichment wrapper suffixes, to this inventory. Forty-three central
`SettingsKeys` entries and 38 domain storage-key declarations are classified in
the report. Domain declarations overlap the central registry. Credentials,
current/default profiles, device identity, updater state, poster-cache markers,
view ordering and platform feature gates remain native effects/input facts;
account/session generations, repository scheduling, matching, source selection,
progress reconciliation and diagnostics/backup policy run in Core.

## Fixed gaps

- Non-object command arguments and invalid/empty/NUL request IDs now receive
  nonretryable 1002 before state/network dispatch. Local strict DTOs consume
  request ID as envelope metadata; streamed search events keep their request ID.
- Apple asynchronous dispatch preserves original JSON tokens when adding request
  ownership. Explicit prepare/cancel controls bypass ordinary request reservation.
  This avoids precision loss and control commands reserving themselves.
- Typed event and snapshot reads use original ABI bytes, including UInt64.max.
  C-string validation rejects embedded NUL. Rejected ABI versions and incomplete
  native libraries release their loaded images; constructor errors retain the
  native last-error message.
- Core owns all 29 runtime playback/subtitle/danmaku preference defaults, range,
  valid-option and nullable-style decisions through `preferences.resolve` and
  `preferences.schema`. Foundation casts/UserDefaults writes and construction of
  decoder/render values remain adapters. The original native branch is retained
  for disabled-mode comparison. Eighteen complete preference projections compare
  all getters and assert that each enabled getter actually executes Core.
- Surface scale and render timestamps reject nonfinite values without changing
  surface state or emitting invalid telemetry.
- HTTP bodies now stream-decode gzip, deflate and Brotli while retaining native
  response headers, final URL and status. SSE delivery remains incremental.
  Independent URLSession comparisons also preserve its first-member gzip and
  rejected stacked-encoding behavior. Corrupt compression is not replayed.
- MoviePilot's public typed user path tolerates newer permission maps as a native
  ignored extension while preserving valid legacy lists and exact integer IDs.
  Its real current-user path now succeeds with the saved account.

## Acceptance boundaries

The live run uses saved server/account credentials internally and records only
method, outcome, timing and field types. Jellyfin and Emby browse/detail/file,
segment and subtitle reads, TMDB search, Bangumi calendar and MoviePilot read
operations pass. The saved Emby endpoint initially timed out and later recovered;
no additional deployment was needed. Account writes, OAuth renewal and remote
mutations use isolated HTTP and native fixtures, preserving the user's real
account/library state.

Actual bundled macOS playback covers HEVC Main10/AAC MKV, VP9/Opus WebM and
AV1/Opus MKV with Core natural-end state and zero render/audio failures. H.264/AAC
covers pause/play, seek, rate and resize, plus a separate natural-end run.
Decoder support remains the native engine's responsibility. These finite samples
are acceptance evidence, not a claim about every codec/file/network combination.

See [the complete report](validation/2026-11-14-completion-audit/README.md) for
final counts, unchanged-input receipts, complete logs and preliminary failures.
Earlier Apple release artifacts remain tied to their original validated commits.

# Shared playback track workflow

`PlaybackController` now delegates its complete subtitle preference and track
operation flow to `PlaybackTrackWorkflow` in PlaybackKit. With Core enabled, the
workflow owns a retained `playbackTracks.*` state machine. Native decoder calls,
file import/security scope, source-generation checks, UI and successful session
mirroring remain host adapters. With Core disabled, the independent native policy
continues to execute the same host operations.

Core retains manual subtitle protection, external display names and subtitle
batch identity. Import executes add → acknowledge returned track ID and name →
select → acknowledge manual protection. Failed selection preserves the imported
name and leaves automatic correction available. Selected removal clears the name
and manual protection only after decoder success. Failed audio selection never
updates the playback-session mirror. Reset clears policy state and retires old
receipts; every effect receives a non-reused ID, including the second import step.
A stale batch completion cannot close the newer identified batch.

Subtitle scoring retains the existing language/script vocabulary, field trust,
tie handling, unknown-language default, and all-external fallback. Audio and
subtitle numeric IDs may coincide. Typed SDK responses preserve Int64 limits
and unsigned effect IDs by decoding original wire bytes. Unicode matching keeps
extended grapheme clusters, including combining suffixes. External-name changes
publish through Observation so menus update after Core acknowledgements.

PlaybackKit tests cover imports and engine failures, selected removal, current
batch cleanup, manual suppression, reentrant refresh, failed audio mirroring,
display-name observation, and 3,600 Core/native differential selector cases.
Existing controller preference/removal tests and native decoder tests remain in
the full macOS AppTests gate. Core-disabled regressions verify the independent
path; the differential test explicitly skips when Core is disabled.

The Core contract is `docs/playback-tracks-contract.md` in OcPlayer-Core.
Authoritative validation inputs, raw outputs and signature/runtime checks are
retained in its `docs/validation/2026-11-14-playback-tracks/` report. Broader source
preparation/recovery orchestration and media/release parity remain active work.

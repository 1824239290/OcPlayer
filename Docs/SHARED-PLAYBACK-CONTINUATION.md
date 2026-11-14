# Playback continuation and recovery intent

`playbackPreparation.start` accepts `mode: "next"` to retain the existing complete
next-episode lookup. The host retains full native items under opaque keys and
executes the returned `episodeWindow` with seriesId, startItemId and limit 6.
The response is an item projection array. Core finds the first current-item ID in
server order and selects the first following item whose season is not zero. It
does not guess if the current ID is absent, resort the server window, reject
already played candidates or replace the native next-item object with a reduced DTO.

Movies, missing series IDs, specials and windows without a successor finish
without a ready effect. These immediate noops consume no active lease slot, even
when the 128 active-flow limit is full. A selected successor uses the same leased
`ready` effect and exact token/sequence acknowledgments as initial preparation.
Malformed responses cannot consume the window. Invalidated or cancelled late
results cannot publish a successor or retire a newer request. Resolver errors
preserve native types; App logs window failures without failing current playback.

The App's active playback identity and task cancellation remain host guards at
publication. New playback cancels old lookup; stale lookup completion cannot
replace the successor for a new item. The Core-disabled path retains an independent
implementation of the original window and special-selection rules. Both server
flavors use their real episode continuation endpoints and preserve server order.

`playbackFlow.recoveryPlan` accepts a typed object with mode (manual/background),
loading, hasPlayback, hasRequest, hasMediaItem, hasLoadedSource and nullable
currentPositionSeconds/requestResumeSeconds. Positions must be finite. Unknown
modes/fields and wrong argument types fail with 1002. It returns action and
nullable resumeSeconds without mutating the active request chain.

| Situation | Action and resume rule |
| --- | --- |
| Manual retry while loading | none |
| Manual retry without a media item | retryLast; native decoder retains its last request |
| Manual retry with a media item | reprepare; current position at least 30s, otherwise request resume |
| Background recovery without playback/request | none |
| Background recovery with a media item | reprepare; trust loaded-source position, including zero; otherwise request resume |
| Background recovery for local/direct URI | reopen with the same native request ID and complete request/context/security scope |

Reprepare calls the complete Core preparation path, obtaining new playback info,
source/session context and a new playback request ID. Reopen retains native URI,
auth header, security scope, context and request identity while replacing the
failed decoder. Direct manual retry uses the original decoder retryLast path.
The host still owns decoder calls, loading UI, reporting, diagnostics and Danmaku
restarts. macOS background transitions remain the existing noops; no new background
behavior is introduced. Core-disabled recovery preserves independent native rules.

Recovery/event SDK initialization, recovery plans, request-chain and engine-event
snapshots and preparation receipts decode original wire bytes. The remaining
direct typed envelope decoders use the same original-byte path. This retains UInt64.max generation/token values without a
Double projection. Main-actor native owners retain their existing ownership model.

Verification includes bounded windows, first-current anchoring, opaque metadata,
typed errors, task cancellation, retired leases, capacity noops, retry threshold,
background position trust and fresh App retry sessions. A 768-case decision
matrix (two modes, five booleans, six current positions and two fallback positions)
checks the public ABI and App paths. Real HTTP continuation is covered for Jellyfin
and Emby, including specials and full successor metadata. Broad decoder/recovery,
transport and release acceptance remains tracked in the parity ledger.

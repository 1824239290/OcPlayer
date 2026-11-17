# Shared playback request and report policy

The decoder, render surface, security-scoped file leases, audio session and
ordered HTTP tasks remain platform execution adapters. `ocp-session` owns the
request-chain decisions used by the macOS application. A chain outlives an
engine: changing sources creates a new platform request and reporting context,
without clearing the failover count or failure history.

## Request chain

All calls use the standard C ABI JSON envelope. The playback request identity
is `playbackRequestId`, independent of the cancellable HTTP `requestId` namespace.
Each Core handle has one flow. Commands are serialized with the Core state lock.

- `playbackFlow.begin`: nonempty `playbackRequestId`, optional string/null
  `sourceId`, `alternates: [{id, hasSessionContext}]`. Starts a user-selected
  request chain, increments its generation and clears history/counts.
- `playbackFlow.snapshot`: current request/source, active status, generation,
  failoverCount, ordered attempts, remaining alternates and pendingSourceId.
- `playbackFlow.failed`: current `playbackRequestId`, `kind`, `hasItem`.
  Returns `action`, `reason` and the complete snapshot. `action` is `ignored`,
  `none`, `manual` or `switch`. Only a current, active request without a pending
  replacement can record a failure. Repeated/stale callbacks do not add attempts.
- `playbackFlow.adopt`: `fromPlaybackRequestId`, `generation`, fresh
  `playbackRequestId`, `sourceId`. Acknowledges only the pending candidate for
  that chain generation. Returns `accepted` and the snapshot. The alternate is
  consumed and history/counts survive. Reusing the previous request identity,
  adopting the wrong source or adopting after invalidation returns false.
- `playbackFlow.invalidate`: deactivates the chain, removes the pending source
  and advances generation. A queued source replacement cannot revive it.

`kind` is one of `network`, `format`, `auth`, `server`, `aborted`, `unknown`.
All failures are recorded before the decision, including auth/cancellation.
Auth and cancellation stop automatic replacement. Other categories try the
first remaining alternate, at most **three replacements**. A missing media
item prevents replacement. A candidate without its own session context produces
`manual`; the old reporting context must never be reused for a new source.
A single-source failure preserves its original error. Exhausting a multi-source
chain or hitting the limit produces `manual` with the ordered failure history.
Terminal decisions deactivate the chain. A new explicit play/retry starts anew.

The snapshot count counts reserved replacement attempts, including a candidate
that lacks its session context, matching the existing macOS decision ordering.
The host retains the alternate's URI, headers and complete session context; it
checks both native generation and Core adoption before presenting the new request.

`playbackFlow.classify` accepts `message` and returns `kind`, `isRetryable` and
`allowsSourceFailover`. Cancellation has highest text-match priority, followed
by network, auth, format, server and unknown. `playbackFlow.capabilities` takes
`kind` and additionally returns `maximumSourceFailovers`. Platform NSError
codes and localized display labels remain platform translations.

`playback.failed` accepts optional `recordOnly: true` to update the engine
projection without requesting recovery. The macOS controller uses this when
its AppModel owns shared source recovery. Its OcpPlaybackSession and
OcpPlaybackFlow share one Core client; preparing a new native engine retains
that client. Legacy standalone `playback.failed` retry behavior remains available
for existing callers that have not adopted the request-chain contract.

Invalid flow command arguments return code 1002 before mutating the chain.
Core-enabled source recovery propagates a policy error to diagnostics and stops
that decision; it does not replay native automatic recovery. The feature-disabled
native compatibility path remains available.

## Report decisions

`playbackFlow.reportStep` is a pure reducer. It accepts:

```json
{
  "snapshot": {
    "state": "paused",
    "positionSeconds": 30,
    "durationSeconds": 100,
    "sourceOpenFailed": false
  },
  "mode": "heartbeat",
  "ticks": 0,
  "reportedPause": false,
  "everyTicks": 10
}
```

States are `active`, `paused`, `stopped`, `error`; modes are `heartbeat`,
`background`, `inspect`. Position and duration must be finite and nonnegative;
`everyTicks` is a positive integer. Returns `action` (`none`, `progress`,
`stopped`), next `ticks`, next `reportedPause`, and `reachedEnd`.

A heartbeat increments ticks, reports once per paused interval and returns to
periodic progress after resume. Backgrounding reports immediate progress or
finalizes a terminal source. Inspect leaves counters unchanged and only computes
natural completion. Only a clean stopped source of known positive duration
within two seconds of the end is complete. Errors and failed opens never count
as natural completion, even if the retained position is at the end.

The native reporting coordinator executes these decisions while retaining its
Start → Progress → Stopped task ordering, session-generation checks, terminal
callback deduplication and timeout behavior for uncooperative reporters. Core
contains the policy; native tasks and clocks execute its result. Engine event and foreground decision policy is specified below. Platform
suspension and engine recreation remain native execution operations.

## Engine events and preferences

`playbackEvents.begin` starts a new engine generation and returns its empty
snapshot. `playbackEvents.snapshot` returns the current snapshot.
`playbackEvents.apply` takes `generation` and `event`:

```json
{"generation":1,"event":{"kind":"state_changed","state":"playing"}}
```

Events are `state_changed` with a state, `position`/`duration` with nonnegative
finite `seconds`, and `failed` with an Int32 `code` and optional `message`.
Native states are `idle`, `opening`, `ready`, `playing`, `paused`, `stopped`,
`closed`, `error`. The response contains `accepted`, `reportedFailure`,
`foldedTailFailure` and `snapshot`. The snapshot contains generation, state,
position/duration, error count, latest real failure and whether the tail EIO
signature has been folded. A rejected old adapter retains its old generation;
it cannot acquire the current engine by copying a rejected response snapshot.
Malformed commands return code 1002 without mutation.

The shared reducer preserves the current native rule for the known stale EIO:
known positive duration, position within two seconds of the end, and a message
containing both `av_read_frame` and `(-5)`. It folds that signature to stopped
once, with a warning and no error count. The following error state event cannot
undo the fold while still in the tail window. If a real failure is already
visible, the stale EIO preserves that error and message. Other errors remain
failures and repeated identical code/message pairs count only once. As in the
reference client, an actual I/O failure with that same signature in the final
two seconds is also folded; this preserves its existing accepted tradeoff.

Accepted events update the same playback session used for controls and source
recovery. Clean stopped events near the end project `ended`; errors project
`failed`. Positions survive event-driven stops, rates/volume/mute/track choices
survive telemetry, and the host refreshes its cached Core snapshot immediately
on state/duration changes. Native PlayerState still publishes Observation
values, refreshes native track lists, counts elapsed playing/buffering time and
logs the reducer's one-time failure/fold decisions. Native stream cancellation
and consumption guards remain alongside Core generation validation.

`playback.setMuted` requires a Boolean `muted`, independently of
`playback.setVolume`. The macOS engine receives zero effective volume while
muted, while Core retains the user's nonzero volume and muted flag. Unmuting
restores that volume. Malformed mute arguments leave preferences unchanged.

`playbackEvents.foreground` accepts `intentToResume`, nullable `state`, and
`hasSetupError`, returning `action` (`none`, `resume`, `rebuild`). No intent or
no current state produces none; an intended resume with setup error/engine
error requests rebuild; paused/ready/playing resume; idle/opening/stopped/closed
remain unchanged. Native suspension, clock accounting, post-resume monitoring
and engine recreation execute on the platform. macOS does not suspend its
process for this iOS lifecycle route; its shared decision table is verified
on macOS independently of iOS device execution.

Accepted engine state transitions publish `playback.stateChanged`, clean natural
completion additionally publishes `playback.ended`, unique real failures publish
`playback.failed`, and a one-time tail fold publishes `playback.tailErrorFolded`.
Duration changes publish `playback.durationChanged`. Position changes retain
`playback.position` and its bounded latest-value coalescing. These payloads carry
engine `generation`; rejected generations publish no notifications. Command
responses and snapshots remain authoritative if a consumer falls behind.

A native engine duration of zero means unknown. Such streams retain their real
position, and changing a known duration to zero removes the previous clamp.
Position/duration events update only the timeline; they do not replay an old
engine phase over a newer pause/play control. Lifecycle state/failure events
update the phase. Ignored recovery callbacks cannot republish a retired chain's
history after a new user play has reset the native projection.

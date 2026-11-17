# Retained repository progress and session coordination

Each repository Core handle now retains session-local playback records, monotonic
revision IDs, confirmation times and shutdown state. The existing Swift record
map and flag are used only by explicit native mode; no mirrored shared records
are replayed into native decisions. All clocks and Date payloads use the original
Foundation Codable reference-date representation and typed response decoding.
Lookup uses canonical Unicode equality; original IDs/metadata and exact signed
integer fields remain intact.

`mediaRepository.progress.*` accepts typed object arguments in `payloadJSON`.
`beginFinal` takes the captured item, position, optional duration and recordedAt;
it rejects a capture older than a current record before touching projections.
It computes the native playback state, preserving previous watched state and
unplayed count, and returns accepted/revision/state. Swift executes the original
MetadataStore transaction and forwards its state and optional newer disk record
to `finishFinal`. Only the same still-unconfirmed revision may adopt the result.
A later final capture, explicit mutation, observed confirmation or invalidation
with discarded progress prevents stale adoption. Accepted newer disk records
retain their actual recorded/confirmed/completion boundaries. Duplicate or stale
receipts return applied=false. Revisions are never reused.

A final write with explicit original-session attribution is permitted after
shutdown and still writes that tenant's database. Its accepted local record is
retained, while shutdown prevents applying it to projections. Ordinary mutations
and incidental network persistence remain blocked. The host retains native Task
cancellation/error checks and executes only the existing network/database effects.

`apply` takes itemID/state/persistToStore/now, establishes explicit confirmation
before an await, updates the canonical item/detail and all episode/home/page
projections, and returns the fallback item used by the disk effect. Native first
matching duplicate behavior and projection timestamp/LRU touches are preserved.
`playbackState` computes the existing bounded percentage with optional duration,
previous count/percentage and explicit played flag.

`incoming` executes the post-database-await reconciliation against the current
session records. A matching position must be strictly within one second and its
request must start at or after the capture. Completed playback can also be
confirmed by a remote played flag; cleared confirmed completion is removed from
resume. A confirmed boundary protects requests started at or before it; later
requests may update state. Missing protected, unfinished resume entries are
appended in descending capture time, using current canonical metadata when
available. `merge` and `filterResume` expose those same retained projection rules.
`invalidate` clears memory while preserving records unless explicitly discarded;
`shutdown` clears memory and sets the retained flag. Neither retires refreshes.
`lifecycle` returns the shutdown flag and `stats` provides retained records.

Malformed operation arguments, clocks and explicit states produce code 1002.
Apply/final adoption validates complete media projections before changing
progress or LRU state; generic non-media projection values cannot trigger an
unchecked mutation. Disposable database errors keep their
existing native degradation path; no successful network result is converted to
failure because persistence failed.

Five Rust cases and four actual C ABI cases cover all projections, duplicate
entries, Unicode and signed IDs, malformed-input atomicity, revision retirement,
confirmation/completion, resume reinsertion, foreign disk records and shutdown.
Three native differential cases compare full public projections and timestamps,
144 independent native observation combinations, actual disk-backed foreign
confirmation and owned post-shutdown writes. The full existing MetadataKit
progress/concurrency/persistence suite is also exercised with Core activated.
Complete raw records are in `validation/2026-11-14-repository-progress/`.

Home/detail/page composition policy now runs in Core; see
[media-repository-composition.md](media-repository-composition.md). Complete effect
sequencing and failure/fallback assembly now use
[retained workflows](media-repository-flow.md);
account/sync, playback preferences/recovery, transport fidelity, diagnostics,
Apple release delivery and Windows adapters remain broader parity requirements.
Windows runtime testing is explicitly deferred, not the adapter implementation.

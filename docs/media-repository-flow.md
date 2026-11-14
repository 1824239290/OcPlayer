# Complete retained media repository workflows

`mediaRepository.flow.*` owns sequencing and result assembly for every cached and
refresh operation for home, item, detail, episodes and page, plus detail prefetch.
The production Apple repository selects this retained handle before executing
its independent native algorithms. Native hosts execute yielded network,
MetadataStore and memory-publication effects and retain Swift task handles; they
no longer choose home section fallback, detail branches, cache restoration,
pagination merge, refresh source/timestamps or prefetch policy in shared mode.
Existing mutation/session-progress operations and refresh claims use that same
handle. The pure `compose.*` API remains available for existing consumers.

## Protocol and lifetime

`start` accepts `kind`, Foundation Codable `now`, and the kind's typed identity:
`itemID`, `kindHint`, `seriesID`, `seasonID`, `descriptor`, `startIndex`, `limit`,
`hasStore`, and optional prior snapshot/detail. It returns UInt64 `token` and
`sequence`, `done`, and either one effect with arguments or the complete result.
`resume` takes that receipt, current `now`, and original typed `responseJSON`.
Receipts are single-use. A malformed/stale response does not advance or retire
the flow; a completed response retires it. `cancel` retires a token idempotently.
`stats` exposes active count and the monotonically allocated next-token counter.
Reopening is refused while refresh claims or flows are active. Projection
invalidation/shutdown does not cancel retained tasks or flows. Hosts cancel in a
defer block on every exit, including a primary network error.

There is a bound of 1024 active flows per repository. Invalid kind/identity,
non-finite clocks, malformed descriptor enums/types and invalid receipts return
code 1002. `pageKey` derives the existing native PageKey from the full descriptor
and signed window: nil/empty identity defaults, sorted kind strings retaining
repetitions, raw sort/direction, watched state and search. The same key supplies
refresh ownership and disk-query matching. `collectionDescriptor` supplies the
native non-recursive year-ascending query. IDs, windows/counts, arbitrary metadata
and Foundation reference-date doubles retain original-byte typed encoding.
The Swift step decoder distinguishes a successful nil cached result from a
missing result or Core error; selected Core failures never replay native work.

## Effect and projection behavior

Home starts four parallel reads, then processes libraries, resume, next-up and
latest in their original persistence order. Empty success clears a section;
failed or cancelled sections keep previous content. Failure projection is
provided by the platform's existing error categorizer; Core owns its section
assignment and complete result. A successful next-up section is deduplicated
against the current resume section after persistence. Final progress merging and
confirmed-completion filtering use the retained session. All-failure results keep
the previous source/timestamp, while any success produces a network snapshot.

Detail keeps series item/seasons parallelism, primary item error propagation,
season/default-episode selection, auxiliary failures and previous section fallback.
A missing initial kind that resolves to series repeats the existing cached-detail
capture and item/season refresh with a fresh start time. Episode fallback requires
the same canonically equivalent season identity; collection total fallback is
independent of whether new members were returned. Shared item/episode subflows
update the current detail projection only after their original incoming-item
persistence. Collection member flows use the full shared page workflow.

Page runs its network read, incoming-item persistence and post-await progress
reconciliation before selecting the current accumulated memory/disk page. It
publishes the first merged projection and remembers incoming items before saving
the original page/key, then re-merges protected progress after that database
await and publishes again. A progress capture or confirmation during persistence
therefore participates in the final result. Replacement/append/offset/duplicate
rules are those in [the composition contract](media-repository-composition.md).

Cache operations return memory immediately without network/disk work. Disk home
uses one snapshot read and the established date/dedup policy. Disk detail reads
its cached item, seasons/default episodes or shared collection cache as needed,
keeping the item's original timestamp. Disk pages walk the contiguous prefix but
use the oldest date of all returned rows, including rows beyond a gap, matching
the native implementation. Cached episodes return nil when absent/empty and
retain their callback clock on recovery. All successful restores publish and
remember the same projections in the same order. Prefetch stops for a memory
snapshot, otherwise joins the shared detail refresh and keeps errors silent.

Native task cancellation/error categories, disposable-database degradation,
profile credentials, transport injection and server/platform interfaces remain
host effects. Source selection, all section fallback/assembly and the repository
business sequencing run in Core. This closes the repository workflow migration
scope; broader account/sync, playback, transport, diagnostics and release
acceptance remain active in [the parity ledger](macos-parity.md).

Five Rust, five actual C ABI and five native differential cases cover the new
flows alongside the existing complete repository suites. They include signed
window/descriptor identity, primary failure retirement, cancelled waiters sharing
one request, auxiliary fallback, complete disk/memory snapshots without network
requests, prefetch/collection behavior, invalid receipts and a progress update
between page publication and persistence completion. Full output is retained in
`validation/2026-11-14-repository-flow/`.

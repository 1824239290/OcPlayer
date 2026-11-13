# Shared repository projections and cache opening

MediaRepository now retains home/item/detail/episode/page memory projections and
five refresh ownership maps in a per-repository Core handle. Swift retains only
native task handles at this boundary. Complete LRU lookup/write/delete/all/clear
behavior, minimum limits, structured keys and freshness predicates run in Core;
waiter cancellation and invalidation preserve entered unstructured refresh tasks.
Explicit `useSharedCore: false` retains the independent native repository.

Keys follow Swift canonical Unicode identity while original keys and payloads
remain intact. Typed original-byte reads preserve Int.max-range model fields,
page totals and local progress counts. This fixed a real composed/decomposed
Unicode duplicate-key crash found by 6000 differential LRU operations. Full public
memory-only home/detail/page/progress results and task coalescing match native.

MetadataCache opening now delegates folder creation, WAL/foreign-key setup,
writer journal bounds, all four migrations and one-time corruption/migration
rebuild to Core. Media.sqlite/WAL/SHM file accounting and best-effort deletion
also run there. The GRDB pool remains the compatible adapter after migration;
a selected Core failure never replays native destructive recovery. Native-only
opening remains available and is compared against actual persisted files.

The complete protocol is in OcPlayer-Core's `docs/media-repository-contract.md`;
raw verification records are in `docs/validation/2026-11-14-media-repository/`.
Session-local progress reconciliation, confirmation/revision barriers, all
projection updates and shutdown state now also run in Core; the existing local
record map and flag serve explicit native mode only. The progress protocol is in
OcPlayer-Core's `docs/media-repository-progress.md`. Home/detail/page effect
composition remains migration work, alongside the broader parity requirements.
Windows runtime testing remains deferred by the user.

The prior enrichment validation report claimed asynchronous test fixture cleanup,
but source inspection showed the blocking waitUntilExit call remained. This
cohort removes the blocking waits from both enrichment and wire fixtures,
retains the stalled-run samples and revalidates the complete MetadataKit package. Historical raw reports are
preserved; this correction supersedes only that cleanup claim.

## Core composition policy

Pagination recovery/append/replace, home restore/deduplication, default-season
selection, detail planning and protected progress composition now dispatch to
`mediaRepository.compose.*` on the repository's retained Core. Typed original
Codable bytes keep signed integers and Foundation Date values exact. Native task
handles, four parallel home effects, section failure/fallback assembly and disk
await sequencing remain in Swift. Core-disabled paths stay independent for
differential testing. The shared protocol and validation are in OcPlayer-Core's
`docs/media-repository-composition.md`; full parity acceptance remains active.

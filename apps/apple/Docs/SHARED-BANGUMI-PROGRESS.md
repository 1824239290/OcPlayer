# Shared Bangumi subject and progress effects

BangumiDatabaseOperator creates RustBangumiProgress on its existing store Core.
With Core enabled, BangumiContext and BangumiEpisodeRepository delegate subject
loading, collection reconciliation, full chapter loading, single/batch progress,
watching preparation, season completion, collection type and rating mutations to
retained bangumiProgress effects. Native services execute HTTP and decode the
original bytes; notifications execute on MainActor.

The Core validates signed IDs, collection/rating inputs, single-use receipts and
tri-state collection lookup. It retains complete episode pages until transactional
replacement, optimistic writes before notification, and batch/completion failure
recovery. SQL is derived and applied inside the database handle's retirement lock.
Authenticated chapter replacement is captured at operation start. Unknown lookup
preserves interest and cannot promote a season. Completion requires nonempty,
all-watched mains plus confirmed remote doing.

Account operation begin immediately retires database work. Effect callbacks check
task cancellation, auth operation revision, API identity and DB work revision;
notifications recheck on MainActor. Core-disabled SQL uses a locked revision guard
around every progress/save transaction so stale work cannot repopulate account
data. Cancellation and retirement do not enter ordinary read-failure recovery.

RustBangumiProgressTests exercise real local HTTP, full paging, native GRDB parity,
large signed IDs, failed watching/batch reads, completion promotion, late remote
receipts, cancellation and every guarded native fallback write. The external Core
repository's docs/bangumi-progress-contract.md and validation ledger document the
exported ABI contract and full macOS run. Complete account/profile effect migration
and broader live-account acceptance remain part of the active project goal.

# Retained Bangumi subject and progress operations

`bangumiProgress.*` composes the existing public/authorized service effects and
the shared Bangumi SQLite store. The database operator creates the progress
directory on the same Core handle as its store and synchronization directory.
Native services retain transport, typed original-byte DTO decoding and the
collection lookup's collected / notCollected / unknown distinction.

`start` accepts a camelCase operation and signed integer subject/episode IDs:

| Operation | Inputs | Resulting behavior |
| --- | --- | --- |
| ensureSubject | subjectId, refreshEpisodes | Read local presence; fetch/save missing metadata; use episode counts to skip or fetch complete episodes; notify progress. |
| reconcileSubject | subjectId | Fetch metadata, merge only a confirmed collection, save and replace complete episodes. |
| refreshAfterProgress | subjectId | Reconcile; even on read failure, check local mains; promote only nonempty all-watched mains and confirmed remote doing to collect; notify membership. |
| ensureWatching | subjectId | Promote confirmed not-collected / none / wish / on-hold / dropped to doing; preserve doing, collect and unknown. Result is whether promotion occurred. |
| updateEpisode | episodeId, type, batch, prepareWatching | Optionally prepare watching before watched intent; perform remote mutation, optimistic SQL update and notification; reconcile batches without rolling back success on read failure. |
| updateSubject | subjectId, type | Remote mutation, local collection type update, membership notification. |
| updateRating | subjectId, rate | Remote mutation, local rating update, progress notification. |
| loadEpisodes | subjectId | Fetch all pages, replace the chapter set, notify progress. |

`authoritativeCollection` is captured from authentication at operation start.
Anonymous episode fetches preserve cached collection status; authenticated
fetches may clear missing collection fields. Metadata writes use the existing
non-authoritative interest merge. Episode pages use limit 1000 and stop on an
empty page or the reported total; replacement happens only after complete fetch.
Signed 64-bit IDs are preserved end to end. Episode types must be 0–3, subject
collection types 0–5 and ratings 0–10 before any remote effect is emitted.

Each reply contains a non-reused `token`, single-use `sequence`, and either
`done/success/result` or a named effect with arguments. HTTP effects are subject,
lookup, episodes, subjectMutation and episodeMutation. The host executes one
effect and supplies its original typed response to `resume`. Notifications and
bounded diagnostic logs also yield explicit effects. A lookup response carries
state plus an interest for collected, or an optional reason for unknown.

Database effects expose no mutable statement payload. `apply(token, sequence,
now)` derives SQL from retained state, validates the receipt, executes the store
transaction and advances the flow under the same composition-root lock.
`resume` cannot impersonate SQL; a failed SQL transaction leaves the receipt
available for explicit `fail` or cancellation. Fractional and underflowing
timestamps reject before SQL. Stale receipts cannot mutate or advance work.

The host supplies `fail(token, sequence, reason)` for an effect error. Watching
preparation failures preserve explicit episode intent. Batch read failures keep
the already committed optimistic progress and first notification. Completion
read/promotion failures log and still notify current membership. Fatal effects
terminate unsuccessfully and the native adapter preserves the original error.
Task cancellation and account/DB retirement abort instead of entering these
recoverable policies.

Account begin/invalidate and clearing account-local state retire both directories.
Changing the configured database path also retires them. Transparent token
refresh preserves current-account operations. Cancellation is idempotent and the
directory admits at most 1024 active flows. The native account operation barrier
immediately invalidates its database handle and increments a locked work revision;
fallback SQL writes validate this revision inside their complete transaction.
Native effect dispatch, replies and MainActor notifications additionally validate
task cancellation, account operation revision, API identity and DB work revision.

Coverage includes the exported C ABI, real local HTTP and independent GRDB parity,
large IDs, complete pagination, tri-state interest, failure ordering, stale HTTP
receipts, cancellation and all guarded fallback writes. See
[validation](validation/2026-11-14-bangumi-progress/README.md) and
[remaining project acceptance](macos-parity.md).

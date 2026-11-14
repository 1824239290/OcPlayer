# Retained Bangumi synchronization

`bangumiSync.*` owns collection pagination, complete episode assembly and
replacement, sliding bounded episode reconciliation and the full incremental
collection/episode refresh. The Apple database operator retains one Core handle
for both the synchronization directory and Bangumi.sqlite. Native adapters
execute the yielded HTTP, target-query and timestamp effects. Database effects
are applied inside Core from the retained payload, under the same state lock as
receipt validation and retirement; the payload does not round-trip to the host.

## Commands

`start` accepts `operation` collections/episodes/reconcile/allCollections and
optional signed `since`, `startedAt`, `maxConcurrent` (default 4), boolean
`force` and `authoritativeCollection`, and `subjectId` for episodes. A child
episode flow also supplies its parent's `parentToken` and Core-issued `parentJob`.
Replies contain exact unsigned `token`/`sequence`, `done`, and either a typed
`result` or an `effect` with `arguments`.

`resume` supplies the current token/sequence and a typed `response`:

| Effect | Host result / behavior |
| --- | --- |
| `collections` | `{data: [subject DTO], total: Int}` from the current `since`, limit 100 and offset |
| `episodes` | `{data: [episode DTO], total: Int}` from the subject, limit 1000 and offset |
| `targets` | Ordered `[Int]` from the complete missing/stale-progress query; a failed optional query becomes an empty array |
| `timestamp` | Apply `value` to the native store under the MainActor account-operation barrier, then resume with `true` |

`saveSubjects` and `replaceEpisodes` require `apply`, with the current receipt
and signed Unix `now`. Core applies the original DTOs transactionally and advances
the receipt only after SQL success. Their reply arguments expose counts and
policy metadata, avoiding another copy of the complete payload over the ABI.
Calling `resume` for a SQL effect is rejected. Invalid inputs and stale receipts
use code 1002; SQL failures use 1402. Transition validation happens before SQL,
and failed SQL leaves the receipt intact. The malformed-page fixture proves
transaction rollback across every row before retrying that same receipt.

`episodeBatch` issues ordered `{id, subjectId}` jobs. The host launches those
jobs as child episode flows, then calls `batchComplete` with `token`, `jobId`
and boolean `succeeded`. Each completion fills only its own slot and issues the
next queued job; it cannot complete while its child still exists. Job receipts
are single-use and completions can arrive out of order. Partial episode errors
count as unsuccessful jobs while other subjects continue. The completion reply
uses the same step envelope, containing newly issued jobs or the final result.

`cancel` retires a token and all descendants; cancellation is idempotent.
`invalidate` retires the complete directory, and `stats` reports `active` and
`epoch`. Tokens are monotonically allocated and never reused. There are at most
1024 active flows. Database reconfiguration and account clearing also invalidate
the directory. A retired parent/job cannot authorize a child's late SQL write.

## Preserved policy and account boundaries

Collection pages save before requesting the next page; earlier successful pages
remain available when a later page fails. Counts use received DTO count, while
offsets advance by the original fixed limit. Episode pages accumulate completely,
including an empty tail, before one transactional replacement prunes obsolete
episodes. Empty successful episode responses replace the previous set with empty.
Authorized episode reconciliation retains authoritative collection clearing.

Full refresh resets the timestamp to zero when forced, queries with a 300-second
overlap (`max(0, since - 300)`), then commits the captured start timestamp after
all collection pages succeed and before episode reconciliation. Its return value
is collection count even when individual episode subjects fail. Standalone
reconciliation returns successful subject count. Concurrency retains the native
minimum of one and fills a newly freed slot without waiting for a whole batch.

The credential account now exposes an identity generation that advances for
OAuth replacement/logout, preserving it across transparent token refresh.
Native synchronization captures the account-operation revision before awaiting
effects and verifies identity/revision around returned results. Beginning a
native login/profile/logout operation immediately invalidates the database Core
directory. On a single configured Core handle, account operation begin, accepted
OAuth commit and accepted invalidation perform that same retirement under the
state lock. Transparent refresh commits retain active sync flows.

The independent Core-disabled path retains native pagination and grouping, with
database-actor revision guards on collection/episode writes after account clear,
plus the same MainActor timestamp adoption barrier. Native stores and account
adapters now decode typed ABI results directly from original response bytes,
preserving full signed/unsigned identifiers rather than a Double projection.

Platform credentials, HTTP tasks, UserDefaults and notifications remain adapters.
Detailed subject loading, watched-state mutation chaining and complete shared
account/profile effect orchestration still require migration/acceptance; this
contract does not close the complete Bangumi or macOS release scope.

## Evidence

Five added Rust cases cover policy, account identity and receipt/owner retirement.
Six actual C ABI cases verify real SQLite application/rollback, exact Int64 IDs,
signed times, empty replacement, account clearing, child cancellation and sliding
slots. Five native cases use real Core HTTP and GRDB comparisons for complete
records, multi-page requests, partial failure, cancellation and late writes.
Production activation and token-refresh identity preservation are also asserted.
Raw validation is retained in `validation/2026-11-14-bangumi-sync/`.

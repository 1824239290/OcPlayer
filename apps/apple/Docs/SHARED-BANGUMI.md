# Shared Bangumi account policy


## Retained account state

The production BangumiAPIClient now retains the same Core handle for HTTP and
`bangumiAccount.*` policy. Credential/OAuth/refresh generations, single-flight
refresh ownership, expiration/session reuse and auth-service revision barriers
are owned by Core. Swift executes credential storage, sessions, effect tasks,
watchdog waits, notifications and profile/UI writes. Injected native transports
and Core-disabled runs retain the independent implementation.

OAuth state is consumed before the token request, preventing concurrent callback
replay and preserving a later authorization when an older request completes.
Logout also retires pending state. Shared refresh tasks are keyed by their Core
claim, so retired cleanup cannot remove a newer task. Real native and Core HTTP
race fixtures cover these behaviors. Collection/account effect scheduling and
complete sync acceptance remain open.

## Retained synchronization

BangumiDatabaseOperator now retains the sync directory on its SQLite Core handle.
Collection pagination, complete episode replacement, sliding reconciliation and
full incremental refresh all execute yielded Core steps. SQL effects use a
single-use receipt applied inside Core; account clearing/reconfiguration retires
pending writes under the same lock. Starting a login/profile/logout operation
also invalidates the database sync directory immediately. Swift retains HTTP
and timestamp effects, using the captured account-operation/identity barriers.
The independent native path now guards database writes with the database actor's
revision and timestamp adoption with the MainActor account revision.

Typed account/store/sync ABI replies decode directly from their original bytes,
preserving exact Int64/UInt64 values. Actual HTTP/GRDB comparison fixtures cover
paging, signed integer identity, partial failures, cancellation and late writes.
Detailed subject/progress mutation chaining and full account/profile effect
orchestration remain separate acceptance work.

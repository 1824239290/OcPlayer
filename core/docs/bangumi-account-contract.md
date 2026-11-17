# Retained Bangumi account policy

`bangumiAccount.*` commands use one account owned by the Core handle, separate
from the HTTP request directory and the SQLite store. A client retains the same
handle for transport and account decisions. No access token, refresh token,
profile or credential file is supplied to this interface. `snapshot` reports
only counters and refresh activity; it never returns OAuth state.

The Apple adapter selects this policy whenever its HTTP transport selects Core.
An explicitly injected native transport and Core-disabled operation retain the
independent Swift implementation. Selected Core operations never replay on the
native implementation after an error. Nonthrowing local lifecycle APIs treat an
invalid Core contract as an invariant failure rather than inventing another
credential owner.

| Command | Input and result |
| --- | --- |
| `snapshot` | Current credential, exchange, refresh, identity and profile-operation counters; refresh activity |
| `identity.current` | Identity `generation`; whether the same account scope remains current across token refresh |
| `current` | Exact unsigned `generation`; whether this credential generation is current |
| `oauth.prepare` | Nonempty `state`, maximum 4096 UTF-8 bytes; replaces the pending state |
| `oauth.consume` | `state`; consumes before any network await, returns `accepted` and exchange `generation` |
| `access` | `present`, Unix `now`, optional Unix `expiresAt`; returns missing/refresh/reuse and credential generation |
| `session` | Access inputs plus optional `sessionGeneration`; whether the authorized native session can be reused |
| `refresh.claim` | Returns `id`, credential `generation`, `joined`, and 15-second timeout; concurrent claims join one owner |
| `refresh.finish` | Owner ID in `generation`; only that owner can clear its active claim |
| `refresh.failure` | `kind` cancelled/unauthorized and refresh ID/credential generation respectively; stale/timeout/login category |
| `commit` | `kind` oauth/refresh and corresponding `generation`; acceptance plus effects to cancel refresh/requests and invalidate session |
| `invalidate` | Optional conditional credential `generation`; acceptance plus retirement effects |
| `operation.begin` | Advances the login/profile/logout revision |
| `operation.current` | Revision in `generation`; whether a profile or UI account operation can still publish |

Counters wrap like the existing Swift `&+=`. JSON integer decoding preserves the
full unsigned 64-bit range and rejects negative, fractional, null and overflowing
values. Required fields are decoded before changing state; invalid commands use
error code 1002 and leave state intact. Expiration retains the native 60-second
leeway (`now + 60 > expiresAt`); the exact boundary remains reusable.

Credential refresh commits advance the credential generation and retire existing
authorized requests/sessions. OAuth commits additionally retire any old refresh
claim and exchange. Logout retires all three generations and the pending state.
Conditional logout does nothing when the credential generation has changed.
Refresh effect tasks are keyed by Core-issued ID in the Swift actor; an old
task's deferred cleanup removes only its own task and claim. A new OAuth flow
prepared while an earlier token exchange runs survives the earlier completion.
Duplicate callbacks cannot submit a second token request.

The native actor still performs credential encoding/persistence, clock reads,
session construction/cancellation, task execution/watchdog sleeping, localized
error mapping and notifications. The four MainActor account/profile service flows now use
[retained account/profile effects](bangumi-auth-flow-contract.md), including
profile commit and failure rollback, logout UI/credential/DB order, conditional
passive invalidation and physical credential/DB clear guards. Native execution
and persistence remain adapters. Subject/progress operations and collection/episode
sync use [progress](bangumi-progress-contract.md) and
[sync](bangumi-sync-contract.md) flows. Broader live-account and full macOS release
acceptance remain open.

Verification includes Rust state tests, five exported C ABI cases (with 64
parallel claims), and real native/Core HTTP comparisons for logout during
refresh, in-flight token exchanges, duplicate callbacks, later authorization,
conditional invalidation and production account selection. Raw results are
retained in `validation/2026-11-14-bangumi-account/`.

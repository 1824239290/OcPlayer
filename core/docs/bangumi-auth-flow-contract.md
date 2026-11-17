# Retained Bangumi account/profile effects

`bangumiAuthFlow.*` uses the same Core account as BangumiAPIClient. It retains
the complete four MainActor service flows, while the host performs HTTP, typed
profile decoding, credential storage, task/session retirement and UI/database
effects. Neither authorization codes, OAuth state, tokens nor profile payloads
are supplied to or retained in this directory.

| Start operation | Retained sequence |
| --- | --- |
| exchange | Begin operation; retire database work; exchange authorization; fetch profile; commit profile. Profile/commit failure yields conditional credential rollback, then the original failure. |
| refreshProfile | Begin operation; retire database work; fetch profile; commit profile. Preserve current credentials on a profile failure. |
| logout | Begin operation; retire database work; clear profile/auth state and incremental timestamp; conditionally clear credentials; clear account-local DB only while the cleared generation is still current. A DB cleanup failure preserves logout success. |
| invalidateSession | If authenticated, observe operation and expected credential generation; conditionally clear credentials; confirm the cleared generation is current; begin operation and retire database work; clear profile/auth state. Keep cached DB rows. |

`start` accepts the camelCase operation plus authenticated and expectedGeneration
for passive invalidation. Ordinary account operations advance the account
operation revision immediately and retire earlier flows. Passive invalidation
does not advance until it has successfully cleared the current credential.
The new revision also retires sync and progress directories on the composition
root. The host immediately retires its selected database work when that effect
is yielded.

Replies contain exact unsigned token, sequence and operationRevision, plus either
done/success/result or effect/arguments. `validate` checks a current single-use
receipt before dispatch. `resume` supplies true acknowledgements, an exchange
generation/identity receipt, or an optional cleared generation. Profile refresh
is guarded by identity as well as operation; transparent token refresh preserves
identity. OAuth exchange adopts its returned identity before profile effects.
Wrong sequences and malformed replies leave current work unchanged; retired
operations or identities reject with 1003. Inputs reject with 1002 before
mutating the account. Tokens never reuse and reject exhaustion. At most 1024
observational invalidations can be active; a new explicit account operation
retires old observers and remains able to proceed. Cancellation is idempotent.
At that bound the native nonthrowing invalidation API safely leaves clearing to
already pending work; explicit login/profile/logout operations remain available.

`fail` retains recovery policy. A failed profile after exchange yields
clearCredentials with the exact exchange generation and operation revision;
this cleanup does not replace the original error, including cancellation.
Rollback failures or a new account still leave that original error intact.
Other profile/exchange failures terminate; logout DB cleanup failure succeeds.
The host always releases the retained receipt on completion/cancellation.

`bangumiAccount.invalidate` now accepts optional operationRevision in addition
to the existing optional credential generation. Both constraints are decoded and
checked under the account lock before changing credentials or exchange/refresh
state. A rejected clear cannot cancel a newly started OAuth exchange. The native
credential actor performs the resulting storage/session effects synchronously;
its independent fallback holds an operation lock around the entire conditional
credential transition.

Native clearAccountLocalState accepts an optional work revision. Validation,
work retirement and the whole SQL deletion share its work lock; a new account's
operation begin invalidates that revision before an old actor handoff can delete
new rows. Both Core and fallback database paths use the same guard. MainActor
profile commit callbacks are validated before and after any asynchronous handoff.
The existing original-byte Codable/default profile decoding and all user fields,
large integer identifiers, avatar and permission flags are preserved.

Verification uses Rust state/boundary cases, exported C ABI composition and real
local HTTP in both selected-Core and independent native modes. It covers profile
and cancellation rollback, newer credentials during failure, late fetch/commit,
logout/new-login DB races, atomic physical credential rejection, passive
invalidation, default profile tolerance and failed DB cleanup. See
[validation](validation/2026-11-14-bangumi-auth-flow/README.md) and
[remaining project acceptance](macos-parity.md).

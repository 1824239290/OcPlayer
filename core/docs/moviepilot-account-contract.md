# Retained MoviePilot account lifecycle

`moviepilotAccount.*` runs on the same retained Core handle as MoviePilot HTTP.
It owns login/authentication generations, the recorded configuration revision,
single-flight refresh receipts, the 15-second watchdog policy and the refresh
fuse. Credentials, platform storage locks/revisions, tasks, localized errors,
cookie-pool retirement and UI notifications are effects. No secrets are retained
by the account directory.

## Commands and receipts

- `seed`: `{generation, configurationRevision, refreshId,
  exhaustedGeneration?}` imports the independent native owner's counters once,
  before adoption. Further seeds fail. The native loader cannot change account
  owners during an initial login or a running native refresh.
- `snapshot`: `{generation, configurationRevision, refreshID,
  exhaustedGeneration, loginActive, refreshActive}`; `current({generation})`
  returns a boolean.
- `clear.allowed({generation, revision})`: both the authentication generation
  and its recorded platform configuration revision must match. This prevents an
  old authentication-required notification from clearing newer credentials.
- `invalidate({revision})`: retires login/refresh receipts, advances generation,
  records the platform revision, resets the fuse and returns
  `{generation, cancelRefresh:true, cancelRequests:true, clearSessions:true}`.
  Sign-out and conditional session clearing apply these effects synchronously.
- `login.begin({revision})`: the same retirement transition, plus a monotonic
  `id` for the new login. It follows platform configuration invalidation, while
  physical old credentials remain until successful validation and commit.
- `login.authorize({id, revision})`: validates the receipt before the platform
  commit. `login.commit({id, revision, tokenMatches})` validates it again after
  the asynchronous platform effect. Commit requires the same pending attempt,
  exactly the previous platform revision plus one, and the issued token still
  matching the atomic platform snapshot. Accepted commit advances generation,
  consumes the attempt and retains the authenticated cookie pool.
- `login.finish({id})`: idempotent owner cleanup. Old cleanup cannot remove a
  replacement attempt.
- `refresh.claim({revision, tokenPresent, credentialsPresent})`: returns
  `{action,id,generation,timeoutSeconds:15,clearToken,notify}`. `start` claims one
  owner; same-revision concurrent requests `join`, including while owner cleanup
  is pending after successful commit. A changed configuration retires the old
  receipt. `missing` clears the token without notification. `fused` clears and
  notifies only if a token is present, so the physical clear makes subsequent
  notification attempts idempotent.
- `refresh.authorize({id, revision})`: guards the conditional platform token
  write. `refresh.commit({id, revision})`: accepts once, advances generation,
  records the revision and fuses the newly issued generation. Token refresh
  preserves the configuration revision and authenticated cookie pool.
- `refresh.failure({id, revision, kind})`: `rejected`, `transient` or `cancelled`.
  Only the current uncommitted owner is accepted. Rejection fuses the current
  generation and requests token clear/notification. Transient or cancelled
  failures preserve credentials. `refresh.finish({id})` releases only that
  owner. Both failure/commit replies include `{accepted,generation}`; failure
  additionally includes `clearToken` and `notify`.

Identifiers and revisions are exact unsigned 64-bit integers. Invalid arguments,
unknown methods and checked-counter exhaustion return 1002 without partially
mutating state. Claim/commit sequencing is protected by the Core state lock.
The host validates cancellation/configuration around network waits, applies
storage writes with the platform revision lock, and respects the second commit
decision before publishing a user. No Core error triggers native policy replay.

## Native integration and verification

`RustMoviePilotAccount` decodes the original response bytes, preserving integers
above 2^53. `MoviePilotAPIClient` seeds the retained owner when its existing
transport is selected; a selected owner remains selected for the actor lifetime.
Injected URLSession protocols and unavailable/disabled initial selection keep
the independent native implementation. That implementation also checks the
generation, committed revision and token after the commit handoff.

Rust tests and `tests/moviepilot_account_contract.py` verify concurrent claims,
late releases, successful/rejected/transient/cancelled refresh, fuse/missing
credentials, configuration retirement, exact large counters and transactional
invalid input. Native tests interrupt the real credential commit with sign-out
or a replacement login in both Core and independent native modes. Existing real
HTTP fixtures cover raw/named/late expiry sharing, cookie/connection retention,
token retry, malformed/rejected refresh and notification counts.

The outer raw-request retry/replay and named-command auth replay now run in
[retained request flows](moviepilot-flow-contract.md). The account and request
directories share lifecycle retirement in the composition root. Live deployments
and release/slice acceptance remain outside these local fixture checks.

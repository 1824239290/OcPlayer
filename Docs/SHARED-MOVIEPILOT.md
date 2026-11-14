# Shared MoviePilot account policy

The selected `MoviePilotAPIClient` Core now retains the account lifecycle as well
as ordinary/login/raw/SSE HTTP commands. `RustMoviePilotAccount` owns no secrets:
it adapts exact integer receipts for login, refresh, logout, conditional clearing,
single-flight coordination and the generation fuse. The actor executes storage,
task/watchdog, cookie-pool and notification effects.

Initial Core adoption imports native counters once and cannot happen during a
native login or refresh. An adopted account remains the owner for this actor.
Injected URLSession protocols and initially disabled/unavailable Core selection
continue to use the independent native path.

Login validates its receipt before the MainActor credential commit and after
that asynchronous handoff. A concurrent logout or newer login prevents an old
successful storage write from publishing an authenticated user or advancing the
new account's generation. The native fallback has the same post-commit guard.
Refresh commits once under a current configuration receipt, preserves the cookie
pool and fuses the newly issued generation. Rejected refresh clears/notifies;
transient network errors preserve credentials. Old task cleanup cannot release
a replacement refresh owner.

`MoviePilotAccountLifecycleTests` uses an injected credential commit to exercise
sign-out/new-login immediately after physical storage succeeds in both modes.
Existing Core authentication fixtures verify real HTTP concurrency, raw/named
expiry sharing, cookies, malformed/rejected refresh and notifications.

The account ABI is documented in OcPlayer-Core's
`docs/moviepilot-account-contract.md`. The selected actor's outer raw-request
retry/auth loop and named-command replay now run in `moviepilotFlow.*`, documented
in `docs/moviepilot-flow-contract.md`. Core owns method idempotence, retry budgets,
backoff/jitter bounds, token reuse vs shared refresh, single auth replay and
failure termination. The actor retains bytes/errors, sampling/sleep and
transport/account effects. Account begin/logout and configuration commits retire
pending flows; transparent refresh preserves them at its unchanged revision.

`RustMoviePilotFlowTests` verifies real HTTP counts, post-refresh retry budget,
named transport-only retry, refresh failure preserving the token without outer
retry and logout during pending backoff. Typed login/current-user decoding also
preserves integer identities above 2^53. Broader live-account, playback/transport,
settings and release acceptance remains.

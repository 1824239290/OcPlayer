# Retained MoviePilot request flows

`moviepilotFlow.*` owns complete retry/auth replay sequencing for the retained
MoviePilot actor. Hosts execute network/account calls, hold original bytes/errors,
read/write tokens, sample jitter, wait and log. No body or secret is retained.

`start({kind,method,authorized,revision,idempotent?})` returns
`{token,sequence,done:false,effect}`. Kind is `raw` or `named`; revision is the
opaque platform configuration revision. An optional boolean idempotence override
replaces method policy. GET/HEAD/PUT/DELETE/OPTIONS/TRACE are idempotent,
case-insensitively; other methods are not. Raw idempotent operations have three
attempts, creations one. Named commands have one outer attempt because their
existing Core HTTP commands already own transient retry.

`resume({token,sequence,revision,outcome,tokenChanged?})` consumes exactly the
current receipt and yields the next effect or `{done:true,success,effect:null}`.
Outcomes are `success`, `unauthorized`, `retryable`, `fatal` or `ready`:

- `send`: `{replay,attempt,maxAttempts}`. Perform exactly one raw exchange, or
  one named Core command including its transport retry; retain bytes/errors.
- `latestToken`: after an initial authorized 401, read the latest token. Resume
  `ready` with `tokenChanged:true` to replay that token immediately. False yields
  `refresh`, so a late old-token failure avoids another password exchange.
- `refresh`: await the shared retained account refresh. Success yields one auth
  replay. Every refresh failure is terminal, including transient errors: login
  transport already owns retry and the rejected-token request must not restart.
- `sleep`: `{baseSeconds,minimumSeconds,maximumSeconds,attempt,maxAttempts}`.
  Raw retryable failures consume one remaining attempt. Base delays are one and
  two seconds; Core sets jitter bounds to 0.5–1.5 times the base. Sample/wait and
  resume `ready`. The next attempt can perform one auth replay again, matching
  the original raw coordinator.

Replay 401 is terminal and cannot trigger another immediate login/replay.
Successful refresh has fused its authentication generation; a later request
performs the existing clear/notification path if that token is still rejected.
Unprotected operations do not refresh. Fatal/exhausted failures return the
original host error.

`cancel({token})` returns `{cancelled}` idempotently; `stats` returns `{active}`.
Terminal results release their entry. The directory has a 1024-flow bound and
checked monotonic u64 identifiers. Invalid input, unknown outcomes, wrong effect
outcomes and out-of-order/duplicate receipts return 1002 without advancing valid
work. Cancelled/missing flows and configuration mismatch return 1003; mismatch
retires the flow. Independent flows cannot release one another.

Account login begin/logout retires all flows under the same Core state lock.
Accepted login commit retires older configuration revisions while preserving
flows already launched with the new revision. Transparent refresh preserves
flows at its unchanged revision. Hosts check cancellation/physical revision
around asynchronous effects and cancel receipts in all exit paths. Selected-Core
failure never falls back to another retry owner.

`RustMoviePilotFlow` decodes typed original-byte continuations.
`MoviePilotAPIClient.runCoreFlow` executes effects on the actor for both raw
requests and named commands/SSE. The independent URLSession path retains its
existing coordinator. Retry-sleep injection remains the last initializer closure
parameter. Typed original-byte login/current-user decoding preserves integer IDs
above 2^53 and native optional flag mapping.

Four Rust tests and `tests/moviepilot_flow_contract.py` verify method overrides,
raw/named retry ownership, one replay per attempt, backoff bounds, terminal
refresh/replay failure, invalid receipts, exact revisions, account retirement,
concurrent IDs and the directory bound. Native real HTTP fixtures verify large
IDs, transient refresh preserving the token without outer retry, post-refresh
raw retry budget, named transport-only retry and logout during pending sleep
without another dispatch. Existing transport/SSE/race, non-replay and independent
native tests remain in the full gate. Broader account/profile, transport,
playback, settings and release acceptance remains in the project ledger.

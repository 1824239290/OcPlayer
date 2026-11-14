# MoviePilot authentication and request contract

The shared client handles MoviePilot's ordinary API, login token issuance,
current-user validation, torrent SSE, downloads and subscriptions. The macOS
MoviePilot actor dispatches all these HTTP paths through its retained Core when
enabled. The retained [account policy](moviepilot-account-contract.md) owns
authentication generations, login/refresh receipts, single-flight coordination
and the refresh fuse. Physical credential storage, atomic platform commits and
configuration revisions, tasks and native notifications remain effects.
Injected URLSession protocols and disabled
Core configurations retain the existing native implementation.

## Login

`moviepilot.login` accepts `baseURL`, `username`, `password`, optional
`validateUser` (boolean, default true) and optional `requestId`. It never sends
an old Bearer token to the login endpoint. It form-encodes Unicode and reserved
characters and retries transient token issuance failures through the shared
idempotent HTTP path. Business creation requests retain their non-replay policy.

With validation enabled, token issuance is followed by current-user validation
using the same connection/cookie jar. A missing/non-string user name fails rather
than publishing an authenticated session. The result is
`{"accessToken":"...","user":{...}}`. With `validateUser:false`, only the token
is issued and `user` is null, matching silent refresh's original request sequence.
Malformed token JSON is code 1514; HTTP 400 is code 2000, auth failure is 1503 and
non-token permission failure is 1504. The account owner keeps the existing refresh
fuse: rejected or malformed refresh clears the expired token and asks for login;
concurrent expiry waits for the same refresh, while a late old-token rejection
replays the already refreshed token.

A successful login publishes its jar only under the issued token and current
session-cache generation. The native actor checks its configuration revision
before committing credentials and Core revalidates the receipt after the commit
handoff; a newer login, sign-out or session invalidation
cancels earlier in-flight Rust work. Failed initial login preserves previously
committed credentials. Successful commit retains the new authenticated pool.

## Byte-preserving request

`moviepilot.request` accepts `baseURL`, optional `accessToken`, `url`, `httpMethod`,
optional string dictionary `headers`, optional `bodyBase64`, optional positive
finite `timeout` in seconds, and optional `requestId`. The URL must stay in the
configured server origin and base path, without URL credentials or a fragment.
Authorization, Cookie and Host header overrides are rejected. A supplied timeout
overrides the ordinary transport's total deadline for this request.

The result is `{"status":200,"headers":{...},"bodyBase64":"..."}`. Both successful
and error response bodies are preserved byte-for-byte, including binary data,
empty 204 responses and error bodies over 16 KiB. HTTP error statuses are returned
as data so the caller can apply its existing authentication/error-envelope policy.
Transport timeout is code 1521, connect failure 1522 and other transport failure
1523. Invalid arguments return 1002 before HTTP dispatch.

This command executes exactly once. In macOS `requestData`, the existing outer
retry/authentication loop remains the sole owner: idempotent reads retry up to
three times, explicit non-idempotent operations and ordinary POST/PATCH creations
are sent once. The native adapter preserves JSON/form bytes and duplicate/null
query items from its existing URLRequest construction, maps HTTP statuses back to
the same MoviePilot errors, and propagates dispatched errors without Swift replay.

All exchanges use the account-scoped pool described in
[network-contract.md](network-contract.md). Cancellation and configuration
retirement guard response publication as well as credential updates.

## Verification

`tests/moviepilot_contract.py` exercises the public C ABI with real HTTP/1.1:
binary/error fidelity, one-shot creation, argument/URL/header validation, token-only
and validated login, malformed-token/user rejection, token retry, timeout category,
all download/subscription mutation routes, path escaping, complete raw list fields
and media-search query shape. It runs in the full macOS verification script.

Native MoviePilot authentication fixtures exercise first login and atomic commit,
Cookie/connection retention, transient token retry, sign-out/newer-login races,
raw JSON/form/binary/query fidelity, typed HTTP errors, retry ownership, timeouts,
concurrent raw/named/late expiry, malformed refresh, rejection and notifications.
Existing native race and injected URLSession regressions remain part of the suite.
These are fixtures, not acceptance of a live user's deployment or the complete
cross-platform account/sync orchestration goal.

# Jellyfin / Emby anonymous login and Quick Connect

The anonymous macOS login session now retains a Core handle from public-info
probe through password or Quick Connect authentication. Credential persistence,
server-profile merging, UI session identity and cancellation ownership remain
in the platform. Injected URLProtocol configurations retain their native
transport; an enabled production default/ephemeral configuration loads Core.
Once a request dispatches to Core it never falls back to a native HTTP attempt.

All commands accept `profile` with the existing server profile shape. An
anonymous profile has `id`, `kind` (`jellyfin` or `emby`), `baseURL`, and the
platform's `authorizationHeader`; optional `userAgent` is read for each native
call. Both Authorization and X-Emby-Authorization carry the same stable native
device identity. The platform preserves reverse-proxy prefixes and appends
`/emby` only after detecting Emby during the initial public-info probe.

| Command | Additional arguments | Result |
| --- | --- | --- |
| `server.probe` | none | Public server info: id, serverName, productName, version |
| `server.login` | username, password (strings; empty passwords are permitted) | token, userId, optional userName/primaryImageTag |
| `server.loginQuickConnect` | nonempty secret | Same login result |
| `server.quickConnect.initiate` | none | code, secret, authenticated |
| `server.quickConnect.state` | nonempty secret | Optional code/secret, authenticated |
| `server.quickConnect.wait` | nonempty secret; optional pollInterval, maxPolls, failureTolerance | Authenticated state with nonempty secret |

Each password login, code issuance and individual state check sends exactly once
through the shared HTTP pool. Public-info probes retain the native three-attempt
bounded transient retry policy. Polling alone owns retries for Quick Connect;
password submission and code issuance are never replayed. The wait checks
immediately, then sleeps between checks. Defaults match the native client:
3 seconds, at most 60 polls, tolerance of five consecutive failures. Any
successful state check resets the consecutive-failure count. An explicit
missing Quick Connect endpoint ends the flow immediately. Emby rejects all
Quick Connect operations without making a network request.

`pollInterval` must be finite and in (0, 60] seconds. `maxPolls` must be an
integer in [1, 1000]; `failureTolerance` must be an integer in [0, 100]. Invalid
arguments fail with 1002 before network access. The normal requestId /
request.cancel contract interrupts in-flight HTTP or polling sleeps. Separate
pairings and concurrent password requests cancel independently. The native
stream emits one polling code, then one authenticated secret; cancellation
ends quietly and never emits a later authorization event.

The password response parser matches native LoginResult.parse: token and user
ID must be nonempty strings. Missing/invalid required credentials or invalid
JSON are unauthorized (2001). Optional name/avatar fields of an unexpected type
are ignored, as are unrelated server/plugin fields. Password HTTP 400 maps to
unauthorized for old Emby versions. Other status codes retain 1600 + status;
401 is 2001, 403 is 2003. Quick Connect disabled is 2401 and polling exhaustion
is 2402. Transport timeout/connect/other failures retain 1521/1522/1523. Error
messages never include credentials, pairing URLs or response payloads.

`tests/media_login_contract.py` verifies the public C ABI against a real local
HTTP/1.1 fixture, including connection reuse, request identity, response types,
mutation non-replay, query escaping, polling reset/tolerance, argument bounds,
cancellation and concurrent flows. The same fixture is copied to JellyfinKit
for production-default native activation, profile commit, Emby prefix/identity,
public Quick Connect, cancellation and injected-transport compatibility tests.
The fixture uses no external service or credentials.

This closes anonymous login/pairing transport and polling, not the remaining
media-resource mapping or platform proxy/trust configuration acceptance work.

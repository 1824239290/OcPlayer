# Network ownership and connection reuse

The Core owns a lazy, persistent Tokio executor with two workers. HTTP commands
execute on it, while blocking C ABI callers wait for their result. Probe, media
server, TMDB, Bangumi and danmaku requests clone the same reqwest connection pool;
credentials and user agents remain per request. The pool stores no cookies or
default authorization header. Creating another Core creates an independent pool.

The executor is destroyed with its Core. Shutdown runs on a separate joined
thread so dropping the handle from an async host is safe and no worker survives
dynamic-library unloading. Network futures retain transports and independent
session-cache state, never their executor owner. Cancellation still drops the
operation and returns code 1003; request preparation/cancellation remains available
while other network commands execute.

MoviePilot uses separate ordinary and SSE transports sharing one cookie jar per
canonical server URL and token. Normal requests use a 15-second connect/read
timeout and 30-second total request timeout. SSE uses 30-second connect/read and
300-second total timeouts. Reads reset the idle deadline, allowing heartbeat
streams to run beyond 30 seconds. Existing idempotency-based retry policy remains:
creation POST/PATCH requests are sent once, while reads can retry transient failures.

The session cache retains at most 16 pairs, evicting the least recently used.
Evicted pools can finish outstanding requests but are not reinserted. Login starts
with a clean jar and publishes it only under the newly issued token after success.
Anonymous requests cannot inherit that authenticated jar. `moviepilot.clearSessions`
retires all cached cookies and advances a generation guard so an older login cannot
repopulate the cache. The command returns `{"cleared":true}` without initializing
the executor. Diagnostics expose worker/session counts and the limit, never tokens,
cookies or server keys.

The macOS MoviePilot actor retains one `OcpCoreClient`. Its single event poller
routes SSE projections to handlers by request ID and rejects retired configuration
revisions. Finishing/cancelling one search removes only its handler; sign-out
cancels in-flight Rust requests, stops progress delivery and clears cookie pools.
Platform-injected URLSession transports remain available for their existing tests.
First login, silent token issuance and byte-preserving low-level request dispatch
are also covered in [moviepilot-contract.md](moviepilot-contract.md); successful
native credential commit now retains the newly authenticated connection pool.

`tests/network_contract.py` exercises the public C ABI against HTTP/1.1 fixtures.
It observes client TCP ports to prove cross-command and cross-domain reuse; checks
headers, token/server/domain cookie isolation, login, eviction and clearing;
cancels a request while other commands remain responsive; checks concurrent SSE
identity and a heartbeat stream lasting more than 30 seconds. Native MoviePilot
fixtures independently verify actual client retention and concurrent progress
routing/cancellation. The full macOS verifier runs both suites.

This contract covers ownership, cookie isolation and these timeout/retry paths.
Native system proxy/Keychain trust, arbitrary injected transport configuration,
full public argument validation and complete business orchestration still require
the broader parity acceptance described in [macos-parity.md](macos-parity.md).

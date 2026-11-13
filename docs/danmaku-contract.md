# Danmaku transport and macOS flow

The production DanmakuGatewayClient retains one Core for its lifetime. All four
HTTP interfaces (match, anime search, episode search and comments) dispatch via
`danmaku.exchange`. The current HTTPS-origin validation and request constraints
remain at the public Swift boundary. Injected URLProtocol sessions keep their
native transport; normal default and ephemeral configurations activate Core.

`danmaku.exchange` accepts `gateway` (`base_url`, `api_key`, `user_agent`), `url`,
`httpMethod`, optional `bodyBase64`, optional `timeoutSeconds` (default 30, range
(0, 300]) and the common `requestId`. It accepts GET search/anime,
search/episodes and non-negative signed-64-bit comments IDs, and POST match,
under the configured origin/path prefix. GET bodies, other routes/methods,
cross-origin requests, userinfo, fragments and malformed arguments are rejected.
Local HTTP origins are supported by the Core ABI for native fixture transports;
the Apple public gateway client continues to require an HTTPS origin.

Successful exchanges return `status`, `headers` and byte-preserving `bodyBase64`,
including non-2xx statuses and malformed/non-UTF8 bodies. Cache and Retry-After
headers reach the existing domain decoder. The Core sends exactly once, leaving
retry settings, business-error mapping and logging with GatewayClient. Transport
failure uses 1501, timeout 1503, invalid arguments 1002 and cancellation 1003.
Cancellation interrupts the in-flight network future on the shared executor.

The macOS automatic flow now always uses DanmakuLoadOrchestrator. The earlier
Core shortcut bypassed cached matches, search degradation and intro sources,
loaded every candidate's comments and reconstructed comments without their IDs
or original modes. Removing that shortcut keeps the complete native matching,
cache/revision checks, alias fallback, manual selection, intro providers and
learning, readiness and generation guards on the production path while the HTTP
work runs through Core. Those orchestration/persistence policies still need
shared implementation for Windows parity; this change does not close that work.

`tests/danmaku_contract.py` checks the exported C ABI against a real local
HTTP/1.1 server. Native RustDanmakuIntegrationTests verify default activation,
injected transport preservation, complete domain responses, shared TCP reuse,
typed errors, exact retry counts and cancellation. Existing DanmakuKit tests
exercise the full native resolver, cache, matching and intro flow. The native
real-server tests invoke the internal exchange boundary to keep fixture HTTP
out of the public HTTPS-origin contract.

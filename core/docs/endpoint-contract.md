# Shared media-server endpoints

Each Core handle may own one endpoint directory. Apple creates a dedicated
handle for each `ServerEndpointDirectory`; concurrent users of the same server
share that directory through `ServerStore`. Endpoint state is independent of
the database, playback session and credential storage.

Policy commands are synchronous and use the standard JSON response envelope.
Invalid arguments use `1002` and do not change the directory. `config` contains
`baseURL`, the complete `candidates` URL array, optional `pinnedURL`, and optional
`expectedServerID`. HTTP(S) URLs are required. Comparison normalizes scheme,
host, default ports, trailing path slash and fragments while retaining original
addresses for requests. Equivalent candidates are deduplicated in order.

| Command | Arguments | Result |
| --- | --- | --- |
| `endpoint.initialize` | `config` | Initial snapshot |
| `endpoint.current` | None | `currentURL`, `pinned`, `candidateCount`, `generation` |
| `endpoint.decision` | Optional `options`, `now` | `decision`: `immediate`, `await_resolution`, or `background` |
| `endpoint.begin` | None | New `generation`, probe `targets`, `expectedServerID` |
| `endpoint.apply` | `generation`, complete successful `results`, optional `options`, `now` | Snapshot, `changed`, `stale`, optional selected `latency` |
| `endpoint.invalidate` | None | Snapshot with an invalidated generation/cache |
| `endpoint.sync` | `config` | Updated snapshot; original session identity retained |
| `endpoint.failureGate` | `failedURL`, optional `options`, `now` | `allowed` for failure-triggered probing |
| `endpoint.probe` | `url`, optional `timeout`, `authorizationHeader`, `userAgent`, `expectedServerID`, `requestId` | Probe result or null |

`results` entries carry `url`, non-negative finite `latency`, and optional
`serverID`. Unknown/removed addresses and a different non-empty server ID are
not eligible. Missing IDs retain the native compatibility behavior. Pinning
limits resolution probes to the pinned address and prohibits automatic failover.
The display-only probe operation remains a host composition of `endpoint.probe`
and never applies its results to selection.

Options default to `cacheTtl: 300`, `unreachableRetryInterval: 5`,
`failureCooldown: 3`, `stickinessRatio: 0.7`, and `stickinessSlack: 0.02`, in
seconds where applicable. Values must be finite/non-negative; the ratio is at
most one. `now` defaults to Unix seconds. A fresh cache returns immediately;
soft expiration returns the current address and lets the host schedule a
background round. First use or invalidation awaits a round. A reachable current
address changes only when the best latency is less than
`currentLatency * stickinessRatio - stickinessSlack`. If the current address
is unreachable, the fastest eligible address wins. No successes retain the
current address and suppress normal reprobes for the unreachable interval.

The host coalesces concurrent requests into one probe task and calls `begin`
once per round. `apply` ignores superseded generations. Network invalidation,
candidate deletion and pin/configuration changes retire old rounds. An older
task cannot restore a removed candidate or overwrite newer selection. Failure
gating suppresses a probe storm and ignores failures from retired addresses.
Apple calls change handlers outside its lock after applying a changed address.

`endpoint.probe` appends `/System/Info/Public` to the original base path, uses
GET, `Accept: application/json`, optional authorization/user-agent headers and
a per-request timeout (default two seconds). It performs one request without
HTTP retries. Non-2xx, transport failure, malformed/non-object payloads, all
four empty public-info fields, identity mismatch, and responses exceeding
64 KiB return a successful null projection. Valid results include the original
URL, elapsed latency, server ID/name, product name and version. Cancellation
uses the normal request lifecycle and `1003`.

The probe connection pool and executor live with their Core handle, so repeated
calls reuse TCP/TLS connections. Destruction joins executor shutdown before the
host may unload the library, including destruction from an async Rust host.
Apple retains injected probe closures and custom URLProtocol configurations;
production default/ephemeral probes use Core. Once selected, a Core probe
failure cannot replay through URLSession.

The Rust media facade resolves the directory before an async request and sends
a fresh profile. Images/stream URLs also read the current profile. Transport
failure of a read may reprobe and issue one Rust request at a newly selected
address. HTTP status failures do not trigger switching. Write/report commands
do not acquire this extra replay. Profiles may supply `authorizationHeader` and
`userAgent`, preserving native device/client identity and current preference
values. The earlier `token` field remains compatible for standalone callers.

Media-server failures preserve HTTP categories with `1600 + status` (401:
`2001`, 403: `2003`, 503: `2103`), timeout/connect/other transport with
`1521`/`1522`/`1523`, decoding with `1514`, and invalid profile with `1002`.
`retryable` remains independent of the numeric code. Apple forwards an expired
credential notification on 401 with the profile ID on the main actor, allowing
its existing account UI to handle reauthentication.

This migration covers address policy and public-info probes. Initial login,
Quick Connect, remaining transport configuration fidelity and connection-pool
ownership of other network clients still require acceptance work. Host task
scheduling and OS network-change signals remain platform integration.

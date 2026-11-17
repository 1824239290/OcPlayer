# Shared standalone Danmaku loading

`OcpDanmakuLoader.load` now runs the complete Core loading flow for a data
consumer. It selects one candidate through the same hash/TMDB/title waterfall,
uses configured caches and resolves intro hints through the same cached,
community, learned, sibling and detected precedence as native player loading.
Player readiness and injection remain specific to the player consumer.

Existing gateway, match request and request-ID call sites remain compatible.
Optional configuration, cache key/revision, aliases, provider settings, output
format, file path, resource timeout and retry count expose the full shared flow.
Manual configuration requires a selected match and forces intro resolution.
Mapping reuse requires a cache opened on the same Core handle. Cancellation and
revision changes prevent stale cache and ID-store writes.

The typed result adds an outcome, diagnostics, raw comment count, kernel-track
payload and intro hint while retaining overlay comments. The loader decodes
`payloadJSON` directly so episode/anime identifiers remain exact Int64 values.
No-match and empty-comment outcomes remain distinct. Errors use the existing
Core error envelope.

Three public binding tests use the same HTTP fixture as Core's ten direct ABI
cases. The exported and native binding sources/fixtures are checked for
equivalence. The complete macOS verification passes all 17 binding tests, all
seven native packages, and the application's 1008 tests with 19 platform skips
and zero failures. The embedded signed application also passes playback-control
checks with zero render/audio failures. Full raw evidence is retained in the
OcPlayer-Core repository under `docs/validation/2026-11-14-standalone-load/`.

# OcPlayerCore

Swift adapter for the OcPlayer-Core C ABI. The blocking native commands run on
workers with request reservation/cancellation; playback commands expose native
session snapshots. The package also provides Bangumi and danmaku bridge helpers.
Native UI, decoding/rendering and credential storage remain platform-owned.

Use `response.decodeData(MyPayload.self)` for typed command results with integer
identifiers. It reads the original ABI response bytes and preserves Int/UInt
ranges, including nested fields; the generic `response.data` uses Double for
numbers. Both synchronous `call` and asynchronous `callAsync` provide the typed
path, and responses remain usable after the client is retired.

Enable with `OCP_CORE_ENABLED=1`, the matching UserDefaults key, or the
`OcpCoreEnabled` bundle flag. The adapter discovers `libocp_ffi.dylib` in the
application's frameworks/resources directories; `OCP_CORE_LIBRARY_PATH` can
select a specific library during development and integration tests. Explicit
environment/UserDefaults settings override the bundle default.

The Core repository's `Scripts/embed-macos-core.sh` validates, embeds and signs
a built application. `Scripts/verify-macos.sh /path/to/OcPlayer` runs the native
Rust/Swift package checks and produces an embedded macOS application. The broader
functional acceptance and outstanding migrations are tracked in the Core
repository's `docs/macos-parity.md`.

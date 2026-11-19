# OcPlayerCore

Swift adapter for the OcPlayer-Core C ABI. The blocking native commands run on
workers with request reservation/cancellation; playback commands expose native
session snapshots. The package also provides Bangumi and danmaku bridge helpers.
Native UI, decoding/rendering and credential storage remain platform-owned.

The source package loads a matching dylib at runtime on macOS. On iOS its
conditional `NativeFFI` dependency imports the canonical C ABI header and
directly links `libocp_ffi.a`. The application's Xcode build phase runs
`Scripts/build-ios-static.sh`, stages the current platform/architectures under
`BUILT_PRODUCTS_DIR/OcPlayerCoreNative`, and supplies that library search path.
Install the needed Rust targets with `rustup target add aarch64-apple-ios
aarch64-apple-ios-sim x86_64-apple-ios`; external source-package consumers must
also build the archive and supply its search path. Homebrew Rust with rust-src
can opt into source-built std using `OCP_CORE_BUILD_STD=1` in the build environment.

The release package made
by `Scripts/build-apple-xcframework.sh` includes a binary `OcPlayerCoreFFI`
dependency and directly references the twelve C ABI functions. This retains
the static Core in optimized, stripped macOS/iOS builds without dynamic symbol
exports. Both package forms expose the same Swift API and contract tests.

Use `response.decodeData(MyPayload.self)` for typed command results with integer
identifiers. It reads the original ABI response bytes and preserves Int/UInt
ranges, including nested fields; the generic `response.data` uses Double for
numbers. Both synchronous `call` and asynchronous `callAsync` provide the typed
path, and responses remain usable after the client is retired.

The existing media-server migration is enabled with `OCP_CORE_ENABLED=1`, the matching UserDefaults key, or the
`OcpCoreEnabled` bundle flag. The adapter discovers `libocp_ffi.dylib` in the
application's frameworks/resources directories; `OCP_CORE_LIBRARY_PATH` can
select a specific library during development and integration tests. Explicit
environment/UserDefaults settings override the bundle default.
File libraries call Core independently of this migration switch. On iOS no
runtime library copy or dynamic export is needed for the static path.

The Core repository's `Scripts/embed-macos-core.sh` validates, embeds and signs
a built application. `Scripts/verify-macos.sh /path/to/OcPlayer` runs the native
Rust/Swift package checks and produces an embedded macOS application. The broader
functional acceptance and outstanding migrations are tracked in the Core
repository's `docs/macos-parity.md`.

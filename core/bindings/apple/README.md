# Apple Swift binding

`OcPlayerCore/` is a standalone Swift package for the shared C ABI. It contains
the same adapter source and tests used by the OcPlayer Apple application;
`Scripts/check-apple-binding.sh /path/to/OcPlayer` verifies their equivalence.
Update both copies together when changing the ABI adapter.

Consumers can declare a local Swift package dependency on
`/path/to/OcPlayer-Core/bindings/apple/OcPlayerCore` and import `OcPlayerCore`.
The host must embed the matching dylib (or provide `OCP_CORE_LIBRARY_PATH` in
development). The package discovers the library at runtime and checks its
exports; no third-party Swift package dependency is needed.

For static macOS/iOS distribution, add the package directory produced by
`Scripts/build-apple-xcframework.sh`. It includes the XCFramework, matching Swift
sources, C module map, system linker settings, tests, license and SHA-256 release
manifest. Its direct C references work when dynamic ABI symbols are stripped.
`Scripts/verify-apple-release.sh /path/to/release-package` verifies that delivery.

Native application domain facades and UI are in the OcPlayer Apple checkout.
The self-contained binding provides JSON commands, cancellation, events,
snapshots, surface calls, and playback/Bangumi/danmaku bridge helpers.

## Native macOS HDR presentation

The Core-enabled native client uses liberika for video rendering. For the
v0.3.6 macOS PQ clipping fix, use `Scripts/build-macos-hdr-fixed.sh` from the
Core repository; it applies the versioned native patch in isolated source copies,
embeds Core and verifies the application. See `docs/macos-hdr.md` for the
source/build contract and the measured staircase regression evidence.

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

Native application domain facades and UI are in the OcPlayer Apple checkout.
The self-contained binding provides JSON commands, cancellation, events,
snapshots, surface calls, and playback/Bangumi/danmaku bridge helpers.

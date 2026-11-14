# Platform packaging

The ABI has two Apple delivery forms:

The workspace includes `Cargo.lock`; build and verification scripts use
`--locked` so a clean checkout retains the validated dependency resolution.

- `Scripts/build-apple-xcframework.sh` builds the static `OcPlayerCore.xcframework`
  for macOS, iOS, and iOS Simulator once the corresponding Rust targets are
  installed. The output directory is a complete local Swift package, including
  all adapter sources/tests, C module map, license and release hash manifest.
  It contains macOS arm64/x86_64, iOS arm64, and simulator arm64/x86_64 slices.
  Default minimum versions match the binding: macOS 13 and iOS 16. The script
  remaps checkout paths, preserves locked dependencies and refuses to overwrite
  an existing delivery.
- `Scripts/build-apple-dylib.sh` builds `libocp_ffi.dylib` for a host/debug
  integration. Copy that file into the app bundle's `Contents/Frameworks` (or
  `Frameworks` on iOS) and keep the checked-in `include/ocplayer_core.h` beside
  the artifact for native consumers.

The source Swift package searches `OCP_CORE_LIBRARY_PATH` first, then the app's
private frameworks/resources directories. The generated static package directly
links the ABI through `OcPlayerCoreFFI`; it does not require exported executable
symbols or an embedded dylib. Both support an explicit library path override.
Enable Core through `OCP_CORE_ENABLED=1` or the `OcpCoreEnabled` bundle flag after
including the matching library. An explicit `0` remains a comparison fallback.

Static release verification:

```bash
Scripts/build-apple-xcframework.sh /path/to/new-release-package
Scripts/verify-apple-release.sh /path/to/new-release-package /path/to/verification
```

Verification runs the complete Swift contracts against the static package in
release mode, compiles and links the Swift adapter against all five SDK/architecture
combinations, checks manifest bytes, and executes arm64 and x86_64 macOS probes
with dynamic Core exports hidden and linker dead stripping enabled. An Apple
Silicon host needs Rosetta for the Intel probe. iOS device/simulator runtime
verification and distribution signing/notarization are separate from these
compile/link and local macOS checks.

Windows consumes the same header and DLL exports through
`bindings/windows/OcPlayerCore.cs`. The Windows native player surface and complete adapter remain implementation
work. Windows runtime verification is deferred by the user; the shared API and
C# binding are available for that adapter.

For a built macOS application, run:

```bash
Scripts/build-apple-dylib.sh
Scripts/embed-macos-core.sh /path/to/OcPlayer.app
```

The embed script verifies architectures and all C ABI exports, copies the dylib
into `Contents/Frameworks`, sets the `OcpCoreEnabled` bundle flag, and signs the
library and application. It defaults to ad-hoc signing for local validation;
set `OCP_SIGNING_IDENTITY` for a distribution identity before notarization.
The Apple adapter reads the bundle flag after environment/UserDefaults overrides.
An explicit override of `0` remains available for comparative testing.

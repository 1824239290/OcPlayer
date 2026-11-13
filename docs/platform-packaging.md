# Platform packaging

The ABI has two Apple delivery forms:

The workspace includes `Cargo.lock`; build and verification scripts use
`--locked` so a clean checkout retains the validated dependency resolution.

- `Scripts/build-apple-xcframework.sh` builds the static `OcPlayerCore.xcframework`
  for macOS, iOS, and iOS Simulator once the corresponding Rust targets are
  installed.
- `Scripts/build-apple-dylib.sh` builds `libocp_ffi.dylib` for a host/debug
  integration. Copy that file into the app bundle's `Contents/Frameworks` (or
  `Frameworks` on iOS) and keep the checked-in `include/ocplayer_core.h` beside
  the artifact for native consumers.

The Swift adapter searches `OCP_CORE_LIBRARY_PATH` first, then the app's private
frameworks/resources directories. When the library is absent, the feature flag
falls back to the native implementation. Release builds should set
`OCP_CORE_ENABLED=1` only after the artifact has been embedded and signed.

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

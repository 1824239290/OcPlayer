# Platform packaging

The ABI has three Apple delivery forms:

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
  integration; `Scripts/build-apple-dylib.sh --universal /path/to/output` builds
  both macOS architectures for a universal Release app. Copy that file into the app bundle's `Contents/Frameworks` (or
  `Frameworks` on iOS) and keep the checked-in `include/ocplayer_core.h` beside
  the artifact for native consumers.
- `Scripts/build-ios-static.sh /path/to/library-directory` builds the iOS
  source checkout for Xcode's `PLATFORM_NAME`, `ARCHS`, `CONFIGURATION` and
  deployment target. The ordinary iOS App runs it before linking, combines
  multiple simulator architectures with lipo, and stages `libocp_ffi.a` under
  `BUILT_PRODUCTS_DIR/OcPlayerCoreNative`. The source package's conditional
  `NativeFFI` system module imports the canonical header and directly references
  the ABI. Neither a runtime dylib nor dynamic executable exports are required.
  CI installs the device/simulator Rust targets; Homebrew Rust with rust-src can
  explicitly opt into source-built std with `OCP_CORE_BUILD_STD=1`.

On macOS the source Swift package searches `OCP_CORE_LIBRARY_PATH` first, then the app's
private frameworks/resources directories. The generated static package directly
links the ABI through `OcPlayerCoreFFI`; it does not require exported executable
symbols or an embedded dylib. Both support an explicit library path override.
Enable Core through `OCP_CORE_ENABLED=1` or the `OcpCoreEnabled` bundle flag after
including the matching library. An explicit `0` remains a comparison fallback.
File libraries use Core independently of this existing media-server migration
switch. iOS AppTests run the ordinary App build with static Core and reject an injected
Core dylib, so tests cannot mask missing or dead-stripped static linkage.

File-library simulator verification (with a booted simulator and Python
containing `impacket==0.13.0`):

```sh
Scripts/test-ios-file-library.py SIMULATOR_UDID --smb-python /path/to/venv/bin/python
```

This builds and signs the ordinary iOS test host, starts the shared SMB fixture
on the Mac using its unchanged source, and forwards its loopback addresses to
the test process. TMDB and WebDAV fixtures run inside the test host. The selected
tests include local movies/TV/S0, offline snapshots/progress, credential recovery,
actual SMB/WebDAV Erika open and seek, and server progress/source regressions.
The SMB host test reports a skip when run without the dedicated fixture; that
skip is not protocol coverage. These fixtures do not replace physical-device
directory grants or real NAS/SMB3-encryption acceptance.

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
work. Windows x64 Core DLL and C# SDK runtime verification is now available through
`Scripts/verify-windows.ps1`; see the [Windows SDK guide](../bindings/windows/README.md)
and [2026-11-14 Windows results](validation/2026-11-14-windows/README.md).
Native decoder/render/audio and complete Windows player acceptance remain separate.

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

# Windows native HDR/SDR mapping fix

OcPlayer-Core owns business policies and the stable ABI. Windows video decoding
and presentation belong to the native Erika adapter. This delivery retains the
Windows renderer change as a versioned patch and an isolated build entry point,
following the existing [macOS HDR delivery](macos-hdr.md).

The fix applies to the local Erika v0.1.7 Dolby Vision branch at base commit
`d9334c6f8dcc87d4131d056ef4692f643b231c6c`. It is distinct from the macOS v0.3.6
patch and does not change official dependency pins or installed applications.

## Change and platform scope

The D3D11 renderer checks the window's actual DXGI display before enabling HDR10,
honors explicit SDR output, and refreshes stale display factories. HDR targets
use the display-reported peak and Windows SDR white level separately. Missing or
invalid luminance information uses finite defaults and remains marked unknown.
PQ's 10,000-nit encoding ceiling is not reported as the screen's HDR headroom.

HDR-to-SDR uses the BT.2446 Method A luminance curve with one gain applied to RGB
maximum, preserving channel ratios. This is not a complete implementation of
Method A's chroma correction procedure. Compressed HDR-to-HDR uses the zero-black
BT.2390 EETF in PQ space. Mapping is disabled when unnecessary. On an SDR desktop,
the target retains the standard 100-nit reference: the reported panel maximum
does not measure the panel at the user's current SDR brightness. Explicit SDR on
an HDR desktop instead uses Windows' queried SDR white for peak and normalization.

The patch modifies only `crates/erika/src/renderer/d3d11.rs`, Windows-target
dependency features in `crates/erika/Cargo.toml`, and the Windows native demo.
The D3D11 module and demo are guarded by `cfg(target_os = "windows")`. Shared
color pipeline code, Metal rendering, Apple bindings, XCFramework slices and the
macOS HDR patch are unchanged. This fix does not alter macOS or iOS render paths;
no new Apple hardware run is claimed.

## Build an isolated test program

Requirements: Windows x64, Rust, Git, MSVC Build Tools/Windows SDK, LLVM libclang,
and a native checkout containing the exact base and its compatible bundled
Windows x64 LGPL dependencies under `third_party/dist`. The script reuses that
dependency directory through a junction and creates fresh source/target folders.
It does not overwrite the supplied native source, existing output or media.

From OcPlayer-Core in PowerShell:

```powershell
.\Scripts\build-windows-hdr-fixed.ps1 `
    -KernelRoot 'D:\DevCache\Erika-Dolby' `
    -OutputDirectory 'D:\OcPlayer-Core\artifacts\windows-hdr-rebuild' `
    -LibClangPath 'D:\DevCache\tools\llvm\bin' `
    -CargoCacheRoot 'D:\DevCache\cargo-home'
```

Adjust `-VcVarsPath` for another Visual Studio installation. Add `-PrepareOnly`
to verify and inspect the patched source without compiling. Complete builds run
the D3D11 suite, build the native demo and record source/patch/binary identities
in `build-receipt.json`.

Play a local sample using the returned executable:

```powershell
& '<output>\KernelTarget\x86_64-pc-windows-msvc\debug\windows_native_demo.exe' `
    'D:\凡人修仙传 - S01E200 - 第 200 集.mp4' `
    --platform-native --output-mode auto
```

The title identifies `Erika Windows HDR Fix 2026-11-15`. Space toggles playback;
left/right seek five seconds. `--frame-at 180` opens and pauses near three minutes
for visual comparison; `--output-mode sdr` tests explicit SDR output. The demo
does not integrate the OcPlayer-Core policy DLL or the unfinished Windows shell.

See [the validation report](validation/2026-11-15-windows-hdr/README.md) for the
17 passing D3D11 checks, actual offscreen shader grayscale results, local playback
measurements and the user's visual acceptance on the current SDR display. True
HDR-display calibration and other hardware remain outside that acceptance.

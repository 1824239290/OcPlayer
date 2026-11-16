# Windows Core SDK

The SDK targets .NET 10 and loads `ocp_ffi.dll` through the stable C ABI.
`OcpCore` owns native handles and strings; `OcpCoreClient` projects responses,
snapshots and events without converting integer identifiers to floating point.
Set `OCP_CORE_LIBRARY_PATH` or pass an explicit library path before the first
native call. Use `CallAsync` for blocking network commands and cancellation.

## Windows x64 verification

Requirements: x64 Rust MSVC toolchain, Visual Studio 2022 C++ x64 Build Tools
with C11 atomic support, .NET 10 SDK, Python 3 and 64-bit PowerShell.
Run from the repository root:

```powershell
.\Scripts\verify-windows.ps1 -Python python
```

Pass the absolute Python executable if it is not on PATH. After dependencies
have been downloaded, `-Offline` keeps Cargo offline. The default build is
debug; `-Configuration release` checks an optimized Rust DLL. C# contracts
always build in Release. Results and complete logs go to
`artifacts/windows-verification/`, or the supplied `-OutputDirectory`.

The script runs the locked Rust workspace tests, builds the real Windows DLL
and CLI, builds C native fixtures and the C# SDK, checks handle/string ownership
and cancellation against the fixture, checks missing exports, then runs the
C# contracts against the real DLL and all shared Python C ABI suites. Local
HTTP fixtures and temporary SQLite/cache files exercise the business surface
without remote accounts. The C# real-DLL contracts also create and destroy a
hidden Win32 HWND to check the surface adapter's handle, resize and event path.
The CLI playback fixture is replayed at the end.

Two transport comparisons require an independent Apple URLSession probe and
are explicitly skipped on Windows when that probe is unavailable. Portable
tests still check gzip, deflate, Brotli, retained raw headers, rejected stacked
encoding without replay, redirects and incremental compressed SSE.

`WindowsPlayerSurface` forwards HWND and lifecycle metadata. A successful test
does not establish video decoding/rendering, audio output, WinUI integration,
HDR, real subtitles or native-player acceptance; those require the completed
Windows player adapter. x86 and ARM64 need separate builds and runtime runs.

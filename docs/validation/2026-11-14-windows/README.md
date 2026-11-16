# Windows x64 Core/SDK verification — 2026-11-14

The shared Core and C# SDK now build and run on this Windows 11 x64 host.
This run starts from `fa75810e943862e5da63431a6a8bbb7d1cef8f04` plus the
uncommitted Windows test/tooling changes recorded in `verification-results.json`.
Production Rust and C# SDK implementation files were unchanged. The Rust DLL is
a **debug/dev build**; the C# SDK and contracts are **Release builds**. This is
Core/SDK acceptance, with surface metadata forwarding, not a completed Windows
native-player or distribution release.

## Final results

| Scope | Executed | Passed | Skipped | Failed/errors |
| --- | ---: | ---: | ---: | ---: |
| Rust workspace | 212 | 212 | 0 | 0 |
| C# native-fixture contracts | 55 assertions in 10 groups | 55 | 0 | 0 |
| C# missing-export contract | 1 assertion | 1 | 0 | 0 |
| C# real Windows DLL contracts | 31 assertions in 3 groups | 31 | 0 | 0 |
| Python C ABI, 33 suites | 218 test declarations | 216 | 2 | 0 |
| CLI playback fixture replay | 5 command responses | 5 | 0 | 0 |

These scopes overlap and are not added into a claimed unique grand total.
The ABI runner executes each declared test once, retaining inherited fixture
helpers without rediscovering their test methods. The public command tests also
exercise all 370 production methods with 4,810 negative argument/request-ID
subcases; those subcases are not counted as separate test declarations above.

See [the consolidated machine-readable receipt](verification-results.json),
[the runtime receipt](runtime-results.json), [Rust tests](rust-tests.log),
[ABI tests](abi-contracts.log), [C# fixture tests](sdk-mock.log),
[C# real DLL tests](sdk-real.log), [missing exports](sdk-missing.log),
[C# build](dotnet-build.log), and [CLI replay](cli-replay.log).
The receipt includes toolchain versions, source-input hashes and binary hashes.

## Verified behavior

- C# native DLL loading, required export checking, UTF-8 and exact signed/unsigned
  integer projections, independently owned response/event/snapshot data.
- Native handle and string ownership, finalization, cancellation, duplicate and
  reusable request IDs, disposal during active calls, and 25 cross-thread
  dispose/native-call races in the fixture.
- Real Rust HTTP cancellation, playback state/settings/validation, snapshots and
  ordered events. A real hidden HWND is created, attached, resized and detached,
  then destroyed; this only establishes opaque-handle and lifecycle forwarding.
- Shared SQLite/cache/progress, media-server routes and nullable projections,
  TMDB, danmaku/intro, Bangumi, MoviePilot, repository flows, backup, preferences,
  diagnostics, HTTP connection/cookie isolation, retry rules and streaming.
- gzip, deflate and Brotli decoding, original response headers, first-member gzip,
  rejected stacked encoding without replay, redirects, malformed compression,
  and compressed SSE delivery before response completion.

Two independent Apple URLSession comparisons require an Apple-built probe and
are explicitly skipped on Windows. Portable Core transport checks above run
normally. No remote account/server or credential was used.

## Windows test/tooling corrections

The C fixture now uses exported Windows DLL functions and `Sleep(1)` on Windows,
while retaining its POSIX path. Python fixture subprocesses use `sys.executable`;
database-change tests use disposable platform-native temp directories. UTF-8
source/cache reads are explicit. The directory-alias test uses a Windows junction
without requiring symbolic-link privileges, retaining the alias-protection and
failed-export cleanup assertions. C# receipts now report the actual host OS and
architecture instead of a hard-coded `windowsRuntimeTested: false`.

`Scripts/verify-windows.ps1` builds/tests the locked Rust workspace, compiles the
native fixtures and C# SDK, runs fixture/real-DLL/ABI checks, and replays the CLI
fixture. `tests/windows-sdk/run_contracts.py` owns the local slow HTTP fixture,
test selection and runtime receipt. See the [SDK guide](../../../bindings/windows/README.md)
for prerequisites and invocation.

Preliminary evidence is retained: an overlapping first build encountered a
locked test executable; the first slow-server fixture did not delay the protocol
routes appended by `endpoint.probe`; and an earlier ABI run exposed default-GBK
reads and missing symlink privileges. Its generic discovery also rediscovered
inherited/imported tests. The final run is serial, uses the corrected fixtures,
and selects the 218 declared tests once. Preliminary runs are not counted as
final passing executions. Intentional cancelled/failed HTTP fixtures can log
Windows connection-abort/reset exceptions from their server threads; these are
not Rust/Core failures and the final unittest outcome is successful.

## Remaining acceptance

Actual decoding/rendering, audio, WinUI integration, HDR, native subtitle display,
credential/system adapters and a complete Windows player remain unimplemented
or outside this run. An optimized Rust release DLL, delivery packaging, x86,
ARM64, other Windows builds and real service/media playback need their own runs.
Earlier macOS validation records retain their original scope.

Subsequent local-file tests are recorded in the
[Windows real-video comparison](../2026-11-14-windows-video/README.md). They
exercise the external Erika native example and FFmpeg independently, followed
by separate Core policy checks; they do not add native-player integration to
this Core/SDK acceptance run.

## Pre-commit recheck — 2026-11-17

The complete `Scripts/verify-windows.ps1` workflow passed again on Windows x64
before committing the validation tooling. The source was `700cd61` plus this
test/tooling change, including the explicit-episode filename regressions and
Bangumi episode collection validation fix. Rust workspace tests passed 214/214;
the native fixture, missing-export and real-DLL C# checks passed 55/55, 1/1 and
31/31; shared Python ABI tests passed 216 with the same two Apple-only skips;
and the CLI playback fixture completed successfully. `cargo fmt --all --
--check` and the public Core surface inventory also passed.

The recheck retained the debug/dev Rust and Release C# configurations. Its Core
DLL SHA256 was `c31729cea5807c1eab3d0324339fd63efc43ea61ad7e69064871b7aa7c4d44e5`.
Fresh logs remain in the ignored local directory
`artifacts/windows-verification-commit-check/`; the adjacent November 14
receipts retain their original date, source hashes and results. The initial
recheck encountered the WindowsApps `python.exe` placeholder; rerunning with an
absolute Python 3.12.14 executable completed the workflow.

# Core diagnostic export parity — 2026-11-14

Core now exports native diagnostic archives and ordered kernel trace tails to an
exclusively created file. macOS flushes and holds its existing sink queue while
Core runs, loads the final Data off the main thread and removes the temporary
file. The original native implementation remains available with Core disabled.
Headers, platform facts, trace selection and the file-export panel stay native.
See [the contract](../../diagnostic-export-contract.md).

| Final evidence | Result |
| --- | --- |
| Rust workspace and independent locked/offline source copy | 204 passed each; 8 new diagnostic cases |
| Public C ABI | 194 passed in 30 suites; 9 diagnostic cases including legacy JSON compatibility |
| Exported Apple SDK | 30 passed; 4 new diagnostic cases |
| Eight native packages | 1382 passed; DiagnosticsKit 97 and native SDK 30 |
| macOS AppTests | 1018 executed: 999 passed, 19 platform skips, zero failures |
| Core disabled JellyfinKit | 288 executed: 273 passed, 15 Core-only skips |
| Core disabled app preparation/continuation/failover and diagnostics | 33 executed: 32 passed, 1 Core-only skip |
| Frozen inputs | 73 Core source + 786 native + 64 gate/binding files unchanged |
| SDK reference | 3 entity files unchanged at recorded SDK commit |
| Signed bundled app | Deep strict signature passes; all 14 runtime sections match |
| Actual bundled controls + natural EOF | Both processes exit zero; no rendering/audio failures |

Five app tests explicitly require Core activation and compare complete bytes
against the original native exporter. They cover modification-date/name ordering,
archive filters and file aliases, full/zero/negative/bounded budgets, charging
actual retained bytes, incomplete/no-newline tails, UTF-8 code points spanning
files and chunks, over 64 KiB of invalid byte patterns, ordered trace headings,
missing traces, and the six-pass native sanitizer. The corpus includes local home
paths versus server Users routes, container paths, URL credentials/query/fragment
and punctuation, quoted assignments, Unicode case folding, Basic/Bearer and JWT.
The settings path verifies queued-record visibility and temporary-file cleanup.
Two DiagnosticsKit cases cover the synchronized queue boundary and recovery after
a throwing export operation.

The existing `diag.export` JSON snapshot alias and its options remain unchanged;
file output uses the separate strict `diag.exportFile` command. The ABI also
covers legacy JSON compatibility, strict input types, concurrent exports on a shared Core,
small reports, exclusive output ownership, directory aliases, cleanup after a
failed whole-file read and nullable unlimited budgets. A streaming UTF-8 writer
was corrected to process repeated invalid bytes linearly. Its behavior is checked
against joined-byte decoding. A dynamic home-path regex compile failure is a
structured invalid-input error rather than a panic. A 64 KiB output buffer also prevents one file write per invalid byte. A local
8 MiB all-invalid-byte fixture produced identical 25,165,833-byte output and SHA256
before/after buffering: 16.473 seconds versus 0.0468 seconds in the targeted run.
The final library repeats the same exact-output fixture; summary.json records
that run. These are single local stress observations, not a general performance
or peak RSS certification. No whole-product completion is claimed.

All raw gate, build, test, disabled-mode, signing and runtime logs are preserved,
including initial fixture compile failures and the queue fixture that incorrectly
assumed a fixed current-log filename. The first complete gate passed before output
buffering; its full logs, library, source module and input manifests are retained
separately. The intermediate buffered gate is also retained. Final acceptance
reruns the
complete gate after both buffering and command compatibility correction, using
the dedicated real DerivedData
directory. Input manifests, SDK reference hashes, the independent
source-copy path and verifier scripts are included; summary.json records exact
counts and runtime-section hashes.

Native settings mapping, remaining SDK schema/transport and public ownership
coverage, Apple release/framework slices and Windows adapter implementation
remain active. Windows runtime testing remains deferred by the user.

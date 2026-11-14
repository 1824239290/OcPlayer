# Core settings backup parity — 2026-11-14

Core now owns the current format-v1 settings backup schema, snapshot defaults and
option rules, Unicode key summary and ordered restore plan. macOS supplies 31
Foundation preference getter/cast facts, six TMDB coordinator values and one raw
gateway fact, then applies the returned effects through its original stores.
All 38 module fields are covered. Native file access/security scope, Date/model
codecs, pretty/sorted JSON, localized errors and file panels remain adapters.
Existing Core configuration and diagnostic JSON aliases stay unchanged. See
[the contract](../../settings-backup-contract.md).

| Final evidence | Result |
| --- | --- |
| Rust workspace and independent locked/offline source copy | 212 passed each; 8 new backup policy cases |
| Public C ABI | 203 passed in 31 suites; 9 new backup cases |
| Exported Apple SDK | 35 passed; 5 new settings backup cases |
| Eight native packages | 1387 passed; native Core SDK 35 |
| macOS AppTests | 1026 executed: 1007 passed, 19 platform skips, zero failures |
| Core disabled JellyfinKit | 288 executed: 273 passed, 15 Core-only skips |
| Core disabled app flows and diagnostics/configuration | 59 executed: 58 passed, 1 Core-only skip |
| Frozen inputs | 74 Core source + 790 native + 67 gate/binding files unchanged |
| SDK reference | 3 entity files unchanged at recorded SDK commit |
| Signed bundled app | Deep strict signature passes; all 14 runtime sections match |
| Actual bundled controls + natural EOF | Both processes exit zero; no rendering/audio failures |

Eight enabled app cases require Core activation and compare complete snapshots,
encoded files, target preference domains, summaries and localized errors against
the original native implementation. Existing 18 backup tests also pass. Coverage
includes absent/default/explicit-false values, Foundation coercions and casts,
invalid enum/source colors, full module restore, nullable subtitle style, empty
credentials/gateway/home-sections, complete mirror overwrite, raw versus trimmed
strings, exact Int64/UInt32 values, first duplicate keys, ignored unknown values,
legacy mirror enabled, fractional/normalized/offset/trailing-text ISO dates,
UTF-16/UTF-32 files, security-scoped reading and grapheme-based key tails.

Foundation runtime probes established first-key semantics and exact integral
floating/exponent decoding. Decimal integer digits never round through f64;
endpoint floating spellings keep native rejection. Newer versions are rejected
only on file import after full shape validation. Encoding/summary still accepts
in-memory future versions, matching native fixtures. Initial app comparison caught
an adapter codec that reused import version checking during encoding; this was
fixed by separating typed model conversion from the import gate. Original failing
build/fixture/comparison logs and probe code are preserved.

The host predecodes/validates all effects before writes. TMDB side effects/cache
normalization and Dandanplay gateway setter retain their original behavior; server
session credentials and Dandanplay API Key are never collected or overwritten.
Restore order matches native behavior. Core-disabled checks include all 26 backup
cases alongside existing app flow/diagnostic checks. No whole-product completion
or general release-performance claim is made.

Raw gate, build, package/app tests, disabled mode, signing and runtime logs are
preserved together with input hashes, SDK reference, independent copy path and
verifier scripts. Acceptance uses a dedicated real DerivedData directory. The
previous diagnostic stress fixture also passes with identical output bytes/hash.

Remaining SDK schema/transport and public ownership coverage, Apple release and
framework slices, and Windows adapter implementation remain active. Windows
runtime testing remains deferred by the user. Remaining native settings coverage
is audited against the broader acceptance scope before whole-goal completion.

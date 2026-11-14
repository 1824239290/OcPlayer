# Portable native settings backup contract

The additive `settings.backup.*` interface owns the current format-v1 backup
schema, preference snapshot policy, masked summary and ordered restore plan.
Existing `settings.schema`, `config.export/import/validate` and `diag.export`
keep their original Core configuration/snapshot semantics.

`capabilities` declares format/schema version 1 and five modules: tmdb, playback,
danmaku, general and mirror. `snapshot` accepts host preference getter facts
(`present`, `value`), current TMDB coordinator values, raw customized gateway and
platform metadata (ISO export time, app version, optional device name). The host
performs Foundation coercions/casts and key access; Core selects defaults, valid
retention/language/upscaler options, nil subtitle colors/style, mirror trimming
and explicit gateway presence. All 38 existing module fields are represented;
31 preference keys plus six TMDB values and one gateway fact are mapped.

`decode` accepts `inputBase64`, preserving original file bytes. UTF-8/BOM,
UTF-16 and UTF-32 with/without BOM are recognized. Known required/nonnullable
fields remain required; optional absent/null modules and properties stay absent.
Unknown properties are ignored. Like Foundation JSONDecoder, duplicate keys
use their first occurrence. Integral decimal/exponent tokens retain exact
integer digits; malformed/nonintegral/out-of-range Int64/UInt32 values are
rejected. Int64 endpoint floating spellings retain native rejection behavior.
Finite Double, Bool and String fields retain their native types. The ISO date
validator preserves covered native fractional/offset/variable-width/normalized
day-time and trailing-text forms; the Apple date codec retains actual Date
conversion and locale formatting.

Mirror's legacy `enabled` is read even when the newer flags are explicit. Missing
or null new flags fall back to legacy, then false. Encoding only emits the new
flag names. File decode checks `formatVersion > 1` after complete schema decode;
0/negative versions remain accepted, matching the native gate. `prepare` (and
restore/summary projection) permits newer-version in-memory values, preserving
native encoding/summary behavior and the ability to create future-version test
fixtures. Empty bytes return nonretryable 2701 with `kind=emptyData`; invalid
schema/bytes return 2702/invalidFormat; future file versions return
2703/unsupportedVersion and the exact version. The host preserves existing
localized ConfigBackupError messages and security-scoped file access.

Projection replies contain canonical `backupJSON`, a typed summary and ordered
effects (`target`, semantic `field`, `operation`, `valueJSON`). Canonical integer
values remain exact across the SDK; large scalars do not pass through its generic
Double projection. The host's existing JSON encoder retains pretty/sorted output,
ISO seconds, model bindings and FileDocument. Masked keys use the last four
extended grapheme clusters; date/device display facts remain native.

Restore only changes present modules. Null subtitle style fields skip writes;
empty/missing TMDB Key and customized gateway retain target credentials/settings.
Invalid subtitle-language/upscaler strings skip those writes. Other imported
numeric values retain the original coordinator's behavior, with no new range
clamping. Mirror's two flags and three addresses are one overwrite group:
missing/empty/whitespace addresses remove keys, nonempty addresses retain their
raw input. Missing/empty home-sections strings skip writes. Core's order matches
the original TMDB, playback, danmaku, mirror and general effects. The host decodes
and validates every effect before writes, then uses the original TMDB/Dandanplay
setters and UserDefaults. Server/session credentials and Dandanplay API Key are
never part of the snapshot or effects; the existing TMDB-Key backup exception is
preserved.

Core-disabled builds retain the original native implementation. Enabled tests
require Core activation and compare full snapshots, encoded files, summaries,
localized errors and target preference domains against that native reference.
See the full validation report for original logs and frozen input evidence.

# Diagnostic export contract

`diag.exportFile.capabilities` reports schema version 1 and file output. `diag.exportFile`
runs outside the shared state mutex and writes an exclusively created destination.
The existing `diag.export` JSON snapshot alias remains unchanged. The file-export command’s strict arguments are `logDirectory`, `outputPath`, `headerLines`, nullable
`bodyByteBudget`, `traces` (`path`, `name`, `maxBytes`) and `username`. Paths must be
absolute. The output must be separate from the log directory and trace inputs;
existing destinations are preserved, including symlink aliases. A failed export
removes only the new destination. Invalid arguments return nonretryable 1002;
file errors return nonretryable 1502. The reply contains path, byte count,
skipped log names and included trace statistics; log contents stay outside JSON.

The host flushes suppression summaries and holds the diagnostic sink's serial
queue while Core exports. Core orders matching archives by modification date,
then name, and appends the current file in that same order. Matches are
`diagnostics.jsonl`, `diagnostics-*.jsonl`, and `diagnostics.jsonl.*` excluding
`.lock` suffixes. A missing/unreadable directory produces no body. Unlimited
exports read every matching file and propagate read failures. Bounded exports
walk newest to oldest, charge actual retained bytes and discard partial first
lines when seeking into files. Empty/unreadable tails reclaim budget for older
archives. A whole-file read failure remains an error, matching the native sink.
Negative budgets clamp to zero. Selected chunks are emitted chronologically.
UTF-8 is repaired after joining archive bytes, including code points spanning
file/chunk boundaries. Headers are joined with newlines and two trailing newlines.
The budget applies to raw body bytes before UTF-8 repair, excluding headers and
traces; repaired byte counts may therefore exceed that raw budget.

Traces follow caller order. Missing/unreadable/empty traces are omitted. Each tail
has its own byte limit; a truncated trace drops through its first newline, but
keeps a suffix when no newline exists. Limits clamp to zero. Trace headings and
truncation annotations retain the native Chinese text and integer MiB value.
Only traces are redacted here; body records were sanitized when logged. The
six native passes replace this username's home paths, app-container paths,
HTTP(S) credentials/query/fragment, Basic/Bearer values, secret assignments and
JWT-like tokens, preserving placeholders and punctuation. Server `/Users/ID`
routes remain unless they match the supplied local username. Existing native
URL authority parsing (including URLs with no path slash) is retained.

The Apple SDK exposes a typed file report and file-URL validation. The macOS
settings flow uses a new temporary output, loads its final Data and removes the
temporary file. Core-disabled builds use the original native export. Native
headers, platform/version/time facts, trace file names, file-export UI and sink
ownership remain native. No Core runtime error is silently replayed through the
fallback. Streaming file output avoids a large JSON body; no new measured peak
RSS claim is made.

Validation includes Rust, the public ABI, identical exported/native SDK tests,
byte-for-byte app comparisons against the original native implementation, and
the DiagnosticsKit queue boundary. See the corresponding validation report.

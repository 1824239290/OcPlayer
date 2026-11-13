# Shared TMDB matching

The native `TMDbMatcher` now delegates complete matching decisions to
`tmdb.matcher` when Core is enabled. Caller-provided searches remain injectable;
the original implementation remains an independent fallback and test oracle.
The existing TMDB transport, rate limiter, metadata cache and enricher consume
the same search/result models.

The command accepts `operation` and a projected `item` containing `name`, `kind`,
optional `year`, `originalTitle`, `tmdbID`, `seasonNumber` and `seriesName`.
`initial` additionally accepts `seriesLink` (`entityKey`, `source`, `confidence`)
and `allowSearch` (default true). It returns an authoritative/parent match, a
search request, or neither. Episode/season matching uses only a parent TV link
and season number, never the episode's own provider ID. Unsupported kinds never
search. Movie/series provider IDs accept the native trimmed positive Int range.

An initial search uses the item name, movie/TV type and item year, falling back
to the first parenthesized 1900...2100 title year only for the query. Ranking
continues to use the item's actual year. `rank` consumes native camel-case
search candidates and returns scores, a match and `needsOriginalSearch`. When
requested, the host searches the nonempty distinct original title once, appends
those candidates and ranks again. Search errors become empty candidates at each
stage, matching the native automatic matcher. Injected search cancellation and
error behavior remain unchanged; this command performs no network/cache writes.

Exact title/original-title matches score 0.95 for the same year, 0.8 for a one-year
difference, 0.7 for missing years and 0.4 for other years. Loose containment scores
0.6/0.5/0.3/0.1; unrelated titles always score 0.1. The auto-apply threshold is
0.85. Ranking retains candidate order and duplicates at equal scores, returns
the best candidate even below the threshold, and retains up to five alternatives
with their original fields for manual matching. Empty candidates return no match.

Title normalization freezes the reference Swift/Foundation lowercase, width,
punctuation/symbol/whitespace and numeric semantics in generated scalar tables.
It preserves non-width compatibility characters and combining marks, and strips
the same five explicit season suffix patterns in order. Equality and containment
use canonical Unicode equivalence and complete character boundaries. Numeric
season suffixes and parenthesized years consume extended grapheme clusters,
including native numeric characters with combining marks. `normalize` exposes batch normalization/year
results; `score` and `providerID` expose the corresponding pure decisions.
`Scripts/generate-swift-tmdb-unicode.swift` regenerates the tables from the
reference runtime without changing source media or reports.

Responses use `data.payloadJSON`; typed consumers decode that text directly to
preserve exact signed 64-bit IDs. Known fields are type/range validated and
unknown candidate fields are retained. Invalid operations, kinds, links,
candidate types and integer overflows return code 1002 before effects.

Four direct C ABI cases verify identity, query/score year separation, fallback,
stable alternatives, Unicode behavior, exact identifiers and preflight errors.
Four native differential cases include the reference Unicode scalar corpus,
900 nine-candidate score/ranking sets, 90 complete search flows and provider/
parent/disabled-search boundaries. Existing native matcher tests also run through
Core under the unified macOS verifier. Enricher/batch scheduling is covered by [tmdb-enrichment-contract.md](tmdb-enrichment-contract.md). Repository memory/freshness orchestration remains open in
[macos-parity.md](macos-parity.md).

Exact-ID evidence here covers the matcher boundary. Network DTOs now use the
SDK's original-byte typed decoding path, with separate HTTP/native differential
coverage described in [tmdb-wire-contract.md](tmdb-wire-contract.md).

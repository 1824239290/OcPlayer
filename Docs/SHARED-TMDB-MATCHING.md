# Shared TMDB matching

When Core is enabled, `TMDbMatcher` now executes provider/parent identity,
search planning and candidate scoring through `tmdb.matcher`. Searches remain
caller-injected, so fixed clients and URLProtocol fixtures keep their existing
transport behavior. The original matcher remains the independent fallback.

Episodes and seasons use their parent TV link and season number. Their own
provider IDs never become TV IDs. Movies and series first use valid positive
provider IDs, otherwise query the item name and optionally its original title.
Title-derived years filter searches without changing the scoring year.

The native auto-apply threshold remains 0.85. Scores, stable ranking, duplicate
candidates and up to five manual alternatives retain the original behavior.
Unicode matching preserves Swift/Foundation width and lowercase rules,
canonical equivalence, and complete character boundaries for numeric season
suffixes, year recognition and containment.

The bridge encodes typed requests and directly decodes `payloadJSON`, preserving
exact Int IDs at the matcher boundary. Four native differential tests compare
the reference Unicode corpus, 900 candidate sets, 90 complete search flows and
provider/parent boundaries. Four C ABI tests independently cover the wire API.
Full evidence is stored in OcPlayer-Core's
`docs/validation/2026-11-14-tmdb-matcher/`.

Enricher/batch coordination is now covered by [SHARED-TMDB-ENRICHMENT.md](SHARED-TMDB-ENRICHMENT.md). Repository memory/freshness remains migration work. Network DTOs now preserve exact identifiers through original-byte typed
decoding, with separate response coverage in [SHARED-TMDB-WIRE.md](SHARED-TMDB-WIRE.md).

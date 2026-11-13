# Shared TMDB network decoding

The Core-enabled TMDB adapter now decodes every search, entity and season DTO
with `OcpResponse.decodeData`. This reads the original ABI response bytes,
avoiding the generic JSONValue Double projection and preserving exact Int
identifiers, season numbers, episode counts and runtimes up to Int.max.
Synchronous/asynchronous SDK calls retain the payload after client retirement.

Core response projection matches the native JSONObject decoder for optional
fields, fractional/boolean numeric values, malformed arrays, the cast prefix
limit, content ratings, UTF-8/UTF-16/UTF-32 and encoding errors. Requests retain
signed IDs, season numbers and movie/TV search years; episode/season searches
omit the year filter. Short date strings do not become result years.

Three native cases compare full entity, season and search models across 14
HTTP scenarios against the original native decoder, then verify malformed-wire
errors and actual signed request paths. Two SDK cases cover nested integer
ranges and the real sync/async ABI. Five direct C ABI cases provide independent
response/preflight coverage. The shared fixture and complete verification logs
are retained in OcPlayer-Core's `docs/validation/2026-11-14-tmdb-wire/`.

Enricher/batch coordination, repository memory/freshness and broader metadata
acceptance remain in progress.

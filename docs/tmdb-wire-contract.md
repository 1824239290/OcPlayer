# Shared TMDB response contract

The public `tmdb.search`, `tmdb.entity` and `tmdb.season` commands retain exact
signed 64-bit identifiers, years, season/episode numbers and runtimes. The
Apple SDK's `OcpResponse.decodeData` decodes typed payloads from the original
owned ABI response bytes, including nested integers, nulls and floating-point
fields. Both synchronous and asynchronous calls retain those bytes after the
client is retired. The existing generic `data: JSONValue` API remains available;
its Double projection should not be used for exact integer identifiers.

`RustTMDbClient` uses this typed response path for every network DTO. Request
IDs, season numbers and movie/TV search years retain the native signed Int
range. Episode and season searches omit the year filter, as the native client
does. Short date strings do not become search-result years. Collection routing
and enricher/repository coordination are separate acceptance work.

Shared decoding follows the reference Foundation JSONObject behavior: boolean
numeric fields become 1/0; finite representable fractional integer fields
truncate; malformed optional fields disappear; arrays containing a non-object
discard the entire projected array. Cast selection applies its 20-entry limit
before dropping malformed entries. Content ratings prefer US, then the raw
`__language` value, then the first entry. Corrupt numbers outside the Int range
are discarded safely rather than triggering the native Int(Double) trap.

The transport retains HTTP status, retry and cancellation ownership. TMDB
parses its raw response bytes as strict UTF-8, UTF-16 or UTF-32, preserving
Unicode and exact integers. The reference macOS JSONSerialization accepts
UTF-8/UTF-16 BOMs, unmarked UTF-16/UTF-32 and a big-endian UTF-32 BOM; it rejects
the little-endian UTF-32 BOM. Invalid encoding, incomplete code units and
non-object roots return decoding code 1514 without a Swift replay.

Five direct C ABI cases and two public SDK cases exercise the actual response
boundary, numeric fields, encodings, malformed responses, request ranges and
preflight rejection without HTTP effects. Three native cases compare complete
entity, season and search models with the independent JSONObject decoder over
14 wire scenarios (42 full model comparisons), and cover malformed bytes and
episode year suppression. The verifier checks that the C ABI, exported SDK and
native MetadataKit use the same HTTP fixture. Evidence is retained under
`validation/2026-11-14-tmdb-wire/`.

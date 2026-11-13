# Shared intro providers

AniSkip, AnimeSkip, TheIntroDB and AniList production clients now retain a Core
handle and use its pooled, cancellable HTTP exchanges. Provider request assembly,
AniSkip/AnimeSkip/TheIntroDB response decoding, opening conversion, timestamp
selection and interval clamping run in Rust. Injected URLProtocol sessions keep
their native transport, and native policy implementations remain independent
comparison oracles. AniList identity scheduling/matching and ID persistence still
run in Swift; sharing its HTTP transport does not complete that migration.

Each exchange is one HTTP attempt. Native AniSkip's retry loop surrounds only
transport exchange; HTTP status handling and decoding are outside that loop.
Timeout/disconnection may retry, but HTTP 429/5xx do not. AnimeSkip and TheIntroDB
do not retry. AniSkip 404 returns nil, while TheIntroDB 404 throws the original
HTTP error. No failed Core call is replayed through native networking.

## Commands

| Command | Arguments | Result |
| --- | --- | --- |
| `introProvider.request` | `provider`, optional `baseURL`, provider inputs, optional `userAgent`/`timeoutSeconds` | `provider`, `baseURL`, `url`, `httpMethod`, `headers`, optional `bodyBase64`, `timeoutSeconds` |
| `introProvider.exchange` | `provider`, optional `baseURL`, `url`, `httpMethod`, optional `headers`/`bodyBase64`/`timeoutSeconds` | Exact `status`, string `headers`, binary `bodyBase64` |
| `introProvider.aniskip` | `malID`, `episodeNumber`, optional `episodeLengthSeconds`/`baseURL` | Optional interval array |
| `introProvider.animeSkip` | `anilistID`, `episodeNumber`, optional `seasonNumber`/`clientID`/`baseURL` | Optional clamped external interval |
| `introProvider.theIntroDB` | `tmdbID`, `episodeNumber`, optional `seasonNumber`/`baseURL` | Optional clamped external interval |
| `introProvider.decodeAniSkip` | `responseBase64` or `responseJSON` | Optional interval array |
| `introProvider.decodeAnimeSkip` | Response bytes, `episodeNumber`, optional `seasonNumber` | Optional clamped interval |
| `introProvider.decodeTheIntroDB` | Response bytes | Optional clamped interval |
| `introProvider.aniskipHint` | `payloadJSON`: interval array | Optional intro hint |
| `introProvider.animeInterval` | `payloadJSON`: episode array, `episodeNumber`, optional `seasonNumber` | Optional unmodified timestamp interval |
| `introProvider.clamp` | `payloadJSON`: external interval | Optional clamped interval |

Providers are `aniSkip`, `animeSkip`, `theIntroDB` and `aniList`. Default origins
are their existing native HTTPS services. Optional HTTP origins/path prefixes
support local fixtures and reverse proxies. Exchanges reject another origin,
credentials, fragments, unsupported routes/methods/headers, GET bodies and
timeouts outside `(0, 300]`. Only read endpoints are exposed: AniSkip skip-times,
AnimeSkip GraphQL, TheIntroDB v3 media and AniList's GraphQL root. Cancellable
requests use the existing `requestId` and `request.cancel` contract.

Typed/pure results use `{payloadJSON: "..."}` so Apple does not route 64-bit IDs
through JSONValue's Double representation. GraphQL variables retain native
string types, even at Int64.max. AniSkip retains repeated types query items,
defaults episode length to zero and validates positive MAL/episode IDs.

## Native selection and decoding

AniSkip decodes the complete results array, skips unknown types and chooses the
first OP/mixed-OP. An invalid first opening does not fall through to a later one.
AnimeSkip prefers the exact season among matching numeric episode strings, then
the first episode match. Stable timestamp ordering preserves equal positions,
including signed zero. The first Intro/Mixed Intro/New Intro runs to the next
timestamp of any type. TheIntroDB uses only the first segment; missing endpoints
do not fall through to a later valid segment. Its Int fields accept integral
floating JSON numbers and reject fractions/out-of-range values.

Parsing matches the installed Foundation oracle for duplicate keys (first value),
UTF-8/UTF-16 BOMs, unmarked UTF-16/UTF-32, and lazy string decoding of unknown or
ignored duplicate fields. The native decoder rejects UTF-32 BOM input, so Core
does too. Known malformed fields and malformed arrays fail as a whole. Decimal
Double conversion uses serde_json's round-trip parser. These are recorded native
compatibility behaviors, rather than a new JSON protocol for providers.

## Validation and limits

Seven Swift cases compare 600 hint/clamp/timestamp corpora, Unicode and duplicate
responses, malformed fields and integer edges. They also call all four public
clients against a real local HTTP/1.1 server, proving connection reuse, typed
errors, one HTTP attempt, three configured timeout retries and cancellation.
Six exported ABI cases cover typed and raw endpoints, signed-64-bit variables,
headers/error bytes, validation before I/O, timeout and cancellation. The exact
same Python fixture is copied into DanmakuKit resources and checked with `cmp`.

Native request/resource timeout distinctions, redirect/TLS/streaming transport
fidelity, AniList identity/cache orchestration, complete shared load/manual flow,
and the remaining macOS parity acceptance rows stay open. The wrapper currently
uses the smaller native request/resource timeout as Core's whole-exchange
deadline; it does not yet model URLSession's separate idle/resource deadlines.
No Windows runtime test is claimed.

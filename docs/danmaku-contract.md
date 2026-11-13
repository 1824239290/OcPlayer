# Danmaku transport and macOS flow

The production DanmakuGatewayClient retains one Core for its lifetime. All four
HTTP interfaces (match, anime search, episode search and comments) dispatch via
`danmaku.exchange`. The current HTTPS-origin validation and request constraints
remain at the public Swift boundary. Injected URLProtocol sessions keep their
native transport; normal default and ephemeral configurations activate Core.

`danmaku.exchange` accepts `gateway` (`base_url`, `api_key`, `user_agent`), `url`,
`httpMethod`, optional `bodyBase64`, optional `timeoutSeconds` (default 30, range
(0, 300]) and the common `requestId`. It accepts GET search/anime,
search/episodes and non-negative signed-64-bit comments IDs, and POST match,
under the configured origin/path prefix. GET bodies, other routes/methods,
cross-origin requests, userinfo, fragments and malformed arguments are rejected.
Local HTTP origins are supported by the Core ABI for native fixture transports;
the Apple public gateway client continues to require an HTTPS origin.

Successful exchanges return `status`, `headers` and byte-preserving `bodyBase64`,
including non-2xx statuses and malformed/non-UTF8 bodies. Cache and Retry-After
headers reach the existing domain decoder. The Core sends exactly once, leaving
retry settings, business-error mapping and logging with GatewayClient. Transport
failure uses 1501, timeout 1503, invalid arguments 1002 and cancellation 1003.
Cancellation interrupts the in-flight network future on the shared executor.

The macOS automatic flow now always uses DanmakuLoadOrchestrator. The earlier
Core shortcut bypassed cached matches, search degradation and intro sources,
loaded every candidate's comments and reconstructed comments without their IDs
or original modes. Removing that shortcut keeps the complete native matching,
cache/revision checks, alias fallback, manual selection, intro providers and
learning, readiness and generation guards on the production path while the HTTP
work runs through Core. Resolver scheduling and intro policies still need
shared implementation for Windows parity. Saved mappings/comments/intro hints
now use the [shared cache](danmaku-cache-contract.md).

`tests/danmaku_contract.py` checks the exported C ABI against a real local
HTTP/1.1 server. Native RustDanmakuIntegrationTests verify default activation,
injected transport preservation, complete domain responses, shared TCP reuse,
typed errors, exact retry counts and cancellation. Existing DanmakuKit tests
exercise the full native resolver, cache, matching and intro flow. The native
real-server tests invoke the internal exchange boundary to keep fixture HTTP
out of the public HTTPS-origin contract.

## Shared matching policy

The production parser, canonical match names, episode tokens, special filename
keywords, Unicode comparable titles, candidate scores and selection now use
Core through the retained RustDanmakuPolicy. Disabled-Core implementations remain
for differential/regression comparison. Once loaded, Core is authoritative;
policy failures do not silently fall back to Swift.

- `danmaku.parseFilename {fileName}` retains raw name and returns title, season,
  episode and final-season status. Release groups, tags, years, specifications,
  episode tails and hidden/trailing-dot filename handling match the native parser.
- `danmaku.parseEpisode {title}` returns an optional episode token and its
  `searchValue`. The string preserves signed-64-bit episode values through hosts
  whose generic JSON number representation uses floating point. S/C/O prefixes
  are case-sensitive, positive and limited to three digits, as in OcPlayer.
- `danmaku.comparableTitle {title}` uses full-width conversion, lowercase,
  canonical Unicode normalization and extended grapheme filtering. It preserves
  character identity instead of compatibility-folding distinct titles.
- `danmaku.specialKind {text}` checks letter/grapheme boundaries, prioritizes
  NCOP/NCED/extra-footage keywords over SP and leaves OVA/OAD unclassified.
- `danmaku.scoreCandidates {target,candidates,rankIndex?}` scores a complete batch
  and returns `scores`, optional `{index,score}` selection and the 1200 confidence
  threshold. Target has optional `animeTitle`, `episodeNumber`, `seasonNumber`,
  `special {index,kinds}`, default `isFinal=false`, and `kind=episode|movie`.
  Candidate fields use the gateway names and signed-64-bit IDs/shift. Namespace
  preferences, same-index OVA fallback, episode/season/final conflicts, grapheme
  overlap/containment and hard movie-vs-episode identity gates match OcPlayer.
  Rank offsets apply to both scores and selection; equal scores retain the first
  input. Swift submits flattened search results in global order and uses the
  returned index to retain the exact original ID, shift and title fields.

Native policy tests compare 960 filenames, 3840 scores, 270 special-keyword
boundary combinations, episode/Unicode/canonical edge cases and large batches.
They explicitly require an activated Core and compare with the independent
native policy bodies. Direct C ABI fixtures additionally check thresholds,
namespace order, type gates, malformed arguments, rank/tie behavior, Unicode,
large integer token strings and zero network requests.

The HTTP/match/search/intro orchestration remains owned by the native service.
Cache persistence, TTL, LRU and revision barriers now run in Core through the
retained RustDanmakuCache. Intro detection, learning persistence/consensus,
manual-seek decisions and interval/sibling aggregation now use the
[shared intro policy](intro-contract.md). Shared scheduling and provider transport
remain necessary for complete platform parity.

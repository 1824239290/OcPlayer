# Standalone shared Danmaku loading

`danmaku.load` now executes the same retained state machine as the native player.
It selects one candidate and uses the complete hash/TMDB/title/parsed-title
waterfall, matching budget, cache branches, payload converter and intro policy.
The data consumer completes without player readiness or renderer mutations;
the player consumer retains its existing readiness/injection boundary before
intro resolution. Both consume the same `flow.rs` decisions.

## Request

`gateway` retains `{base_url,api_key,user_agent}`. `matchRequest` contains the
original media fingerprint fields and may be omitted for a manual selection.
`configuration` accepts a JSON object or textual JSON containing the existing
[flow configuration](danmaku-flow-contract.md); this command sets delivery to
`data`. Its context defaults filename, file size and duration from `matchRequest`.
Additional episode/season/movie/special/TMDB/MAL/AniList context remains explicit.
Manual mode requires `matchValue` and forces intro resolution. Automatic mode
uses hash and filename together when a filename exists, otherwise hash only.

Optional `cacheKey` and `revision` bind mapping reads/writes to an existing
`danmakuCache.open` on the same Core; revision requires a cache key. Existing
comment/hint, learning and ID stores on the handle are reused. The command
does not reopen them on every load. No cache key disables mapping reuse/writes,
while an already configured episode comment/hint cache can still be reused.
Local `filePath` computes the head-16-MiB MD5; the host owns its file-access scope.
Otherwise the caller supplies the fingerprint. Missing/unreadable fingerprints
retain the same fallback and manual-selection failure priority as the player.

`aliases` supplies host-resolved title alternatives. `providers` contains optional
`aniList`, `aniSkip`, `animeSkip` and `theIntroDB` settings, each with optional
`enabled`, `baseURL`, `timeoutSeconds` and provider-specific `clientID`/`userAgent`.
AniList, AniSkip and TheIntroDB are available by default when their IDs/context
permit a query; anime-skip additionally requires a client ID. Disabled providers
perform no requests. Alias expansion and ordered AniList resolution reuse the
existing shared resolver/ID cache. Community reads execute concurrently and
retain completion ordering before Core's stable source consensus. Cached intro,
community, learned, sibling and detected precedence remains unchanged.

`format` is `overlay`, `kernelTrack` or `both` (default). Gateway resource timeout
defaults to 30 seconds and accepts `(0,300]`; `retryAttempts` defaults to three and
accepts `1...20`. One layer owns retries: transient transport errors, 429 and
500/502/503/504 only. Backoff uses the native 2-based exponent and 0.5...1.5 jitter;
a positive numeric 429 Retry-After overrides it, capped at sixty seconds. Business,
decoding, parameter and other status failures are never replayed. Matching's
thirty-second budget starts after hashing, gates subsequent queries, and lets an
in-flight request finish. Nonpositive matching budgets disable the gate.

## Result and lifetime

The result includes `payloadJSON` plus legacy outer `match` and `episodes` fields.
Consumers decode the textual payload directly to preserve exact 64-bit IDs.
`match.matches` and `episodes` contain only the selected candidate, or are empty
for a complete no-match waterfall. An episode retains `candidate`, valid-overlay
`count` and `comments`, and adds format-specific `entries`/`json`, raw
`rawCommentCount` and resolved `introHint`. The result adds `outcome`,
`selectedMatch` and matching `diagnostics`. Empty/all-invalid comments produce an
`empty` outcome, distinct from `noMatch`. Failed matching/readiness-independent
data loading returns the stable API error envelope rather than a false no-match.

The Apple `OcpDanmakuLoader` exposes these options and typed outcomes/intro hints,
and decodes only the textual payload. Gateway decoding consumes the same native
optional fields, tolerates unknown fields/encodings where the native decoder
does, accepts integral floating JSON for Int/Int64, and preserves business-error
fallback when domain decoding fails. Rendering uses the shared production
numeric/Unicode rules, stable overlay order and source-order Erika JSON.

All loads share the Core's 64-continuation admission limit. Terminal completion,
errors and cancellation close the continuation. Cancellation interrupts network
requests/backoff/provider tasks and prevents later writes. Cache mutations and
ID commits recheck revisions under the mutation lock, so a newer media mapping
cannot receive a stale result. Stores retain their existing native-compatible
file formats and best-effort persistence semantics.

Ten direct ABI cases cover candidate selection, the eight-query waterfall,
fallback/retry ownership, cache/forced forgetting, aliases/ID cache/community
consensus, learned/sibling precedence, manual mode, payload conversion, exact
identifiers, integral floating fields, preflight/budget outcomes, live cancellation
and stale writes. Three Apple binding cases exercise the public API against the
same fixture. Two Rust flow cases verify data delivery with cached/manual paths.
The complete macOS acceptance scope remains in [macos-parity.md](macos-parity.md).

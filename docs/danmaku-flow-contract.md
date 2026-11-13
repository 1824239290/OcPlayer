# Shared automatic and manual Danmaku loading

The production macOS orchestrator now drives a retained, resumable Core flow.
Core chooses every matching tier/query, budgets, candidate ranking, cache branch,
payload route, playback readiness step and intro-source precedence. The adapter
executes requested file/network/cache/player effects and returns their results.
Gateway transport already uses Core's pool; its existing Swift retry and typed
response wrapper execute network effects, including injected URLProtocol tests.
Security-scoped file access, settings-backed provider availability and renderer
mutations remain adapter responsibilities.

## Continuation API

All results are wrapped in `payloadJSON` to preserve signed 64-bit identifiers.

| Command | Input | Result inside `payloadJSON` |
| --- | --- | --- |
| `danmakuFlow.begin` | `flowID`, `payloadJSON` configuration | Flow ID, step zero, requested effect, optional match/outcome, diagnostics |
| `danmakuFlow.advance` | Same flow ID, exact `step`, `payloadJSON` reply | Next step/effect or terminal outcome |
| `danmakuFlow.close` | Flow ID | Whether an active continuation was removed |
| `danmakuFlow.stats` | None | Active/capacity and cumulative started/finished counts |
| `danmaku.renderPayload` | `payloadJSON` comments, `format`, `detectingIntro` | Optional sorted overlay entries, optional Erika JSON, raw comment count and detected hint |

Configuration contains `mode` (`automatic` or `manual`), `context`, optional
`forceRematch`, `budgetSeconds`, `hasAliases`, `hasLearning`, and manual
`matchValue`, and `delivery` (`player` by default, or `data`). Context fields mirror DanmakuMatchContext: filename, title/original
title, episode/season, TMDB IDs, MAL/AniList IDs, movie/final/special identity,
file size, duration and cached-match reuse. The adapter binds the playback UUID,
cache key and revision to that flow; these cannot change between effects.

A reply contains required `current`, optional `cancelled`, `value`, `error` and
`nowSeconds`. `current` is the result of the existing cache revision check.
The Core uses a monotonic clock; fixtures can supply finite, monotonic elapsed
seconds. Error kinds preserve native Dandanplay categories and optional status/
message. A stale step or malformed reply leaves the continuation unchanged.
Terminal outcomes remove it automatically; an adapter also closes in `defer`.
Each Core permits 64 active continuations and rejects excess admission.

Effects cover force clearing, revision claims, cached matches, media fingerprint,
hash matching, scoped episode searches, mapping remember/forget, cached intro/
comments, comments fetch/persistence, rendering, readiness and injection, aliases,
AniList ID resolution, concurrent provider reads, promoted hints, sibling hints
and final intro persistence. Only small result summaries return from cached
comments/rendering to the flow; the adapter keeps renderer payloads for injection.

## Automatic and manual behavior

Automatic matching retains the four native tiers: hash+filename, TMDB episode/
whole-series/movie search, supplied title scoped/whole-series search and distinct
parsed title scoped/whole-series search. Specials use whole-series queries;
ordinary episodes try their number first. The first match remains authoritative
when `isMatched=true`; otherwise Core's existing confidence/ranking policy picks
the candidate. Search candidates retain anime IDs and the native zero shift.

The default thirty-second budget starts after fingerprint completion and is
checked between tiers and before each query. An in-flight request finishes.
Nonpositive budgets disable the gate. Gateway/network/credential failures stop
remaining tiers; 4xx status, parameter, business and decoding failures can fall
through. A missing fingerprint retains its manual-selection failure priority.
A budget-cut miss is retryable failure rather than a false `noMatch`. A complete
eight-request empty waterfall does not manufacture a budget-cut diagnostic.
Cached matches bypass fingerprint/matching and the matching budget entirely.
Forced rematching clears the renderer and forgets an unsuccessful old mapping.

Manual selection remembers the chosen mapping and loads with forced intro
resolution. Loading reads the existing intro cache before deciding to detect
comments, reuses TTL comments or fetches/persists once, builds only the requested
payload format, waits thirty seconds for readiness and injects using the original
UUID/name/shift. Intro network reads start only after successful injection.

Intro precedence is unchanged: permanent cache unless forced; concurrent AniSkip/
AnimeSkip/TheIntroDB community intervals; promoted learning unless forced;
sibling consensus; this payload's detected hint. Aliases augment matched/original
titles before shared AniList ID resolution. Community endpoints require native
episode context; provider results keep completion ordering before shared stable
aggregation. The existing 10000-based episode/anime ID derivation is preserved.

The flow checks revisions after awaited decisions and again before injection.
The adapter checks before intro persistence. Cancellation after injection stops
subsequent ID resolution/persistence, and a revision change during readiness
cannot inject into the same UUID. These close races in the retained native
orchestrator, whose old intro fallback could continue after cancellation.

## Production payload rules

`overlay`, `kernelTrack` and `both` use one shared conversion. The first three
ASCII comma-separated fields require finite nonnegative Swift-compatible Double
time, mode 1/4/5 and color in 0...0xFFFFFF. Empty or all-native-whitespace text is
discarded without trimming accepted content. Original combining comma suffixes,
hexadecimal Double input and signed zero behavior are retained. Overlay entries
are stably sorted by time. Erika JSON retains source ordering and contains
`time/type/color/content` without synthesized IDs. Count is the raw comment count;
an all-invalid array yields absent render payloads and an `empty` outcome.

## Verification and remaining scope

All 29 existing loading cases pass through Core. Six Rust state-machine cases and
six C ABI cases independently exercise eight-request ordering, budgets, first/
ranked matching, exact Int64 IDs, cache branches, source plans, cancellation,
revision checks, stale replies and bounded admission. Four new Swift cases
compare 1200 numeric/Unicode corpora across three formats, native manual/cached
control flow and the two post-await races. Original implementations remain
available as control-flow/rendering comparison oracles.

`danmaku.load` now executes the same complete state machine for a data consumer;
see [standalone-danmaku-contract.md](standalone-danmaku-contract.md). Manual-seek
learning promotion/propagation also executes in Core; see
[intro-contract.md](intro-contract.md). Broader macOS acceptance remains open;
this does not mark the full goal complete or claim Windows runtime validation.

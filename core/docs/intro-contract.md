# Shared intro policy and learning

Production DanmakuIntroDetector, IntroLearningStore, source interval selection,
sibling-hint aggregation and the player's manual-seek eligibility/confirmation
now dispatch through Core. Pure policies share RustDanmakuPolicy's retained
handle. The production learning actor shares its service's retained cache Core,
so manual-seek learning reads and updates the same live hints and mappings.
Standalone learning stores retain their own Core. Disabled Core and
injected FileManagers retain native implementations for comparison/testing.
Activated operations do not replay through Swift.

## Pure policy

`danmakuIntro.*` operations return `data.payloadJSON`, decoded directly into
domain types. Array/object inputs use `payloadJSON`, accepting either encoded
JSON text or domain JSON. Textual payloads preserve exact 64-bit episode IDs
and avoid the generic Apple JSON projection's Double conversion.

| Operation | Arguments | Decoded result |
| --- | --- | --- |
| `detect` | `payloadJSON`: original comment array | Optional DanmakuIntroHint |
| `timestamp` | `text` | Optional parsed seconds |
| `jumpTarget` | `text` | Optional reported landing seconds |
| `commentFields` | `p` | `{time,uid}` |
| `consensus` | `payloadJSON`: seek events, optional signed `minimumEpisodes` (default 2) | Optional `{end,episodeCount}` |
| `eligibleSeek` | Finite `from`, `to` | Boolean |
| `confirmedHint` | Finite `to`, `payloadJSON`: optional current hint | Optional upgraded hint |
| `selectIntervals` | `payloadJSON`: `{source,start?,end}` array | Optional `{start,end,votes,source}` |
| `siblingHint` | `payloadJSON`: previously filtered sibling hint array | Optional aggregate hint |
| `policy` | None | Landing window, minimum seek, snap tolerance, minimum episodes and event limit |

Detection retains native reported-target/landing/start signals, rounded medians,
25-second adjacent clustering, distinct-value/user evidence, confirmation
tolerance, landing-only rejection of single-user spam and intro-start estimation.
Comments preserve original `p`/`m` and optional signed-64-bit `cid`. Keyword
scanning runs once per comment and validates grapheme boundaries only on byte
matches. Jump keywords retain their array priority and first occurrence, scanning
at most twelve Characters after each match.

Timestamp parsing follows the existing Swift Regex behavior: numeric Characters,
full-width separators, first-match validation, minute/second ranges and decimal
point restrictions. It retains the reference's third capture as the hour value;
`1:23:45` produces 162083 seconds. Intro detection subsequently applies its
30–300-second target range. Swift numeric/whitespace scalar tables are generated
from the reference runtime and checked into the Rust crate, so runtime consumers
need no Apple dependencies. Regenerate on macOS with
`swift -swift-version 6 Scripts/generate-swift-intro-unicode.swift > crates/ocp-danmaku/src/intro_unicode.rs`,
then run `cargo fmt --all` and the differential checks.

Hexadecimal comment times use the platform conversion routine with an immutable
C numeric locale, preserving complete-input validation and correctly rounded
tail bits. Windows declarations follow the official
[_create_locale](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/create-locale-wcreate-locale?view=msvc-170)
and [_strtod_l](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/strtod-strtod-l-wcstod-wcstod-l?view=msvc-170)
signatures. Windows execution remains deferred.

Learning consensus uses adjacent positions within ten seconds, ranks clusters
by distinct episodes then event count, and retains the first cluster on a full
tie. It returns the unrounded position median only inside 30–360 seconds.
Manual eligibility requires a strictly greater-than-five-second forward seek.
Only an existing danmaku hint within ten seconds receives confirmation: it
retains the original interval, increments evidence and becomes learned.

Source selection groups adjacent ends within ten seconds, then ranks by votes
and the first interval's source priority. The chosen cluster uses median ends
and available starts, and its highest source priority: AniSkip > anime-skip >
learned > TheIntroDB > danmaku. Sibling aggregation uses five-second clustering,
at least two entries and an optional start only when at least two near-end starts
also agree within five seconds. Source/episode filtering happens before this
policy in the native service.

## Learning store

`introLearning.open {directory}` configures a best-effort absolute learning
folder on the handle. `record {animeID,payloadJSON}` appends a seek event;
`promote {animeID,payloadJSON}` saves a hint. `promotedHint`, `consensusHint` and
`events` accept `animeID`; `stats` returns lifetime `writeFailures`. Writes return
a Boolean and reads return optional hints or event arrays inside `payloadJSON`.
Bad arguments return 1002 and an unconfigured store returns 1401.

`learned-intros.json` keeps the original anime-ID dictionary of `{events,promoted?}`.
Events retain signed-64-bit `episodeID`, numeric `position` and Swift reference-date
`at` (seconds since 2001-01-01 UTC). Only recording truncates to the latest 200
events per anime; reading/promotion preserves existing data. Missing/corrupt
learning files become a cached empty map, matching native reconstructible-data
recovery. Atomic writes share the cache's same-directory temporary-file writer.
Failed writes retain write-through memory, increment diagnostics and clean up
temporary files. Store reads never trigger promotion by themselves.

Seven native cases explicitly require activated Core and compare independent
native algorithms: 676 Unicode timestamp combinations, number/UID edge cases,
700 detector corpora, 3000 consensus checks, 600 interval/sibling comparisons,
seek/source boundaries, bidirectional learning files and a 10000-comment batch.
Six direct C ABI cases additionally cover validation, exact IDs/dates, event
bounds, corruption semantics, disk failure and source/cluster ties.

Provider transport/identity and automatic/manual loading now run in Core;
see [intro-provider-contract.md](intro-provider-contract.md),
[intro-identity-contract.md](intro-identity-contract.md) and
[danmaku-flow-contract.md](danmaku-flow-contract.md). The broader acceptance
scope remains in [macos-parity.md](macos-parity.md).

## Complete manual-seek learning

`introLearning.applySeek {payloadJSON}` accepts `{match,from,to,at?}`. `match`
is the original EpisodeMatch; `at` is an optional reference-date timestamp,
sampled by Core when recording if absent. Positions and supplied timestamps
must be finite. Apple normalizes negative-infinite `from` to its smallest finite
Double, retaining native eligibility. Invalid arguments return 1002 before writes.
An ineligible seek or a match without an explicit/derived anime ID returns
`ignored` before requiring storage. An eligible seek requires both
`introLearning.open` and `danmakuCache.open` on the same handle (otherwise 1401).

The decoded result is `{kind,animeID,hint,updatedEpisodeIDs,applyToCurrent}`:
`kind` is `ignored`, `recorded`, `confirmed` or `promoted`. Confirmation retains
the current interval, upgrades its source/evidence, promotes the anime hint,
and updates only the current episode. It records no event and requests no
immediate playback update. Otherwise the event is recorded; only a new consensus
for an anime without an existing promotion is promoted and propagated. Explicit
anime IDs take precedence over episode-ID division. Propagation updates only
absent or danmaku hints, protecting all other sources and duplicate mappings.
Updated IDs are sorted. `applyToCurrent` follows the native mapping-membership
rule even when the current cache hint is protected; native playback source ranking
and the captured request ID guard the live session update.

One Core state lock covers this decision and all memory updates, so concurrent
requests cannot repeatedly confirm the same stale danmaku hint. Disk writes
retain the existing best-effort semantics: this is not a multi-file disk
transaction. `updatedEpisodeIDs` describes the write-through hint updates;
store/cache diagnostics count failed persistence. Cancellation before the Apple
entry point avoids all writes; an operation already executing under Core's lock
finishes its finite update. No network or player operation occurs inside it.

The native fallback owns the same sequence in DanmakuKit and remains independently
testable. The app now captures the seek and playback request ID, logs completed
confirmations/promotions, and applies the returned consensus. Six new native
flow cases compare these paths and test exact IDs/dates, source protection,
single-episode evidence limits, concurrency and cancellation. Three additional
C ABI cases cover the complete workflow and failed-write memory behavior.

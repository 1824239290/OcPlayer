# Shared media repository composition

`mediaRepository.compose.*` executes the repository's composition decisions in
the same retained Core handle as projection caches, refresh claims and local
progress. Every operation accepts `payloadJSON`; the Apple adapter uses original
Codable bytes in both directions, retaining exact signed integers, optional
fields, metadata and Foundation reference-date timestamps. Operations are pure
reductions and do not touch cache recency or progress records. Invalid arrays,
IDs, numeric fields or overflowing pagination offsets return code 1002.

`diskPage` sorts rows stably by startIndex and walks only the contiguous prefix
starting at zero. Page length advances the cursor even when item IDs duplicate;
canonical Unicode equivalent IDs coalesce while the first complete item survives.
Each consumed row replaces the total (including a missing total) and full-page
flag. Empty pages and zero/negative limits follow the original native comparison.
`page` preserves duplicates on replacement at startIndex zero. Later windows
append only previously unseen IDs, preserve previous total when the incoming total
is missing, use the maximum cursor and the incoming page's fullness, then merge
currently protected session progress.

The host loads a missing accumulated page from the database before `page`, writes
its projection before the database await, persists the original incoming page,
and merges protected progress again after that await. This retains the native
interleaving behavior when playback changes during persistence. Existing shared
refresh claims continue to own request coalescing; waiter cancellation does not
retire a request. No reduction initiates or repeats a network mutation.

`diskHome` suppresses next-up entries whose canonical ID appears in resume,
preserves duplicates elsewhere, and returns nil for an entirely empty restored
home. Its timestamp is the oldest existing rail date, otherwise the oldest
library date, otherwise the supplied clock. `nextUp` uses the same suppression
policy after a successful next-up refresh. `home` merges protected progress in
all three rails and removes confirmed completed resume entries. The host still
executes four parallel network reads and per-part persistence/failure assembly;
failed sections retain previous content and cancellation creates no failure.

`defaultSeason` selects the first season whose number compares unequal to zero,
including a missing number, otherwise the first season. `detailPlan` applies the
first caller's kind hint or cached kind, series priority, collection discovery
from the full item, and series retry when the list lacked a hint. `detail` merges
protected progress in the full item and every detail section. The host retains
asynchronous request ordering and prior-section fallback on auxiliary failures.
Core-disabled native algorithms remain independent differential oracles.

Three Rust cases, three actual ABI cases and three native differential cases
cover these policies. The native corpus includes 500 page arrangements,
16 complete home success/failure/cancellation combinations and six series or
collection workflows with missing hints, missing season numbers and failures.
The existing repository cache/progress/concurrency tests run with Core active.
Full initial and final output is retained in
`validation/2026-11-14-repository-composition/`.

This closes the stated composition policy scope. Whole repository effect
sequencing, failure/fallback assembly and complete acceptance remain follow-up;
account/sync, playback orchestration, native transport fidelity, configuration,
release delivery and Windows adapter implementation remain broader goal work.
Windows runtime testing is deferred by the user.

The complete continuation stage is now implemented in
[media-repository-flow.md](media-repository-flow.md). All ten cache/refresh flows,
section failure/fallback assembly, prefetch and effect sequencing run in Core;
Swift executes the yielded effects and retains platform task handles. Earlier
remaining-work statements above describe the original composition-only cohort.

# Shared Bangumi repository

Core's `bangumiStore.*` commands use the existing `Bangumi.sqlite` schema and
GRDB migration identifiers (`createBangumiSchemaV1`, `addEpisodesSyncedAt`).
Configure `bangumiDatabasePath` to reuse an exact existing database, or
`dataDirectory` to open `Bangumi.sqlite` in that directory. This database is
independent of `Media.sqlite`; it opens lazily on the first repository command.
File databases use WAL, a five-second busy timeout, and immediate write
transactions. Read operations use one consistent transaction. A locale-only
settings update keeps the open repository.

Commands return their result directly in the standard envelope's `data` field.
Missing persistence is 1401; bad arguments/unknown repository commands are 1002;
open/migration/query failures are 1402. The paths are redacted in diagnostics.
Subject/episode payloads retain existing Apple Codable names (`nameCN`,
`subjectID`, `epStatus`, `updatedAt`, etc.) and JSON BLOB representation. Unix
timestamps are integer seconds. `now` is required for time-sensitive writes;
selection cutoffs are explicit, making behavior reproducible across platforms.

| Command suffix | Arguments | Result |
| --- | --- | --- |
| `saveSubject` | `item`, optional `authoritativeInterest` | created boolean |
| `saveSlimSubject` | `item` | created boolean |
| `saveSubjects` | `items`, optional `authoritativeInterest` | null |
| `subject` | `subjectId` | full subject or null |
| `subjects` | `ids` | full subject array; missing IDs skipped |
| `saveEpisodes` | `subjectId`, `items`, optional `authoritativeCollection`, `now` | null |
| `replaceEpisodes` | same as `saveEpisodes` | null; also removes obsolete chapters atomically |
| `deleteEpisodesNotIn` | `subjectId`, `episodeIds` | null |
| `episodes` | `subjectId`, optional `main`, `uncollectedOnly`, `sortDesc`, `limit` | episode array ordered by sort |
| `episodeCounts` | `subjectId` | `{main,other}` |
| `updateEpisodeCollection` | `episodeId`, `type`, optional `batch`, `now` | owning subject ID or null |
| `updateSubjectCollectionType` | `subjectId`, `type`, `now` | null |
| `updateSubjectRating` | `subjectId`, `rate`, `now` | null |
| `collectionSubjects` | `subjectType`, `collectionType`, `limit`, `offset` | full subject array |
| `collectionCounts` | `subjectType` | map from decimal collection type to count |
| `progressSubjects` | `progressTab`, `sortMode`, `search`, `episodeWindowSize`, `limit`, `offset` | `{data,total}`, with subject/episode windows |
| `progressSubject` | `subjectId`, `episodeWindowSize` | subject/episode window or null |
| `progressCounts` | — | map from decimal subject type to count for all/book/anime/real |
| `missingEpisodes` | `limit`, `staleBefore` | missing/incomplete chapter subject IDs |
| `staleEpisodeProgress` | `limit`, `cooldownBefore` | subject IDs with stale chapter progress |
| `syncTargets` | `limit`, `staleBefore`, `cooldownBefore` | missing targets followed by stale targets, deduplicated in one snapshot |
| `subjectID` | `episodeId` | owning subject ID or null |
| `clearAccountLocalState` | — | null; removes subjects and episodes atomically |

## Preserved behavior

Full subject updates preserve absent images and, unless the response is marked
as authoritative, absent interest. Authoritative collection responses can clear
interest, collection type and collection timestamp. A slim update preserves
full metadata and known episode/volume/privacy state. Same-page duplicate
subject IDs merge optional image/interest contributions before the last update
is applied. Redirect and series-entry fields retain the native persistence
contract (not persisted). Alias and sync timestamps survive metadata updates.

Chapter updates preserve an absent description and collection unless an
authoritative chapter sync explicitly reports no collection. Integer and
fractional chapter sort values use the existing Float precision. Batch watched
updates include all main chapters through the selected sort, including the
selected fractional chapter. Derived watched counts do not reduce a higher
server count when marking watched; explicit revocation permits reduction.

Progress windows center on the next uncollected main chapter, rebalance at the
beginning/end, and exclude siblings with the same sort from either side. A
finished list shows its last window. Non-anime/non-real subjects do not acquire
chapter windows. Collection/date sorting, escaped percent/underscore searches,
pagination, missing-chapter retry intervals and stale-progress cooldowns retain
the native rules.

Pruning compares against the complete retained ID set before issuing bounded
positive `IN` deletion batches. This fixes the former behavior where successive
`NOT IN` batches deleted one another's retained chapters beyond 900 IDs. A full
replacement commits subject metadata, chapter changes, sync time and pruning
in one transaction. Empty replacements still advance the sync timestamp.
Unknown/malformed JSON BLOB containers retain native field fallbacks instead of
breaking an otherwise readable subject.

The Apple `BangumiDatabaseOperator` delegates every repository entry point to
Core when enabled. Its native fallback remains available and also uses the
corrected complete-set pruning and transactional replacement. The actual
chapter sync calls `replaceEpisodes` after checking cancellation; collection
sync checks cancellation before saving a page. Account credentials and task
scheduling remain in the Apple adapter, with broader shared-sync lifecycle work
tracked in the macOS acceptance checklist.

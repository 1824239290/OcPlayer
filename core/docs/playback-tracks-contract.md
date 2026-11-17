# Retained playback track workflow

`playbackTracks.*` owns one decoder-independent workflow per Core handle. The
macOS controller delegates automatic subtitle preference, manual audio/subtitle
selection, imported/sidecar subtitle loading, removal, batches and external names.
The host owns decoder calls, file copies, security scope, source-generation
validation, menu rendering and playback-session mirroring after engine success.

## Commands and effects

`begin` accepts a `request` with one of these `operation` values:

| Operation | Fields | Host effects |
| --- | --- | --- |
| `automatic` | `tracks`, `preference`, nullable `current` | Keep, select subtitle or disable |
| `selectSubtitle` | nullable signed `id` | Select subtitle or disable; success protects manual choice |
| `selectAudio` | signed `id` | Select audio; failures never reach the session mirror |
| `importSubtitle` | `path`, `name` | Add, record returned ID/name, then select; manual protection follows selection success |
| `attachSubtitle` | `path`, nullable `name` | Add and record name without manual protection |
| `removeSubtitle` | `track` | Remove only when `canRemove`; successful selected removal unlocks automatic preference |

Each effect has a non-reused unsigned `operationId`. `complete` acknowledges
`operationId` and `success`; only successful add effects accept and require a
signed `trackId`. The second import effect receives a new ID, so duplicate add
or failure receipts cannot consume its selection. Invalid arguments return
1002 without consuming the current effect. Retired IDs return 1003 without
changing current work. Pending refresh cannot replace an in-flight effect.
`reset` clears names, batch and manual protection and retires any effect, keeping
the receipt counter monotonic. Identifier exhaustion fails before mutation.

`beginBatch` and `endBatch` use an exact string `batchId`. A newer begin replaces
the batch; an old end returns 1003. Automatic preference waits until the current
batch ends; manual and attachment effects remain available. Native source guards
still validate request identity and generation at engine entry. The legacy
anonymous native batch retains its existing unconditional flag cleanup behavior.

`snapshot` exposes `manualChoice`, nullable `batchId`, `externalNames` keyed by
signed-ID strings and nullable `pendingOperationId`. `registerName` supports
externally resolved display names. `selection` offers the same preference policy
without mutating workflow state. Tracks have signed `id`, `kind`, `source`,
`selected`, nullable `title`, `language`, `displayName`, and `canRemove`. Numeric
IDs are scoped to track kind; audio and subtitle IDs may coincide.

## Subtitle parity

Preferences remain `zh-Hans`, `zh-Hant`, `followSource` and `off`. The original
native vocabulary and scoring are retained: preferred script 120, unknown script
110, opposite script 105. Contradictory fields become unknown; equal-scoring
current selection is retained. Weak ISO-colliding tokens (`sc`, `sg`, `mo`) count
only in track titles. Strong language/script tokens and Chinese words also count
in external display names. Unicode normalization operates on extended grapheme
clusters, preserving combining suffixes rather than inventing matches by stripping
them. Unknown languages retain decoder defaults. When all subtitles are external,
none is selected and preference is not off, the first track remains the fallback,
including `followSource`.

The Apple SDK decodes typed effects directly from original JSON bytes, preserving
signed limits and unsigned receipts. Core-selected workflow failures do not fall
back into another policy path. Core-disabled mode retains an independent native
implementation. `PlaybackTrackWorkflow` publishes display-name changes through
Observation, including an acknowledged addition whose tracks otherwise did not
change. Automatic failures stay in logs; explicit user failures retain badges.

Verification and original logs are linked from
[macOS parity](macos-parity.md). Broader source preparation/recovery, real decoder
and media-format coverage, settings/transport/release and Windows adapter
acceptance remain in scope.

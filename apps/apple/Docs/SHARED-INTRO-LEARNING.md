# Shared manual-seek learning

The player captures the episode match, seek positions and playback request ID.
`IntroLearningStore.applySeek` owns the complete confirmation/consensus workflow.
Production creates the store with `sharedWith: service`, retaining the cache's
Core handle and reading the same live hint/mapping state. Disabled Core or
custom file-manager stores retain the native sequence in DanmakuKit.

Core confirms only danmaku hints within ten seconds of the landing and updates
the current episode without recording an event or changing live playback.
Otherwise it records the landing and promotes a new cross-episode consensus
only when the anime has no promoted hint. Propagation changes absent/danmaku
hints and protects AniSkip, anime-skip, TheIntroDB and learned hints. Explicit
anime IDs take precedence over episode-ID derivation. Events retain the newest
200 entries and original reference-date timestamps.

The result supplies the promoted hint and whether the current mapped episode
can receive it. The app keeps its existing diagnostic messages and passes the
captured request ID to playback; playback's source ranking protects stronger
live hints. Confirmation intentionally requests no immediate playback update.

The Core state lock serializes decisions and write-through memory changes.
Existing atomic-file/best-effort persistence semantics remain; failed disk
writes increment store/cache diagnostics. Cancellation before entry avoids all
writes. Six workflow fixtures compare the independent native implementation
and cover exact IDs, file compatibility, source protection, concurrent
confirmation and cancellation.

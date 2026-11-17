# Core completion audit integration

The current shared business command surface has a source-backed 370-command
inventory and native call/setting ownership audit in the OcPlayer-Core repository.
Windows adapter work is handed back to the user.

`PlaybackPreferences` now supplies Foundation-cast presence/value facts to
`preferences.resolve`. Core owns all 29 runtime default/range/option and nullable
style rules. Native setters, UserDefaults, SubtitleStyle construction and decoder/
render effects keep their existing contracts. Disabled mode retains the original
native rules. The enabled differential test compares 18 complete projections and
requires successful Core execution for each getter; existing preference tests
also remain in the complete macOS suite.

The Apple SDK keeps original JSON tokens during asynchronous dispatch, separates
explicit request controls from ordinary request reservation, and preserves exact
original event/snapshot bytes for typed decoding. Incomplete or incompatible
native libraries are rejected and unloaded. Core handles cancellation metadata
outside strict local DTOs and retains streamed-event request correlation.

Core transport now stream-decodes gzip/deflate/Brotli with native header/status/URL
fidelity and incremental SSE. Its typed MoviePilot current-user path tolerates
permission-map extension fields consistently with MPUser. Native URLSession and
real saved-account checks exercise these changes; temporary test servers close
at the end of each test. The complete logs and playback evidence live under
OcPlayer-Core/docs/validation/2026-11-14-completion-audit/.

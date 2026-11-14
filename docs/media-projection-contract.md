# Core media metadata projection

`media.subtitles` and `media.fileInfo` now return canonical `subtitles` and
`fileInfo` projections alongside their existing raw query result. Original
Items, source/stream fields and plugin properties remain intact. Existing raw
consumers can keep reading them; the macOS facade consumes the canonical fields.
The Rust composition root owns selection, filtering, defaults and file metadata.

Selection uses the same retained preparation rule as native MediaSourceSelection:
first direct-play source, then direct-stream source, then the first source.
Empty sources produce null file info and empty external subtitles. An explicitly
provided subtitle source ID matches exactly; an absent match, including an empty
ID, produces no subtitles and never selects another source. A source without an
ID can still be the preferred source, retaining a null mediaSourceId. The Apple
adapter constructs the existing ExternalSubtitle namespace/identity/download
path and performs physical downloads with the native transport.

Metadata always reads `GET /Items?ids=...&fields=MediaSources&userId=...`.
The selected source is chosen locally, is not forwarded as a server filter, and
does not create a PlaybackInfo session. A mediaSourceId value must be a string,
null or absent; other types fail as invalid arguments before HTTP dispatch.

File info contains the first Video, all Audio and all Subtitle streams, retaining
original codecs/languages/titles, flags, channel layout, bitrates, HDR/profile,
Int64 size, duration, file basename and original source count. File track titles
use Title only; external subtitles may fall back to DisplayTitle. External
subtitles require Type=Subtitle, IsExternal=true, an index and a supported text
codec (srt/subrip/ass/ssa/vtt/webvtt); codec normalization happens in Core.

Frame rates use the first valid value in average/real order, with strict
0 < rate < 1000 bounds. Jellyfin's reference SDK decodes these as Float32 and
then converts to Double; Core retains that rounding before checking bounds and
rejects Float32 overflow/nonzero underflow. Emby retains its Double values. Jellyfin stream and
video-range enums use the current reference SDK's declared values; unknown
values fail decoding. Emby raw strings remain tolerated, with unknown types
ignored by the same exact-case Video/Audio/Subtitle filters as native mapping.

Source and projected stream scalars are typed and decoded before selection.
Wrong non-null types fail with 1514/non-retryable, including fields on unselected
sources. Missing/null optional fields retain native defaults. Null list/source/
stream behavior from the prior media-nullability contract remains accepted.
Basenames follow the native macOS slash rules, including trailing slash, root,
empty paths and literal Windows-style backslashes returned by a server.

Eight new Rust cases, six public C ABI HTTP cases and eight explicitly activated
native/Core HTTP comparisons cover source isolation/priority, complete encoded
file info, Int64.max, flags/codec filtering, nullable fields, basename variants,
Float32/Double boundaries, malformed scalars, flavor enums and request identity.
The Native before-change tests expose 79 failing assertions; the first canonical
projection comparison exposed four additional Jellyfin Float32 differences.
Original failure logs remain in the validation report.

This covers media metadata projection behavior, not every unused SDK field,
transport or remaining product requirement. Full OcPlayer-Core completion remains
subject to the macOS parity ledger and Windows adapter delivery; Windows runtime
testing is deferred by the user.

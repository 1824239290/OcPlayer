# Retained playback preparation

`playbackPreparation.*` owns leaf resolution, source negotiation, resume/title
policy, fallback and final presentation leases per Core handle. macOS retains full
MediaItem, PlaybackInfo and PlaybackMediaSource objects under opaque keys. Core
receives only policy fields; the host owns HTTP, decoder presentation, reporting,
diagnostics, home snapshots and native object construction.

## Receipts and lifetime

`start` accepts `mode` (`resolve` or `open`), an `item` projection and nullable
`resumeSeconds`. Each returned step carries a non-reused unsigned `token`, a
monotonic unsigned `sequence`, nullable `effect` and its `arguments`, `done` and
nullable `result`. `resume` acknowledges an exact token/sequence with `response`;
`fail` supplies `error` and `cancelled`. `validate` checks the lease before a host
effect, `cancel` retires only that token and `invalidate` retires all outstanding
work. `stats` exposes active count. At most 128 preparations coexist.
Malformed responses return 1002 without consuming state; retired or mismatched
receipts return 1003. Overflow fails before mutation. The Apple SDK maps retired
receipts to CancellationError and decodes original wire bytes, preserving UInt64
receipts and signed 64-bit opaque policy values.

## Effects and policy

| Effect | Host response and behavior |
| --- | --- |
| `collectionMembers` | Full default-page nonrecursive collection contents projected as items |
| `home` | Current nextUp/resume projections, read when this effect runs |
| `episodes` | Full episode list; exclude season zero for initial resolution |
| `resolved` | Update loading title, acknowledge true |
| `playbackInfo` | Opaque source projections and optional playSessionId |
| `streamURL` | URI string for primary, alternate or fallback role |
| `fallback` | Record original info/primary error, acknowledge true |
| `ready` | Validate, construct native result and present synchronously, acknowledge true |

Collections choose the first unplayed movie/episode, then first playable leaf;
collections containing only series resolve the first series. Series prefer a
matching nextUp entry, then resume, then first unplayed nonspecial episode, then
first nonspecial episode. Home is read after any collection await. Native episode
ordering is preserved. Empty results retain localized original-entry messages.
Episode titles use series name and optional S/E numbers. Same item ID retains the
caller resume; newly resolved IDs use their saved position.

Sources prefer first direct play, then first direct stream, then first. Alternate
URLs are generated in original source order, excluding every source with the
preferred ID. An alternate failure skips only that candidate. Info or primary URL
failure triggers a direct URL without old source/session IDs; a second failure
reports the original negotiation error. Resolver errors preserve native typed
errors. Task cancellation retires its lease; an isolated info CancellationError
without Task cancellation retains the original fallback behavior. Invalidated late
HTTP results cannot update UI or consume a newer preparation.

`ready` remains leased until its true acknowledgment. Native validates before and
after awaited effects and immediately before synchronous presentation. Core mode
never silently switches to the independent native implementation on an error.
OCP_CORE_ENABLED=0 selects the independently retained original policy.

## Server and wire corrections

Jellyfin and Emby episode requests use `Shows/{seriesId}/Episodes` with native
user/season/image/user-data options. Full lists sort by season, episode and ID;
missing numbers sort after real Int32.max. Continuation requests pass startItemId
and limit to the server and retain server order, including interstitial specials.
Typed native server results decode original response bytes, preserving Int64.max
source size. Playback source HDR derives from the first Video stream, with the
existing top-level fallback. Stream metadata and PascalCase field aliases survive
serialization. VideoRange is not substituted for the finer VideoRangeType.

Real HTTP fixtures exercise both protocols, full metadata/source context, HDR,
resume, alternate ordering, authentication, episode endpoint and continuation.
URI parameter names are compared case-insensitively; source/session values and
absence of URL API keys remain strict. Built-in URI casing is preserved.

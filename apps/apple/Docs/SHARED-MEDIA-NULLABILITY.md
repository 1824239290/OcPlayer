# Media response nullability and projection parity

Jellyfin and Emby query-result `Items`, playback `MediaSources`, source
`MediaStreams`, `Chapters`, genres and people may be omitted or null. Core accepts these
as empty collections while retaining session identity and source metadata.
A non-null value of the wrong container type remains a decode failure (1514,
non-retryable). Emby `/Items/Latest` still uses the native bare-array response.
The raw subtitles/file-info responses retain their fields; Core validates their
query envelope and the Apple adapter validates source and stream arrays.

Item normalization follows the current native mapping:

- Missing ID uses the same FNV-1a identity from original name/type; missing name
  becomes `未命名`, missing type becomes `other`. Explicit empty strings stay empty.
- Missing user data remains absent. Present user data with null played/position
  defaults to false/zero. Partial cast entries missing ID/name are omitted and
  a missing person type defaults to Actor.
- Primary image follows own/album/series precedence; episodes use their own
  primary tag. Backdrops come from the first backdrop-array entry. Parent logo,
  primary, thumb and backdrop identity/tags survive normalization.
- A season uses its own ID, name and index, with no episode number.
- Provider IDs retain native key aliases. MAL comes from Mal/MyAnimeList/mal;
  TVDB is a different provider and must not populate MAL.
- Similar results use the same typed normalization as detail/list results.
- Libraries retain optional identity until the Apple adapter supplies the native
  UUID default; collection types are case insensitive and unknown/folders are
  filtered as in the native facade.

Detail uses Jellyfin `Items/{id}` and Emby `Users/{userId}/Items/{id}`. Both
explicitly request People, Genres, Overview, Chapters and PrimaryImageAspectRatio
as the native clients do. The fixture rejects a missing People field or a modern
Emby detail route, so permissive test routing cannot conceal these differences.

Emby media segments read `Users/{userId}/Items/{id}?fields=Chapters`, rather than Jellyfin's
`MediaSegments/{id}` plugin endpoint. Numeric or case-insensitive textual
intro-start, intro-end and credits-start markers retain the first occurrence.
When intro-end is absent, the next chapter start closes the intro. Valid credits
run to item duration. Unknown/malformed marker values are ignored as in EmbyWire.
Jellyfin retains its plugin endpoint and Intro/Outro mapping.

Acceptance uses the same localhost fixture in Core and JellyfinKit, compared
byte-for-byte by the macOS gate. Eight native HTTP cases compare native and
explicitly activated Core facades for both server flavors, including full encoded
MediaItem/file-info equality, playback preparation with null streams, exact
Int64 size, invalid containers, libraries and Emby markers. Four independent
public C ABI cases validate canonical output and error envelopes. Six Rust model
cases cover defaulting, images, provider aliases and container strictness.

This closes the null-stream defect recorded in the prior continuation report.
It establishes parity for the covered fields, not exhaustive server-schema,
transport or overall product completion. See the macOS parity ledger.

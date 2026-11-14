# OcPlayer-Core

Shared GPL-3.0 Rust core for OcPlayer on macOS, iOS, and Windows.

The workspace contains the stable C ABI, JSON command/response envelope,
snapshots, FIFO events, playback session primitives, and domain crates
for HTTP, Jellyfin/Emby, SQLite, TMDB, danmaku, Bangumi, and MoviePilot. Platform
clients own their native UI, window/surface lifecycle, audio session,
credentials, and system services.

```bash
cargo test
cargo run -p ocp-cli -- ping
cargo run -p ocp-cli -- replay fixtures/playback-basic.jsonl
```

The core exposes a C ABI in `include/ocplayer_core.h`. Commands use the JSON
response envelope documented in `docs/ffi-contract.md`; playback state is
available through the `core` and `playback` snapshots. The command surface
covers Jellyfin/Emby anonymous login, Quick Connect, browsing, detail/season/episode/media resources and
playback reporting, TMDB lookup, DanDanPlay identity matching, loading and complete gateway exchanges, Bangumi service calls,
MoviePilot login/media/torrent/download/subscription commands, SQLite-backed
progress, and versioned configuration/diagnostic export. `replay` accepts one
JSON command per line (`{"method":"...","arguments":{...}}`) and prints each
response followed by the final snapshot on stderr.

Playback leaf resolution, primary/alternate source negotiation, resume/title and
direct fallback now use retained preparation leases; see
[`docs/playback-preparation-contract.md`](docs/playback-preparation-contract.md).

Playback track preference, manual selection, import/sidecar loading, removal and
identified subtitle batches now use retained decoder effects; see
[`docs/playback-tracks-contract.md`](docs/playback-tracks-contract.md).

MoviePilot's macOS transport now includes first login, token-only silent refresh
and byte-preserving low-level exchanges through Core. Login/refresh/logout policy
is retained through [`docs/moviepilot-account-contract.md`](docs/moviepilot-account-contract.md).
Complete raw/named retry and auth replay run through
[`docs/moviepilot-flow-contract.md`](docs/moviepilot-flow-contract.md).
Its wire/retry boundaries and platform credential effects are documented in
[`docs/moviepilot-contract.md`](docs/moviepilot-contract.md).

Bangumi credential, OAuth and refresh generations now run in retained Core
account state, together with refresh ownership, expiration/session reuse and
profile-operation revision barriers. Collection/episode synchronization now uses
retained flows and transactional SQL receipts. Native credential storage and
effects remain adapters; see [`docs/bangumi-account-contract.md`](docs/bangumi-account-contract.md)
and [`docs/bangumi-sync-contract.md`](docs/bangumi-sync-contract.md).
Subject loading, tri-state collection reconciliation, progress and rating
mutations, batch readback and season completion now also use retained SQL/effect
flows; see [`docs/bangumi-progress-contract.md`](docs/bangumi-progress-contract.md).
The complete login/profile/logout/invalidation service sequences now also use
retained effects with atomic credential and DB clear guards; see
[`docs/bangumi-auth-flow-contract.md`](docs/bangumi-auth-flow-contract.md).

Danmaku matching policy and mapping/comment/intro-hint persistence now run in
Core. The shared cache reads and writes OcPlayer's existing JSON files; TTL,
bounded LRU memory and revision guards are documented in
[`docs/danmaku-cache-contract.md`](docs/danmaku-cache-contract.md).
Intro detection, cross-episode learning, source selection and sibling consensus
also run in Core; see [`docs/intro-contract.md`](docs/intro-contract.md).
AniSkip, AnimeSkip, TheIntroDB and AniList provider HTTP transport now runs in
Core, together with the first three providers' request/decoding/interval policies;
see [`docs/intro-provider-contract.md`](docs/intro-provider-contract.md). AniList
ordered identity resolution and native-compatible ID persistence also run in
Core; see [`docs/intro-identity-contract.md`](docs/intro-identity-contract.md).
Automatic/manual loading now uses a resumable Core flow, including matching
budgets, payload conversion and intro precedence; see
[`docs/danmaku-flow-contract.md`](docs/danmaku-flow-contract.md).
The standalone `danmaku.load` command and Apple loader now use that same complete
flow for a data consumer; see
[`docs/standalone-danmaku-contract.md`](docs/standalone-danmaku-contract.md).
Manual-seek confirmation and source-protected cross-episode learning promotion
share the same retained cache Core; see the complete workflow in
[`docs/intro-contract.md`](docs/intro-contract.md). Broader acceptance remains
in progress.

Native TMDB matching now uses Core's complete provider/parent/search and ranking
decisions, preserving injected searches and exact identifiers; see
[`docs/tmdb-matcher-contract.md`](docs/tmdb-matcher-contract.md).
TMDB network models also preserve full native integer ranges and Foundation
wire-decoding behavior; see [`docs/tmdb-wire-contract.md`](docs/tmdb-wire-contract.md).

The Apple client uses the same core facade for migrated browsing, reporting,
and playback state when `OCP_CORE_ENABLED=1` (or the matching UserDefaults
flag) is set; native decoding/rendering remains the platform adapter. The
checked-in `Scripts/build-apple-xcframework.sh` produces the release artifact
once the Apple Rust targets are installed. Windows remains a separate adapter
that consumes this ABI and is intentionally deferred until its native player
surface is available.


macOS integration checks (requires the OcPlayer Apple source checkout):

```bash
Scripts/verify-macos.sh /path/to/OcPlayer
```

This runs Rust checks, loads the built dylib in Swift package integration tests,
builds the native macOS app, and embeds/signs the core. Full raw logs are kept
with the application artifact. See `docs/macos-parity.md` for the broader
functional acceptance scope and outstanding migration work.

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

MoviePilot's macOS transport now includes first login, token-only silent refresh
and byte-preserving low-level exchanges through Core. Its wire/retry boundaries
and native credential lifecycle are documented in
[`docs/moviepilot-contract.md`](docs/moviepilot-contract.md).

Danmaku matching policy and mapping/comment/intro-hint persistence now run in
Core. The shared cache reads and writes OcPlayer's existing JSON files; TTL,
bounded LRU memory and revision guards are documented in
[`docs/danmaku-cache-contract.md`](docs/danmaku-cache-contract.md).

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

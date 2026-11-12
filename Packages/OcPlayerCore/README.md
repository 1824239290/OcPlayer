# OcPlayerCore

Minimal Swift adapter for the shared `OcPlayer-Core` C ABI. It is intentionally
small during the incremental migration: existing Swift playback and UI code
remain the source of truth until the Rust feature flag is introduced.

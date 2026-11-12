# OcPlayer-Core

Shared GPL-3.0 Rust core for OcPlayer on macOS, iOS, and Windows.

P0 establishes the stable C ABI, JSON command/response envelope, snapshots,
FIFO events, and the CLI diagnostic entry point. Platform clients own their
native UI, window/surface lifecycle, audio session, credentials, and system
services.

```bash
cargo test
cargo run -p ocp-cli -- ping
```


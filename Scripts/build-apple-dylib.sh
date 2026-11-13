#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:-$repo_root/artifacts/apple}"
target="${CARGO_BUILD_TARGET:-$(rustc -vV | awk '/^host:/ {print $2}')}"

cd "$repo_root"
export CARGO_INCREMENTAL=0
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/ocplayer-target}"
cargo build --locked --release -p ocp-ffi --target "$target"

library="$CARGO_TARGET_DIR/$target/release/libocp_ffi.dylib"
if [[ ! -f "$library" ]]; then
  echo "Expected dynamic library was not produced: $library" >&2
  exit 1
fi
mkdir -p "$output_dir"
cp "$library" "$output_dir/libocp_ffi.dylib"
echo "$output_dir/libocp_ffi.dylib"

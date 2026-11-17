#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [[ "${1:-}" == --universal ]]; then
  output_dir="${2:-$repo_root/artifacts/apple}"
  targets=(aarch64-apple-darwin x86_64-apple-darwin)
else
  output_dir="${1:-$repo_root/artifacts/apple}"
  targets=("${CARGO_BUILD_TARGET:-$(rustc -vV | awk '/^host:/ {print $2}')}")
fi
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/ocplayer-dylib.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT

cd "$repo_root"
export CARGO_INCREMENTAL=0
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/ocplayer-target}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
export CARGO_ENCODED_RUSTFLAGS="$(python3 - "$repo_root" <<'PY'
import os, sys
flags = os.environ.get('CARGO_ENCODED_RUSTFLAGS')
items = flags.split('\x1f') if flags is not None else os.environ.get('RUSTFLAGS', '').split()
items = [item for item in items if item]
items.append('--remap-path-prefix=' + sys.argv[1] + '=ocplayer-core')
print('\x1f'.join(items), end='')
PY
)"
libraries=()
for target in "${targets[@]}"; do
  cargo build --locked --release -p ocp-ffi --target "$target"
  library="$CARGO_TARGET_DIR/$target/release/libocp_ffi.dylib"
  if [[ ! -f "$library" ]]; then
    echo "Expected dynamic library was not produced: $library" >&2
    exit 1
  fi
  libraries+=("$library")
done

if [[ "${#libraries[@]}" == 2 ]]; then
  xcrun lipo -create "${libraries[@]}" -output "$stage_dir/libocp_ffi.dylib"
else
  cp "${libraries[0]}" "$stage_dir/libocp_ffi.dylib"
fi
cp "$stage_dir/libocp_ffi.dylib" "$output_dir/libocp_ffi.dylib"
echo "$output_dir/libocp_ffi.dylib"

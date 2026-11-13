#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:-$repo_root/artifacts/apple}"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/ocplayer-xcframework.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required to create the Apple XCFramework" >&2
  exit 1
fi

targets=(
  aarch64-apple-darwin
  x86_64-apple-darwin
  aarch64-apple-ios
  aarch64-apple-ios-sim
  x86_64-apple-ios
)
target_installed() {
  local target="$1"
  if command -v rustup >/dev/null 2>&1; then
    rustup target list --installed | rg -qx "$target"
  else
    test -d "$(rustc --print sysroot)/lib/rustlib/$target"
  fi
}

for target in "${targets[@]}"; do
  if ! target_installed "$target"; then
    echo "Missing Rust target $target (install with: rustup target add $target)" >&2
    exit 1
  fi
done

cd "$repo_root"
export CARGO_INCREMENTAL=0
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-/tmp/ocplayer-target}"
mkdir -p "$CARGO_TARGET_DIR"
CARGO_TARGET_DIR="$(cd "$CARGO_TARGET_DIR" && pwd)"
mkdir -p "$stage_dir/headers"
if command -v cbindgen >/dev/null 2>&1; then
  cbindgen --config cbindgen.toml --crate ocp-ffi --output "$stage_dir/headers/ocplayer_core.h"
else
  echo "cbindgen is unavailable; using the checked-in ABI header" >&2
  cp "$repo_root/include/ocplayer_core.h" "$stage_dir/headers/ocplayer_core.h"
fi

libraries=()
for target in "${targets[@]}"; do
  cargo build --locked --release -p ocp-ffi --target "$target"
  library="$CARGO_TARGET_DIR/$target/release/libocp_ffi.a"
  if [[ ! -f "$library" ]]; then
    echo "Expected static library was not produced: $library" >&2
    exit 1
  fi
  libraries+=("$library")
done

mkdir -p "$output_dir"
framework="$output_dir/OcPlayerCore.xcframework"
if [[ -e "$framework" ]]; then
  echo "Refusing to overwrite existing output: $framework" >&2
  exit 1
fi

# One library per platform/variant; architectures of the same variant share a slice.
mkdir -p "$stage_dir/macos" "$stage_dir/simulator"
xcrun lipo -create "${libraries[0]}" "${libraries[1]}" -output "$stage_dir/macos/libocp_ffi.a"
xcrun lipo -create "${libraries[3]}" "${libraries[4]}" -output "$stage_dir/simulator/libocp_ffi.a"
xcodebuild -create-xcframework \
  -library "$stage_dir/macos/libocp_ffi.a" -headers "$stage_dir/headers" \
  -library "${libraries[2]}" -headers "$stage_dir/headers" \
  -library "$stage_dir/simulator/libocp_ffi.a" -headers "$stage_dir/headers" \
  -output "$framework"

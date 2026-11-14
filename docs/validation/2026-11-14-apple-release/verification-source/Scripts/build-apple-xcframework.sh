#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
output_dir="${1:-$repo_root/artifacts/apple}"
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/ocplayer-xcframework.XXXXXX")"
trap 'rm -rf "$stage_dir"' EXIT
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
framework="$output_dir/OcPlayerCore.xcframework"
for item in OcPlayerCore.xcframework Package.swift Sources Tests LICENSE; do
  if [[ -e "$output_dir/$item" ]]; then
    echo "Refusing to overwrite existing output: $output_dir/$item" >&2
    exit 1
  fi
done

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
    rustup target list --installed | grep -qx "$target"
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
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"
# Keep panic/source paths independent of the checkout location. Encoded flags
# also preserve repository paths containing spaces as one rustc argument.
export CARGO_ENCODED_RUSTFLAGS="$(python3 - "$repo_root" <<'PY'
import os, sys
flags = os.environ.get('CARGO_ENCODED_RUSTFLAGS')
items = flags.split('\x1f') if flags is not None else os.environ.get('RUSTFLAGS', '').split()
items = [item for item in items if item]
items.append('--remap-path-prefix=' + sys.argv[1] + '=ocplayer-core')
print('\x1f'.join(items), end='')
PY
)"
mkdir -p "$CARGO_TARGET_DIR"
CARGO_TARGET_DIR="$(cd "$CARGO_TARGET_DIR" && pwd)"
mkdir -p "$stage_dir/headers"
if command -v cbindgen >/dev/null 2>&1; then
  cbindgen --config cbindgen.toml --crate ocp-ffi --output "$stage_dir/headers/ocplayer_core.h"
else
  echo "cbindgen is unavailable; using the checked-in ABI header" >&2
  cp "$repo_root/include/ocplayer_core.h" "$stage_dir/headers/ocplayer_core.h"
fi
cat > "$stage_dir/headers/module.modulemap" <<'MODULE'
module OcPlayerCoreFFI {
  header "ocplayer_core.h"
  export *
}
MODULE

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

# One library per platform/variant; architectures of the same variant share a slice.
mkdir -p "$stage_dir/macos" "$stage_dir/simulator"
xcrun lipo -create "${libraries[0]}" "${libraries[1]}" -output "$stage_dir/macos/libocp_ffi.a"
xcrun lipo -create "${libraries[3]}" "${libraries[4]}" -output "$stage_dir/simulator/libocp_ffi.a"
xcodebuild -create-xcframework \
  -library "$stage_dir/macos/libocp_ffi.a" -headers "$stage_dir/headers" \
  -library "${libraries[2]}" -headers "$stage_dir/headers" \
  -library "$stage_dir/simulator/libocp_ffi.a" -headers "$stage_dir/headers" \
  -output "$framework"

# Deliver a package that imports the C module and links each ABI entry directly.
# Merely adding a static archive to a dynamic-loader package can dead-strip Core.
cp -R "$repo_root/bindings/apple/OcPlayerCore/Sources" "$output_dir/Sources"
cp -R "$repo_root/bindings/apple/OcPlayerCore/Tests" "$output_dir/Tests"
cp "$repo_root/LICENSE" "$output_dir/LICENSE"
cat > "$output_dir/Package.swift" <<'PACKAGE'
// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "OcPlayerCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "OcPlayerCore", targets: ["OcPlayerCore"])],
    targets: [
        .binaryTarget(name: "OcPlayerCoreFFI", path: "OcPlayerCore.xcframework"),
        .target(name: "OcPlayerCore", dependencies: ["OcPlayerCoreFFI"], linkerSettings: [
            .linkedFramework("Security"), .linkedFramework("CoreFoundation"),
            .linkedLibrary("iconv"), .linkedLibrary("resolv"),
        ]),
        .testTarget(name: "OcPlayerCoreTests", dependencies: ["OcPlayerCore"], resources: [.copy("Fixtures")]),
    ]
)
PACKAGE
cp "$repo_root/bindings/apple/OcPlayerCore/README.md" "$output_dir/README.md"
python3 "$repo_root/Scripts/apple-release-manifest.py" "$repo_root" "$output_dir"

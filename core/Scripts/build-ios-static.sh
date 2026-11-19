#!/usr/bin/env bash
set -euo pipefail

# Source-checkout iOS linkage: only build the architectures Xcode is using.
# The release XCFramework builder remains available to external SDK consumers.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
destination="${1:?Usage: build-ios-static.sh /path/to/library-directory}"
case "${PLATFORM_NAME:-}" in
    iphoneos|iphonesimulator) ;;
    *) echo 'PLATFORM_NAME must be iphoneos or iphonesimulator' >&2; exit 2 ;;
esac
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$repo_root/target}"
export IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-16.0}"
profile=debug
cargo_options=(--locked -p ocp-ffi)
if [[ "${CONFIGURATION:-Debug}" == Release ]]; then
    profile=release
    cargo_options+=(--release)
fi
if [[ "${OCP_CORE_BUILD_STD:-0}" == 1 ]]; then
    # Optional source-built std for a Homebrew Rust installation with rust-src.
    # This is local to the build process; no global toolchain is modified.
    export RUSTC_BOOTSTRAP=1
    cargo_options+=(-Z build-std=std,panic_abort)
fi
libraries=()
for architecture in ${ARCHS:-arm64}; do
    case "$PLATFORM_NAME:$architecture" in
        iphoneos:arm64) target=aarch64-apple-ios ;;
        iphonesimulator:arm64) target=aarch64-apple-ios-sim ;;
        iphonesimulator:x86_64) target=x86_64-apple-ios ;;
        *) echo "Unsupported iOS Core architecture: $PLATFORM_NAME:$architecture" >&2; exit 2 ;;
    esac
    if [[ "${OCP_CORE_BUILD_STD:-0}" != 1 ]] &&
       [[ ! -d "$(rustc --print sysroot)/lib/rustlib/$target/lib" ]]; then
        echo "Missing Rust target $target. Install with: rustup target add $target" >&2
        echo 'Homebrew Rust with rust-src can instead build with OCP_CORE_BUILD_STD=1.' >&2
        exit 1
    fi
    cargo build --manifest-path "$repo_root/Cargo.toml" --target "$target" "${cargo_options[@]}"
    libraries+=("$CARGO_TARGET_DIR/$target/$profile/libocp_ffi.a")
done
mkdir -p "$destination"
staged="$(mktemp "$destination/libocp_ffi.XXXXXX")"
trap 'rm -f "$staged"' EXIT
if [[ "${#libraries[@]}" == 1 ]]; then
    cp "${libraries[0]}" "$staged"
else
    xcrun lipo -create "${libraries[@]}" -output "$staged"
fi
mv -f "$staged" "$destination/libocp_ffi.a"

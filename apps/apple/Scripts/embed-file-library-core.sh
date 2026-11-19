#!/usr/bin/env bash
set -euo pipefail

# File libraries use Core even while the media-server migration switch is off.
# Run before Xcode's app signature, without setting OcpCoreEnabled in Info.plist.
[[ "${PLATFORM_NAME:-}" == macosx ]] || exit 0
repo_root="$(cd "$SRCROOT/../.." && pwd -P)"
export PATH="$HOME/.cargo/bin:$PATH"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$repo_root/core/target}"
export MACOSX_DEPLOYMENT_TARGET=13.0
profile=debug
cargo_options=(--locked -p ocp-ffi)
if [[ "$CONFIGURATION" == Release ]]; then
    profile=release
    cargo_options+=(--release)
fi
host_target="$(rustc -vV | awk '/^host:/ {print $2}')"
libraries=()
for architecture in $ARCHS; do
    case "$architecture" in
        arm64) target=aarch64-apple-darwin ;;
        x86_64) target=x86_64-apple-darwin ;;
        *) echo "Unsupported Core architecture: $architecture" >&2; exit 1 ;;
    esac
    if [[ "$target" == "$host_target" ]]; then
        cargo build --manifest-path "$repo_root/core/Cargo.toml" "${cargo_options[@]}"
        libraries+=("$CARGO_TARGET_DIR/$profile/libocp_ffi.dylib")
    else
        cargo build --manifest-path "$repo_root/core/Cargo.toml" --target "$target" "${cargo_options[@]}"
        libraries+=("$CARGO_TARGET_DIR/$target/$profile/libocp_ffi.dylib")
    fi
done
destination="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libocp_ffi.dylib"
mkdir -p "$(dirname "$destination")"
if [[ "${#libraries[@]}" == 1 ]]; then
    cp "${libraries[0]}" "$destination"
else
    xcrun lipo -create "${libraries[@]}" -output "$destination"
fi
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
    codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$destination"
fi

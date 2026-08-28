#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/OcPlayer.xcodeproj"
SCHEME="OcPlayer-macOS"
BUILD_DIR="$ROOT/.local-build/current"
DERIVED_DATA="$BUILD_DIR/DerivedData"
# 默认拉 fork 的预读内核：与 Vendor 现有产物同版本，fetch 直接命中缓存，
# 不会像旧的 latest 那样去上游下载官方内核覆盖本地自编译产物。
# 内核改动合并上游后，这里与 CI 两个 workflow 一起切回官方 latest。
export ERIKA_VERSION="${ERIKA_VERSION:-v0.1.7+readahead.1}"
export ERIKA_REPO="${ERIKA_REPO:-1824239290/Erika}"

usage() {
    echo "Usage: Scripts/build-macos.sh [debug|release]" >&2
}

case "${1:-debug}" in
    debug|Debug)
        CONFIGURATION="Debug"
        ;;
    release|Release)
        CONFIGURATION="Release"
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
esac

if [[ $# -gt 1 ]]; then
    usage
    exit 2
fi

if ! xcodebuild -version >/dev/null 2>&1; then
    export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "xcodebuild is unavailable. Select Xcode first:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

echo "Checking Erika core ($ERIKA_VERSION)..."
"$ROOT/Scripts/fetch-erika.sh" "$ERIKA_VERSION"

# This path is intentionally fixed: every run replaces the previous local build.
if [[ "$BUILD_DIR" != "$ROOT/.local-build/current" ]]; then
    echo "Refusing to clean unexpected build directory: $BUILD_DIR" >&2
    exit 1
fi

echo "Cleaning previous build: $BUILD_DIR"
rm -rf "$BUILD_DIR"
mkdir -p "$DERIVED_DATA"

echo "Building $SCHEME ($CONFIGURATION)..."
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/OcPlayer.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Build succeeded but the app was not found at $APP_PATH" >&2
    exit 1
fi

echo
echo "Build complete:"
echo "  $APP_PATH"

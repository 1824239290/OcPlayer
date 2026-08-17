#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/OcPlayer.xcodeproj"
SCHEME="OcPlayer-macOS"
BUILD_DIR="$ROOT/.local-build/current"
DERIVED_DATA="$BUILD_DIR/DerivedData"
ERIKA_XCFRAMEWORK="$ROOT/Packages/ErikaKit/Vendor/Erika.xcframework"

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

if [[ ! -d "$ERIKA_XCFRAMEWORK" ]]; then
    echo "Erika.xcframework is missing; fetching it first."
    "$ROOT/Scripts/fetch-erika.sh"
fi

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

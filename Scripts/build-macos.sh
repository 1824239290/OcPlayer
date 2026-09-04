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

XCCONFIG_VERSION="$(sed -n 's/^MARKETING_VERSION *= *//p' "$ROOT/Config/App.xcconfig" | head -1 | tr -d '[:space:]')"
GIT_COUNT="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
GIT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
    GIT_DIRTY="-dirty"
else
    GIT_DIRTY=""
fi
GIT_INFO="${GIT_COMMIT}${GIT_DIRTY}"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-$GIT_COUNT}}"

echo "Building $SCHEME ($CONFIGURATION) [v$XCCONFIG_VERSION Build $BUILD_NUMBER · $GIT_INFO]..."
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -quiet \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$XCCONFIG_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    GIT_COMMIT_HASH="$GIT_INFO" \
    build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/OcPlayer.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Build succeeded but the app was not found at $APP_PATH" >&2
    exit 1
fi

echo
echo "Build complete (v$XCCONFIG_VERSION Build $BUILD_NUMBER · $GIT_INFO):"
echo "  $APP_PATH"

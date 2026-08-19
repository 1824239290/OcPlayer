#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_TAG="${1:-v0.1.1}"
ERIKA_VERSION="${ERIKA_VERSION:-latest}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/.local-build/release}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP_NAME="OcPlayer"
SCHEME="OcPlayer-macOS"

SAFE_TAG="$(printf '%s' "$RELEASE_TAG" | tr -c 'A-Za-z0-9._-' '-')"
ARTIFACT_BASE="$APP_NAME-$SAFE_TAG-macOS-arm64"
ZIP_PATH="$DIST_DIR/$ARTIFACT_BASE.zip"
DMG_PATH="$DIST_DIR/$ARTIFACT_BASE.dmg"
CHECKSUM_PATH="$DIST_DIR/SHA256SUMS.txt"

if [[ "$RELEASE_TAG" =~ ^v?([0-9]+\.[0-9]+\.[0-9]+)([-+][A-Za-z0-9.-]+)?$ ]]; then
    MARKETING_VERSION="${BASH_REMATCH[1]}"
else
    echo "Release tag must use semantic versioning, for example v0.1.0" >&2
    exit 2
fi

"$ROOT/Scripts/fetch-erika.sh" "$ERIKA_VERSION"

mkdir -p "$BUILD_ROOT" "$DIST_DIR"
rm -f "$ZIP_PATH" "$DMG_PATH" "$CHECKSUM_PATH"

xcodebuild \
    -project "$ROOT/OcPlayer.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$BUILD_ROOT/DerivedData" \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGNING_ALLOWED=NO \
    DEBUG_INFORMATION_FORMAT=dwarf \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER:-1}" \
    build

APP_PATH="$BUILD_ROOT/DerivedData/Build/Products/Release/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Build succeeded but $APP_PATH was not produced" >&2
    exit 1
fi

# Ad-hoc signing makes the bundle internally consistent. Public distribution
# still requires Developer ID signing and Apple notarization.
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Third-party license compliance: ship Erika's bundled license texts with the app.
NOTICES_DIR="$APP_PATH/Contents/Resources/THIRD_PARTY_LICENSES"
ERIKA_MAC_EXTRACTED="$ROOT/Vendor/extracted/erika-capi-macos-arm64"
if [[ ! -d "$ERIKA_MAC_EXTRACTED/licenses" ]]; then
    echo "Missing Erika license texts under $ERIKA_MAC_EXTRACTED/licenses" >&2
    exit 1
fi
mkdir -p "$NOTICES_DIR/erika"
cp "$ERIKA_MAC_EXTRACTED/LICENSE" "$NOTICES_DIR/erika/"
cp "$ERIKA_MAC_EXTRACTED/THIRD_PARTY_NOTICES.md" "$NOTICES_DIR/erika/"
cp -R "$ERIKA_MAC_EXTRACTED/licenses/." "$NOTICES_DIR/erika/licenses/"
codesign --force --sign - "$APP_PATH"

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ocplayer-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGE"' EXIT
ditto "$APP_PATH" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGE" \
    -format UDZO \
    -ov \
    "$DMG_PATH" >/dev/null

(
    cd "$DIST_DIR"
    shasum -a 256 "$(basename "$ZIP_PATH")" "$(basename "$DMG_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

echo "Release artifacts:"
printf '  %s\n' "$ZIP_PATH" "$DMG_PATH" "$CHECKSUM_PATH"

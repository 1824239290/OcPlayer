#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_TAG="${1:-v0.1.3}"
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

# Third-party license compliance: ship Erika's bundled notices and every
# resolved SwiftPM dependency license with the app.
NOTICES_DIR="$APP_PATH/Contents/Resources/THIRD_PARTY_LICENSES"
ERIKA_MAC_EXTRACTED="$ROOT/Vendor/extracted/erika-capi-macos-arm64"
SWIFTPM_CHECKOUTS="$BUILD_ROOT/DerivedData/SourcePackages/checkouts"
if [[ ! -d "$ERIKA_MAC_EXTRACTED/licenses" ]]; then
    echo "Missing Erika license texts under $ERIKA_MAC_EXTRACTED/licenses" >&2
    exit 1
fi
if [[ ! -d "$SWIFTPM_CHECKOUTS" ]]; then
    echo "Missing SwiftPM checkouts under $SWIFTPM_CHECKOUTS" >&2
    exit 1
fi

copy_license() {
    local source_path="$1"
    local destination_path="$2"
    if [[ ! -f "$source_path" ]]; then
        echo "Missing third-party license: $source_path" >&2
        exit 1
    fi
    mkdir -p "$(dirname "$destination_path")"
    cp "$source_path" "$destination_path"
}

verify_sha256() {
    local file_path="$1"
    local expected="$2"
    local actual
    actual="$(shasum -a 256 "$file_path" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "SHA-256 mismatch for $file_path" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        exit 1
    fi
}

rm -rf "$NOTICES_DIR"
mkdir -p "$NOTICES_DIR/erika"
copy_license "$ERIKA_MAC_EXTRACTED/LICENSE" "$NOTICES_DIR/erika/LICENSE"
copy_license "$ERIKA_MAC_EXTRACTED/MANIFEST.txt" "$NOTICES_DIR/erika/MANIFEST.txt"
copy_license "$ERIKA_MAC_EXTRACTED/THIRD_PARTY_NOTICES.md" "$NOTICES_DIR/erika/THIRD_PARTY_NOTICES.md"
cp -R "$ERIKA_MAC_EXTRACTED/licenses/." "$NOTICES_DIR/erika/licenses/"

# jellyfin-sdk-swift identifies its sources as MPL-2.0 but does not ship a
# top-level LICENSE file. Erika's LICENSE is the canonical, unmodified MPL-2.0
# text. Verify that exact standard text before reusing it; no network fetch is
# needed during packaging.
verify_sha256 \
    "$ERIKA_MAC_EXTRACTED/LICENSE" \
    "3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04"
copy_license \
    "$ERIKA_MAC_EXTRACTED/LICENSE" \
    "$NOTICES_DIR/swiftpm/jellyfin-sdk-swift/LICENSE-MPL-2.0"
copy_license \
    "$SWIFTPM_CHECKOUTS/Get/LICENSE" \
    "$NOTICES_DIR/swiftpm/Get/LICENSE"
copy_license \
    "$SWIFTPM_CHECKOUTS/swift-nio-transport-services/LICENSE.txt" \
    "$NOTICES_DIR/swiftpm/swift-nio-transport-services/LICENSE.txt"
copy_license \
    "$SWIFTPM_CHECKOUTS/swift-nio/LICENSE.txt" \
    "$NOTICES_DIR/swiftpm/swift-nio/LICENSE.txt"
copy_license \
    "$SWIFTPM_CHECKOUTS/swift-nio/NOTICE.txt" \
    "$NOTICES_DIR/swiftpm/swift-nio/NOTICE.txt"
copy_license \
    "$SWIFTPM_CHECKOUTS/swift-atomics/LICENSE.txt" \
    "$NOTICES_DIR/swiftpm/swift-atomics/LICENSE.txt"
copy_license \
    "$SWIFTPM_CHECKOUTS/swift-collections/LICENSE.txt" \
    "$NOTICES_DIR/swiftpm/swift-collections/LICENSE.txt"
copy_license \
    "$SWIFTPM_CHECKOUTS/swift-system/LICENSE.txt" \
    "$NOTICES_DIR/swiftpm/swift-system/LICENSE.txt"
copy_license \
    "$SWIFTPM_CHECKOUTS/GRDB.swift/LICENSE" \
    "$NOTICES_DIR/swiftpm/GRDB.swift/LICENSE"
copy_license \
    "$ROOT/OcPlayer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved" \
    "$NOTICES_DIR/swiftpm/Package.resolved"

# The license list above is hand-written, so a new SwiftPM dependency would
# otherwise ship without its notice. Fail the build when a resolved checkout has
# no corresponding entry under THIRD_PARTY_LICENSES.
for checkout in "$SWIFTPM_CHECKOUTS"/*; do
    [[ -d "$checkout" ]] || continue
    name="$(basename "$checkout")"
    if [[ ! -d "$NOTICES_DIR/swiftpm/$name" ]]; then
        echo "SwiftPM dependency '$name' has no license bundled under $NOTICES_DIR/swiftpm" >&2
        echo "Add a copy_license entry for it in Scripts/package-macos.sh" >&2
        exit 1
    fi
done
codesign --force --sign - "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

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

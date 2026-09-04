#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 不带参数时从 App.xcconfig 读版本号（唯一事实源），避免脚本里再硬编码一份漂移。
XCCONFIG_VERSION="$(sed -n 's/^MARKETING_VERSION *= *//p' "$ROOT/Config/App.xcconfig" | head -1 | tr -d '[:space:]')"

# Git 信息与构建号推导：
# 1. 提交总数作为默认 Build 号（严格单调递增，符合 Apple CFBundleVersion 规范）
# 2. 短 commit hash 与 dirty 标记（方便测试追踪具体代码改动）
GIT_COUNT="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
GIT_COMMIT="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
if [[ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
    GIT_DIRTY="-dirty"
else
    GIT_DIRTY=""
fi
GIT_INFO="${GIT_COMMIT}${GIT_DIRTY}"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-$GIT_COUNT}}"

IS_LOCAL_BUILD=0
if [[ $# -eq 0 ]]; then
    IS_LOCAL_BUILD=1
    RELEASE_TAG="${XCCONFIG_VERSION:+v$XCCONFIG_VERSION}"
else
    RELEASE_TAG="$1"
fi

ERIKA_VERSION="${ERIKA_VERSION:-v0.1.7+dolby.2}"
# 必须 export：fetch-erika.sh 是子进程，普通变量它读不到，会静默回落上游仓库。
export ERIKA_REPO="${ERIKA_REPO:-1824239290/Erika}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT/.local-build/release}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP_NAME="OcPlayer"
SCHEME="OcPlayer-macOS"

SAFE_TAG="$(printf '%s' "$RELEASE_TAG" | tr -c 'A-Za-z0-9._-' '-')"
if [[ "$IS_LOCAL_BUILD" -eq 1 ]]; then
    SAFE_BUILD="$(printf '%s' "$GIT_INFO" | tr -c 'A-Za-z0-9._-' '-')"
    ARTIFACT_BASE="$APP_NAME-$SAFE_TAG-b$BUILD_NUMBER-$SAFE_BUILD-macOS-arm64"
else
    ARTIFACT_BASE="$APP_NAME-$SAFE_TAG-macOS-arm64"
fi
ZIP_PATH="$DIST_DIR/$ARTIFACT_BASE.zip"
DMG_PATH="$DIST_DIR/$ARTIFACT_BASE.dmg"
CHECKSUM_PATH="$DIST_DIR/SHA256SUMS.txt"

if [[ "$RELEASE_TAG" =~ ^v?([0-9]+\.[0-9]+\.[0-9]+)([-+][A-Za-z0-9.-]+)?$ ]]; then
    MARKETING_VERSION="${BASH_REMATCH[1]}"
else
    echo "Release tag must use semantic versioning, for example v0.1.0" >&2
    exit 2
fi

# SKIP_ERIKA_FETCH=1：使用 Vendor 里现成的内核（自编译/实验分支产物），
# 不跑 fetch-erika.sh —— 后者会从上游 Release 拉官方包**覆盖**本地产物。
if [[ "${SKIP_ERIKA_FETCH:-0}" != "1" ]]; then
    "$ROOT/Scripts/fetch-erika.sh" "$ERIKA_VERSION"
else
    # 自编译产物至少要带新 API 符号对应的头，防呆：头文件不对就尽早失败。
    grep -q "ErikaOpenOptions" "$ROOT/Packages/ErikaKit/Sources/CErika/include/erika.h" || {
        echo "SKIP_ERIKA_FETCH=1 但 CErika 头里没有 ErikaOpenOptions —— Vendor 不是自编译内核？" >&2
        exit 2
    }
    echo "· 跳过 fetch-erika（使用 Vendor 现有内核）"
fi

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
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    GIT_COMMIT_HASH="$GIT_INFO" \
    build

APP_PATH="$BUILD_ROOT/DerivedData/Build/Products/Release/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Build succeeded but $APP_PATH was not produced" >&2
    exit 1
fi

# Third-party license compliance: ship Erika's bundled notices and every
# resolved SwiftPM dependency license with the app.
# 签名放在许可证拷贝之后只做一次：先签再改 bundle 会作废签名，前一次纯浪费。
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

# Vendored 本地包（Packages/ 下带 PROVENANCE.md 的第三方代码）也在随包分发之列。
copy_license \
    "$ROOT/Packages/DanmakuRenderKit/LICENSE" \
    "$NOTICES_DIR/DanmakuRenderKit/LICENSE"
copy_license \
    "$ROOT/Packages/DanmakuRenderKit/PROVENANCE.md" \
    "$NOTICES_DIR/DanmakuRenderKit/PROVENANCE.md"

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

# 本地 vendored 包（有 PROVENANCE.md）不在 SWIFTPM_CHECKOUTS 里，上面那个循环
# 看不到它们——单独校验：漏登记 / 漏拷贝直接让打包失败。
for pkg in "$ROOT"/Packages/*; do
    [[ -d "$pkg" ]] || continue
    name="$(basename "$pkg")"
    [[ -f "$pkg/PROVENANCE.md" ]] || continue
    if [[ ! -d "$NOTICES_DIR/$name" ]]; then
        echo "Vendored package '$name' has no license bundled under $NOTICES_DIR/$name" >&2
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

echo "Release artifacts (v$MARKETING_VERSION Build $BUILD_NUMBER · $GIT_INFO):"
printf '  %s\n' "$ZIP_PATH" "$DMG_PATH" "$CHECKSUM_PATH"

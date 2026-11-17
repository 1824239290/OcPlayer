#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 内核版本唯一事实源：Config/Erika.version（见该文件注释）。
# 环境变量 ERIKA_VERSION 仍可覆盖，用于临时试版本。
erika_version_from_config() {
    local file="$ROOT/Config/Erika.version"
    [[ -f "$file" ]] || { echo "✗ 缺少 $file（内核版本唯一事实源）" >&2; exit 3; }
    local value
    value="$(awk -F= '/^[[:space:]]*ERIKA_VERSION[[:space:]]*=/ {sub(/^[^=]*=[[:space:]]*/, ""); print; exit}' "$file")"
    [[ -n "$value" ]] || { echo "✗ $file 里没有 ERIKA_VERSION=" >&2; exit 3; }
    printf '%s\n' "$value"
}
PROJECT="$ROOT/OcPlayer.xcodeproj"
SCHEME="OcPlayer-macOS"
# `BUILD_DIR` 可覆盖（`BLD-01`）：默认仍是 `.local-build/current`，但允许与
# `package-*.sh` 的 `BUILD_ROOT` 对齐 —— 本地「先 build 再 package」时不会因为
# 落到不同根而全量重编一遍。
#
# ⚠️ 覆盖只允许落在 `.local-build/` 之下（下面有守卫），避免把产物写到源码目录。
BUILD_DIR="${BUILD_DIR:-$ROOT/.local-build/current}"
DERIVED_DATA="$BUILD_DIR/DerivedData"
export ERIKA_VERSION="${ERIKA_VERSION:-$(erika_version_from_config)}"

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
# SKIP_ERIKA_FETCH=1 跳过 fetch,直接用 Vendor 现有产物构建本地自编译内核
# (与 package-macos.sh / package-ios.sh 同一开关)。fetch 会按 ERIKA_VERSION
# 重新解包 Release 产物,把手动铺进 Vendor 的自编译内核静默覆盖回发行版。
if [[ "${SKIP_ERIKA_FETCH:-0}" != "1" ]]; then
    "$ROOT/Scripts/fetch-erika.sh" "$ERIKA_VERSION"
else
    if ! grep -q "ErikaOpenOptions" Packages/ErikaKit/Sources/CErika/include/erika.h; then
        echo "SKIP_ERIKA_FETCH=1 but shim header looks stale (missing ErikaOpenOptions)" >&2
        exit 1
    fi
    echo "Skipping Erika fetch (SKIP_ERIKA_FETCH=1) — using Vendor as-is."
fi

# 每次运行都整体替换上一次的本地构建（不做增量，避免配置串味）。
#
# ## 守卫：先**规范化**，再检查前缀
#
# 原先是「`BUILD_DIR` 必须恰好等于 `$ROOT/.local-build/current`」—— 那样覆盖就没法用。
# 放宽成前缀检查时有个坑：`case` 做的是**字面**前缀匹配，于是
#
#     BUILD_DIR="$ROOT/.local-build/../.."
#
# 会**通过**检查，而下一行 `rm -rf` 会删掉仓库的父目录。路径穿越必须在这里挡掉。
#
# 所以先 `cd` 进目标目录（或它最近的已存在祖先）拿物理路径 `pwd -P`，再判断它是否
# 落在 `.local-build/` 之内 —— 这样 `..`、符号链接（`pwd -P` 会解析）都被规范化掉。
# 规范化一个路径：处理 `.` / `..` / 重复斜杠，**不要求路径存在**。
#
# 为什么要自己写：macOS 的 `realpath` 没有 `-m`（GNU 才有），而目标目录可能
# 还不存在（首次构建），所以不能靠 `cd` + `pwd -P` 单独解决 —— 那条路只对
# **已存在**的前缀生效，`nope/../../..` 这种「中间组件不存在」的穿越会漏过去
# （实测确认）。
normalize_path() {
    local input="$1"
    # 相对路径先接到调用方给的工作目录上（这里统一用仓库根，见下面用法）。
    [[ "$input" != /* ]] && input="$PWD/$input"
    local -a parts=()
    local IFS='/'
    for seg in $input; do
        case "$seg" in
            ''|'.') continue ;;
            '..')
                # 已经在根上就忽略（`/..` == `/`），否则弹一层。
                (( ${#parts[@]} > 0 )) && unset "parts[${#parts[@]}-1]"
                ;;
            *) parts+=("$seg") ;;
        esac
    done
    local out=""
    for seg in "${parts[@]}"; do out="$out/$seg"; done
    printf '%s\n' "${out:-/}"
}

# 再解析符号链接：取其**已存在前缀**的物理路径。这样 `evil -> /tmp` 这类
# 中间符号链接会被解析成真实位置，从而被前缀检查挡住（`rm -rf` 会跟随中间组件）。
physical_path() {
    local target="$1"
    local probe="$target"
    while [[ ! -e "$probe" && "$probe" != "/" ]]; do
        probe="$(dirname "$probe")"
    done
    local resolved
    resolved="$(cd "$probe" 2>/dev/null && pwd -P)" || return 1
    printf '%s%s\n' "$resolved" "${target#"$probe"}"
}

sanitized_build_dir() {
    local normalized
    normalized="$(normalize_path "$1")"
    # 规范化之后**再**做一次物理路径解析（挡符号链接）。
    local physical
    physical="$(physical_path "$normalized")" || return 1
    # 符号链接解析可能重新引入 `..`（若链接目标含 `..`），再规范化一次。
    normalize_path "$physical"
}

if ! RESOLVED_BUILD_DIR="$(sanitized_build_dir "$BUILD_DIR")"; then
    echo "Refusing to clean unresolvable build directory: $BUILD_DIR" >&2
    exit 1
fi
RESOLVED_ROOT="$(cd "$ROOT" && pwd -P)"
case "$RESOLVED_BUILD_DIR" in
    "$RESOLVED_ROOT/.local-build"/*) ;;
    *)
        echo "Refusing to clean unexpected build directory: $BUILD_DIR" >&2
        echo "  （规范化后: $RESOLVED_BUILD_DIR）" >&2
        echo "  （只允许 \$ROOT/.local-build/ 之下、且不允许 .. 穿越）" >&2
        exit 1
        ;;
esac
# 后续一步用规范化后的路径（避免 `..` 在 mkdir/rm 之间被再次解释）。
BUILD_DIR="$RESOLVED_BUILD_DIR"
DERIVED_DATA="$BUILD_DIR/DerivedData"

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

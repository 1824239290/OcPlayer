#!/usr/bin/env bash
# 拉取 Erika 预编译内核，并合成 Vendor/Erika.xcframework（macOS + iOS 设备 + iOS 模拟器）
#
#   用法: Scripts/fetch-erika.sh [latest|tag]
#         Scripts/fetch-erika.sh --resolve-version [latest|tag]
#   环境: ERIKA_MACOS_ARCH=arm64|universal|x64   (默认 arm64，Apple Silicon 自用够了)
#
# 产物不入库：Vendor/ 已在 .gitignore 中。
set -euo pipefail

MACOS_ARCH="${ERIKA_MACOS_ARCH:-arm64}"
# 内核来源仓库。默认上游；内核改动未合并前可设 ERIKA_REPO 指向 fork
# （如 ERIKA_REPO=1824239290/Erika），配合对应 tag 使用。
REPO="${ERIKA_REPO:-AimesSoft/Erika}"

usage() {
  echo "用法: Scripts/fetch-erika.sh [latest|tag]" >&2
  echo "      Scripts/fetch-erika.sh --resolve-version [latest|tag]" >&2
}

REQUESTED_VERSION="latest"
RESOLVE_ONLY=false
case "$#" in
  0) ;;
  1)
    if [[ "$1" == "--resolve-version" ]]; then
      RESOLVE_ONLY=true
    else
      REQUESTED_VERSION="$1"
    fi
    ;;
  2)
    if [[ "$1" != "--resolve-version" ]]; then
      usage
      exit 2
    fi
    RESOLVE_ONLY=true
    REQUESTED_VERSION="$2"
    ;;
  *)
    usage
    exit 2
    ;;
esac

resolve_version() {
  local requested="$1"
  if [[ "$requested" != "latest" ]]; then
    printf '%s\n' "$requested"
    return
  fi

  local release_url
  release_url="$(curl --retry 3 -fsSIL -o /dev/null -w '%{url_effective}' \
    "https://github.com/$REPO/releases/latest")"
  printf '%s\n' "${release_url%/}" | awk -F/ '{print $NF}'
}

TAG="$(resolve_version "$REQUESTED_VERSION")"
if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$ ]]; then
  echo "✗ 无效的 Erika release tag: $TAG" >&2
  exit 2
fi
if [[ "$RESOLVE_ONLY" == true ]]; then
  printf '%s\n' "$TAG"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
CACHE="$VENDOR/downloads"
WORK="$VENDOR/extracted"
# binaryTarget 的 path 必须落在包目录内，所以 xcframework 放进 ErikaKit
OUT="$ROOT/Packages/ErikaKit/Vendor/Erika.xcframework"
SHIM_INCLUDE="$ROOT/Packages/ErikaKit/Sources/CErika/include"

case "$MACOS_ARCH" in
  arm64)     MAC_PKG="erika-capi-macos-arm64"; MAC_SLICE="macos-arm64" ;;
  x64)       MAC_PKG="erika-capi-macos-x64"; MAC_SLICE="macos-x86_64" ;;
  universal) MAC_PKG="erika-capi-macos-universal"; MAC_SLICE="macos-arm64_x86_64" ;;
  *) echo "ERIKA_MACOS_ARCH 只能是 arm64 / x64 / universal" >&2; exit 2 ;;
esac
IOS_PKG="erika-capi-ios"

MAC_MANIFEST="$WORK/$MAC_PKG/MANIFEST.txt"
IOS_MANIFEST="$WORK/$IOS_PKG/MANIFEST.txt"
VERSION_MARKER="$OUT/.erika-version"
# 与 tag 同名的 sha256 文件用于固定 release 资产；latest 指向未来版本时
# 无法预先入库对应哈希，因此每次使用都明确提示当前校验边界。
PINNED="$ROOT/Scripts/erika-$TAG.sha256"
if [[ ! -f "$PINNED" ]]; then
  echo "⚠ Erika $TAG 没有仓库内固定哈希；本次仅校验 HTTPS 下载与 zip 完整性" >&2
  echo "  固定方法：从 Release 资产下载 sha256，审核后存为 Scripts/erika-$TAG.sha256" >&2
fi

manifest_matches() {
  local manifest="$1"
  local package="$2"
  [[ -f "$manifest" ]] || return 1
  [[ "$(awk '$1 == "bundle:" {print $2; exit}' "$manifest")" == "$package" ]] || return 1
  [[ "$(awk '$1 == "ref:" {print $2; exit}' "$manifest")" == "$TAG" ]]
}

pinned_archives_verified() {
  [[ -f "$PINNED" ]] || return 0

  local package zip expected actual
  for package in "$MAC_PKG" "$IOS_PKG"; do
    zip="$CACHE/$package-$TAG.zip"
    [[ -f "$zip" ]] || return 1
    expected="$(awk -v pkg="$package" '$2 == pkg".zip" {print $1}' "$PINNED")"
    [[ -n "$expected" ]] || return 1
    actual="$(shasum -a 256 "$zip" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || return 1
  done
}

if [[ -d "$OUT" ]] \
  && [[ -f "$VERSION_MARKER" ]] \
  && [[ "$(<"$VERSION_MARKER")" == "$TAG" ]] \
  && [[ -f "$OUT/$MAC_SLICE/liberika_capi.a" ]] \
  && [[ -f "$OUT/ios-arm64/liberika_capi.a" ]] \
  && [[ -f "$OUT/ios-arm64_x86_64-simulator/liberika_capi-sim.a" ]] \
  && manifest_matches "$MAC_MANIFEST" "$MAC_PKG" \
  && manifest_matches "$IOS_MANIFEST" "$IOS_PKG" \
  && [[ -f "$WORK/$MAC_PKG/lib/liberika_capi.a" ]] \
  && [[ -d "$WORK/$MAC_PKG/licenses" ]] \
  && [[ -f "$WORK/$IOS_PKG/include/erika.h" ]] \
  && cmp -s "$WORK/$IOS_PKG/include/erika.h" "$SHIM_INCLUDE/erika.h" \
  && pinned_archives_verified; then
  if [[ -f "$PINNED" ]]; then
    echo "· Erika $TAG 缓存归档哈希校验通过"
  fi
  echo "✓ Erika $TAG 已就绪，无需重新下载或合成"
  exit 0
fi

# 未 xcode-select 时兜底指向 Xcode.app
if ! xcodebuild -version >/dev/null 2>&1; then
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "✗ xcodebuild 不可用。请先执行:" >&2
  echo "    sudo xcode-select -s /Applications/Xcode.app" >&2
  echo "    sudo xcodebuild -license accept" >&2
  exit 1
fi

mkdir -p "$CACHE" "$WORK"

fetch() { # $1 = 包名
  local zip="$CACHE/$1-$TAG.zip"
  local url="https://github.com/$REPO/releases/download/$TAG/$1.zip"
  if [[ -f "$zip" ]] && unzip -tqq "$zip" >/dev/null 2>&1; then
    echo "· 已缓存 $1.zip ($(du -h "$zip" | cut -f1))"
  else
    echo "↓ 下载 $1.zip …"
    curl -fL --progress-bar -C - -o "$zip" "$url"
    unzip -tqq "$zip" >/dev/null || { echo "✗ $1.zip 校验失败" >&2; exit 1; }
  fi
  if [[ -f "$PINNED" ]]; then
    local expected actual
    expected="$(awk -v pkg="$1" '$2 == pkg".zip" {print $1}' "$PINNED")"
    actual="$(shasum -a 256 "$zip" | awk '{print $1}')"
    if [[ -z "$expected" ]]; then
      echo "✗ $PINNED 中缺少 $1.zip 的期望哈希" >&2; exit 1
    fi
    [[ "$actual" == "$expected" ]] || { echo "✗ $1.zip 哈希不匹配：期望 $expected，实际 $actual" >&2; exit 1; }
    echo "· $1.zip 哈希校验通过"
  fi
  shasum -a 256 "$zip" | awk '{print $1"  '"$1"'.zip"}' >> "$VENDOR/erika-$TAG.sha256.tmp"
  rm -rf "$WORK/$1"
  # zip-slip 防护：条目路径带 .. 或绝对路径 = 解包逃逸，拒绝。
  if unzip -l "$zip" | awk '{print $NF}' | grep -qE '(^|/)\.\.(/|$)|^/'; then
    echo "✗ $1.zip 含可疑路径（zip-slip），拒绝解包" >&2; exit 1
  fi
  unzip -qq "$zip" -d "$WORK"
}

rm -f "$VENDOR/erika-$TAG.sha256.tmp"
fetch "$MAC_PKG"
fetch "$IOS_PKG"
sort -o "$VENDOR/erika-$TAG.sha256" "$VENDOR/erika-$TAG.sha256.tmp"
rm -f "$VENDOR/erika-$TAG.sha256.tmp"

MAC_LIB="$WORK/$MAC_PKG/lib/liberika_capi.a"
MAC_INC="$WORK/$MAC_PKG/include"
IOS_XC="$WORK/$IOS_PKG/lib/erika_capi.xcframework"
IOS_INC="$WORK/$IOS_PKG/include"
IOS_DEV_LIB="$(ls "$IOS_XC"/ios-arm64/*.a)"
IOS_SIM_LIB="$(ls "$IOS_XC"/ios-arm64*simulator/*.a)"

for f in "$MAC_LIB" "$MAC_INC/erika.h" "$IOS_DEV_LIB" "$IOS_SIM_LIB"; do
  [[ -e "$f" ]] || { echo "✗ 缺少 $f，release 布局可能变了" >&2; exit 1; }
done

echo "⚙ 合成 xcframework …"
mkdir -p "$(dirname "$OUT")"
rm -rf "$OUT"
xcodebuild -create-xcframework \
  -library "$MAC_LIB"     -headers "$MAC_INC" \
  -library "$IOS_DEV_LIB" -headers "$IOS_INC" \
  -library "$IOS_SIM_LIB" -headers "$IOS_INC" \
  -output "$OUT" >/dev/null
printf '%s\n' "$TAG" > "$VERSION_MARKER"

# 供 Swift 侧 import 的 C 头（随 tag 更新，diff 可见）
mkdir -p "$SHIM_INCLUDE"
cp "$IOS_INC/erika.h" "$SHIM_INCLUDE/erika.h"

echo "✓ $OUT"
/usr/libexec/PlistBuddy -c "Print :AvailableLibraries" "$OUT/Info.plist" \
  | grep -E "LibraryIdentifier|SupportedPlatform" | sed 's/^ */  /'
echo "· tag=$TAG  macOS=$MACOS_ARCH  体积 $(du -sh "$OUT" | cut -f1)"
echo "· commit $(awk '/^commit:/{print $2}' "$WORK/$IOS_PKG/MANIFEST.txt")"

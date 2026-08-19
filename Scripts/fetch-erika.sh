#!/usr/bin/env bash
# 拉取 Erika 预编译内核，并合成 Vendor/Erika.xcframework（macOS + iOS 设备 + iOS 模拟器）
#
#   用法: Scripts/fetch-erika.sh [tag]
#   环境: ERIKA_MACOS_ARCH=arm64|universal|x64   (默认 arm64，Apple Silicon 自用够了)
#
# 产物不入库：Vendor/ 已在 .gitignore 中。
set -euo pipefail

TAG="${1:-v0.1.6}"
MACOS_ARCH="${ERIKA_MACOS_ARCH:-arm64}"
REPO="AimesSoft/Erika"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
CACHE="$VENDOR/downloads"
WORK="$VENDOR/extracted"
# binaryTarget 的 path 必须落在包目录内，所以 xcframework 放进 ErikaKit
OUT="$ROOT/Packages/ErikaKit/Vendor/Erika.xcframework"
SHIM_INCLUDE="$ROOT/Packages/ErikaKit/Sources/CErika/include"

case "$MACOS_ARCH" in
  arm64)     MAC_PKG="erika-capi-macos-arm64" ;;
  x64)       MAC_PKG="erika-capi-macos-x64" ;;
  universal) MAC_PKG="erika-capi-macos-universal" ;;
  *) echo "ERIKA_MACOS_ARCH 只能是 arm64 / x64 / universal" >&2; exit 2 ;;
esac
IOS_PKG="erika-capi-ios"

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

# 期望哈希（供应链校验）：与 tag 同名的 sha256 文件需在 Scripts/ 内入库；
# 无对应文件时跳过校验（新 tag 首次拉取后可据 Vendor/erika-<tag>.sha256 固化）。
PINNED="$ROOT/Scripts/erika-$TAG.sha256"
if [[ ! -f "$PINNED" ]]; then
  echo "⚠ 未找到 ${PINNED}，跳过哈希校验（建议固化该 tag 的期望哈希）" >&2
fi

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

# 供 Swift 侧 import 的 C 头（随 tag 更新，diff 可见）
mkdir -p "$SHIM_INCLUDE"
cp "$IOS_INC/erika.h" "$SHIM_INCLUDE/erika.h"

echo "✓ $OUT"
/usr/libexec/PlistBuddy -c "Print :AvailableLibraries" "$OUT/Info.plist" \
  | grep -E "LibraryIdentifier|SupportedPlatform" | sed 's/^ */  /'
echo "· tag=$TAG  macOS=$MACOS_ARCH  体积 $(du -sh "$OUT" | cut -f1)"
echo "· commit $(awk '/^commit:/{print $2}' "$WORK/$IOS_PKG/MANIFEST.txt")"

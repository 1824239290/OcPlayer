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
# 内核来源仓库。默认上游（0.3.0 起上游更名 liberika，C ABI 仍为 erika_*）；
# 需要跟踪未合并的内核改动时可设 ERIKA_REPO 指向
# fork（如 ERIKA_REPO=1824239290/Erika），配合对应 tag 使用。
REPO="${ERIKA_REPO:-AimesSoft/liberika}"

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
#
# **默认 fail-closed**：pin 缺失即失败，而不是打条警告继续。此前是「警告 +
# 跳过哈希校验」，于是新增一个 ERIKA_VERSION 而忘记入库 pin 时，供应链校验会
# 静默退化成「HTTPS 下载 + 是个合法 zip」——没有 sha256 就等于没有钉点。
# 确实要评估一个未固定的新版本时，显式 `ERIKA_ALLOW_UNPINNED=1`。
PINNED="$ROOT/Scripts/erika-$TAG.sha256"
if [[ ! -f "$PINNED" ]]; then
  if [[ "${ERIKA_ALLOW_UNPINNED:-0}" == "1" ]]; then
    echo "⚠ Erika $TAG 没有仓库内固定哈希；ERIKA_ALLOW_UNPINNED=1 已显式放行，" >&2
    echo "  本次仅校验 HTTPS 下载与 zip 完整性。" >&2
  else
    echo "✗ Erika $TAG 缺少仓库内固定哈希，拒绝继续（供应链校验不能静默退化）。" >&2
    echo "  固定方法：从 Release 资产取 sha256，审核后存为 Scripts/erika-$TAG.sha256。" >&2
    echo "  仅评估新版本时可显式放行：ERIKA_ALLOW_UNPINNED=1 Scripts/fetch-erika.sh $TAG" >&2
    exit 3
  fi
fi

# 部分 release（如手工打包的 dolby fork）只附 macOS arm64，没有 iOS 资产。
# 优先看 pin 文件；无 pin 时探测一次 asset 是否存在。
# 不存在时保留已有 iOS 切片，并在合成/打包阶段明示。
ios_release_available() {
  local url code
  url="https://github.com/$REPO/releases/download/$TAG/$IOS_PKG.zip"
  code="$(curl --retry 2 -sSIL -o /dev/null -w '%{http_code}' -L "$url" || echo 000)"
  [[ "$code" == "200" ]]
}

IOS_AVAILABLE=true
if [[ -f "$PINNED" ]]; then
  # pin 只列 release 实际提供的包；没有 iOS 行 = macOS-only tag。
  if ! awk -v pkg="$IOS_PKG" '$2 == pkg".zip" {found=1} END{exit !found}' "$PINNED"; then
    IOS_AVAILABLE=false
  fi
elif ! ios_release_available; then
  IOS_AVAILABLE=false
fi
if [[ "$IOS_AVAILABLE" == false ]]; then
  echo "⚠ Erika $TAG 未提供 $IOS_PKG.zip（本 release 仅 macOS）。" >&2
  echo "  iOS 将复用 Vendor 现有切片；若不存在则只合成 macOS slice。" >&2
fi

manifest_matches() {
  local manifest="$1"
  local package="$2"
  [[ -f "$manifest" ]] || return 1
  [[ "$(awk '$1 == "bundle:" {print $2; exit}' "$manifest")" == "$package" ]] || return 1
  [[ "$(awk '$1 == "ref:" {print $2; exit}' "$manifest")" == "$TAG" ]]
}

# pin 文件里列出的包都要校验；缺列的包（例如 macOS-only release 的 iOS）跳过。
pinned_archives_verified() {
  [[ -f "$PINNED" ]] || return 0

  local package zip expected actual
  for package in "$MAC_PKG" "$IOS_PKG"; do
    expected="$(awk -v pkg="$package" '$2 == pkg".zip" {print $1}' "$PINNED")"
    [[ -n "$expected" ]] || continue
    zip="$CACHE/$package-$TAG.zip"
    [[ -f "$zip" ]] || return 1
    actual="$(shasum -a 256 "$zip" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || return 1
  done
}

ios_slices_ready() {
  [[ -f "$OUT/ios-arm64/liberika_capi.a" ]] \
    && [[ -f "$OUT/ios-arm64_x86_64-simulator/liberika_capi-sim.a" ]]
}

# macOS 切片是否已就绪：v0.3.0 起官方 macOS .a 要经 Catalyst 声明改写后才能合成
# xcframework，切片文件名随之变成 `liberika_capi.macos-only.a`；老 tag 仍是
# `liberika_capi.a`。两个名字都要认——只认前者会让快路径永不命中，于是每次构建都
# 重新解包 ~320 MB、重建 ~780 MB xcframework，还会刷新 erika.h 的 mtime 触发
# ErikaKit 全量重编。
mac_slice_ready() {
  [[ -f "$OUT/$MAC_SLICE/liberika_capi.a" ]] \
    || [[ -f "$OUT/$MAC_SLICE/liberika_capi.macos-only.a" ]]
}

# macOS-only tag：ready 判定不要求 iOS manifest / 切片，但 macOS 必须齐。
if [[ -d "$OUT" ]] \
  && [[ -f "$VERSION_MARKER" ]] \
  && [[ "$(<"$VERSION_MARKER")" == "$TAG" ]] \
  && mac_slice_ready \
  && ( [[ "$IOS_AVAILABLE" == false ]] || ios_slices_ready ) \
  && manifest_matches "$MAC_MANIFEST" "$MAC_PKG" \
  && ( [[ "$IOS_AVAILABLE" == false ]] || manifest_matches "$IOS_MANIFEST" "$IOS_PKG" ) \
  && [[ -f "$WORK/$MAC_PKG/lib/liberika_capi.a" ]] \
  && [[ -d "$WORK/$MAC_PKG/licenses" ]] \
  && { [[ "$IOS_AVAILABLE" == false ]] || [[ -f "$WORK/$IOS_PKG/include/erika.h" ]]; } \
  && { [[ "$IOS_AVAILABLE" == false ]] || cmp -s "$WORK/$IOS_PKG/include/erika.h" "$SHIM_INCLUDE/erika.h"; } \
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
    if [[ -z "$expected" ]]; then
      # pin 只列了 release 实际提供的包；macOS-only tag 不含 iOS 行是正常的。
      if [[ "$1" == "$IOS_PKG" && "$IOS_AVAILABLE" == false ]]; then
        echo "· 跳过 $1 的哈希校验（$TAG 未提供该资产）" >&2
      else
        echo "✗ $PINNED 中缺少 $1.zip 的期望哈希" >&2; exit 1
      fi
    else
      actual="$(shasum -a 256 "$zip" | awk '{print $1}')"
      [[ "$actual" == "$expected" ]] || { echo "✗ $1.zip 哈希不匹配：期望 ${expected}，实际 $actual" >&2; exit 1; }
      echo "· $1.zip 哈希校验通过"
    fi
  fi
  shasum -a 256 "$zip" | awk '{print $1"  '"$1"'.zip"}' >> "$VENDOR/erika-$TAG.sha256.tmp"
  rm -rf "$WORK/$1"
  # zip-slip 防护：条目路径带 .. 或绝对路径 = 解包逃逸，拒绝。
  # 用 zipinfo -1 只取条目名：unzip -l 的 "Archive: /abs/path.zip" 头行会被
  # awk 取成以 / 开头的字段，令 ^/ 规则对任何绝对路径归档必然误报。
  if zipinfo -1 "$zip" | grep -qE '(^|/)\.\.(/|$)|^/'; then
    echo "✗ $1.zip 含可疑路径（zip-slip），拒绝解包" >&2; exit 1
  fi
  unzip -qq "$zip" -d "$WORK"
}

rm -f "$VENDOR/erika-$TAG.sha256.tmp"
fetch "$MAC_PKG"
if [[ "$IOS_AVAILABLE" == true ]]; then
  fetch "$IOS_PKG"
else
  echo "· 跳过 $IOS_PKG 下载（$TAG 仅提供 macOS 产物）"
fi
sort -o "$VENDOR/erika-$TAG.sha256" "$VENDOR/erika-$TAG.sha256.tmp"
rm -f "$VENDOR/erika-$TAG.sha256.tmp"

MAC_LIB="$WORK/$MAC_PKG/lib/liberika_capi.a"
MAC_INC="$WORK/$MAC_PKG/include"

# v0.3.0 起官方 macos zip 的 liberika_capi.a 里，285 个 compiler-rt 对象
#（Rust compiler_builtins 产物）同时携带 macOS 与 MACCATALYST 两条
# LC_BUILD_VERSION，xcodebuild -create-xcframework 因此把整个 .a 判成「多平台」
# 拒收。此处把对象里的 Catalyst 平台声明原地改写成等长（24B）的 LC_UUID：
# 结构合法、不挪数据偏移、对象本体与全部符号保留（实测 ranlib 后成员数与符号
# 总数与原档分毫不差；改 LC_SOURCE_VERSION 会被 ranlib 整个丢成员，勿用）。
# 老 tag 无此问题（检出 0 处时不落盘、原样沿用）。
strip_catalyst_build_version() {
  local src="$1" dst="$2"
  python3 - "$src" "$dst" <<'PY'
import struct, sys

src, dst = sys.argv[1], sys.argv[2]
LC_BUILD_VERSION, LC_UUID = 0x32, 0x1B
PLATFORM_MACCATALYST = 6

data = open(src, "rb").read()
if data[:8] != b"!<arch>\n":
    # universal 包是「fat 容器里套 ar 归档」，本修复只处理 thin 归档（默认
    # arm64；x64 也是 thin）。给一条能直接照做的信息，别掉进 xcodebuild 的
    # 「unable to determine the platform / multiple platforms」。
    if data[:4] in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
                    b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"):
        sys.exit("macOS 内核包是 universal(fat) 归档，本脚本的 Catalyst 声明修复"
                 "暂不支持；请用 ERIKA_MACOS_ARCH=arm64（或 x64）重跑")
    sys.exit("不是 ar 归档")
out = [data[:8]]
pos = 8
patched = 0
while pos + 60 <= len(data):
    hdr = data[pos:pos + 60]
    name = hdr[0:16].decode("ascii", "replace").rstrip()
    size = int(hdr[48:58])
    body = bytearray(data[pos + 60:pos + 60 + size])
    pos = pos + 60 + size + (size & 1)
    if name.startswith("__.SYMDEF"):
        continue  # 符号表交给 ranlib 重建
    if name.startswith("#1/"):
        namelen = int(name[3:])
        real = bytes(body[:namelen]).rstrip(b"\x00")
        body = body[namelen:]
    else:
        real = name.encode("ascii", "replace")
    if len(body) >= 32 and struct.unpack_from("<I", body, 0)[0] == 0xFEEDFACF:
        sizeofcmds = struct.unpack_from("<I", body, 20)[0]
        off, end = 32, 32 + sizeofcmds
        while off + 8 <= end:
            cmd, cmdsize = struct.unpack_from("<II", body, off)
            if cmdsize < 8 or off + cmdsize > end:
                break
            if cmd == LC_BUILD_VERSION and cmdsize == 24 and \
               struct.unpack_from("<I", body, off + 8)[0] == PLATFORM_MACCATALYST:
                struct.pack_into("<II", body, off, LC_UUID, 24)
                struct.pack_into("<QQ", body, off + 8, 0, 0)
                patched += 1
            off += cmdsize
    payload = real + bytes(body)
    out.append(b"#1/" + str(len(real)).encode().ljust(13)
               + b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6)
               + b"100644".ljust(8) + str(len(payload)).encode().ljust(10)
               + b"`\n" + payload + (b"\n" if len(payload) & 1 else b""))
if patched == 0:
    sys.exit(2)  # 无 Catalyst 声明，保持原样（不落盘）
open(dst, "wb").write(b"".join(out))
print(f"· 改写 Catalyst 平台声明 {patched} 处（→LC_UUID）", file=sys.stderr)
PY
}

# python 退出 0 = 确有改写且已落盘；退出 2 = 无需改写（保持原档）。任何其他
# 退出码都让整个 fetch 失败，绝不拿半成品合成。
#
# ⚠️ 不能用 `if strip_catalyst_build_version …; then`：函数放在 if 条件里时
# `set -e` 不生效，python 的报错退出会被静默吞掉，然后拿**未改写**的 .a 去合成，
# 最终由 xcodebuild 抛出那句晦涩的「多平台」错误——正是本修复要消灭的症状。
PATCHED_MAC_LIB="$WORK/$MAC_PKG/lib/liberika_capi.macos-only.a"
if ! command -v python3 >/dev/null; then
  echo "✗ 缺少 python3：v0.3.0 的 macOS .a 需要先改写 Catalyst 平台声明才能合成 xcframework" >&2
  exit 1
fi
patch_rc=0
strip_catalyst_build_version "$MAC_LIB" "$PATCHED_MAC_LIB" || patch_rc=$?
case "$patch_rc" in
  0)
    # `-D` 不写 mtime/uid/gid，同一个 zip 反复解包得到逐字节相同的产物。
    ranlib -D "$PATCHED_MAC_LIB"
    echo "· macOS .a 含 Catalyst 平台声明，已改写为纯 macOS"
    MAC_LIB="$PATCHED_MAC_LIB"
    ;;
  2)
    : # 检出 0 处（≤ v0.2.1 的老 tag），原样沿用
    ;;
  *)
    echo "✗ Catalyst 平台声明改写失败（退出码 $patch_rc），不拿半成品合成 xcframework" >&2
    exit 1
    ;;
esac

# 先保留旧 iOS 切片（macOS-only release 时复用），再重建 xcframework。
SAVED_IOS=""
if [[ -d "$OUT" ]] && ios_slices_ready; then
  SAVED_IOS="$(mktemp -d)/ios"
  mkdir -p "$SAVED_IOS"
  cp -R "$OUT/ios-arm64" "$SAVED_IOS/"
  cp -R "$OUT/ios-arm64_x86_64-simulator" "$SAVED_IOS/"
fi

create_args=(
  -library "$MAC_LIB" -headers "$MAC_INC"
)
INC_FOR_HEADER="$MAC_INC"

if [[ "$IOS_AVAILABLE" == true ]]; then
  IOS_XC="$WORK/$IOS_PKG/lib/erika_capi.xcframework"
  IOS_INC="$WORK/$IOS_PKG/include"
  IOS_DEV_LIB="$(ls "$IOS_XC"/ios-arm64/*.a)"
  IOS_SIM_LIB="$(ls "$IOS_XC"/ios-arm64*simulator/*.a)"

  for f in "$MAC_LIB" "$MAC_INC/erika.h" "$IOS_DEV_LIB" "$IOS_SIM_LIB"; do
    [[ -e "$f" ]] || { echo "✗ 缺少 ${f}，release 布局可能变了" >&2; exit 1; }
  done
  create_args+=(-library "$IOS_DEV_LIB" -headers "$IOS_INC")
  create_args+=(-library "$IOS_SIM_LIB" -headers "$IOS_INC")
  INC_FOR_HEADER="$IOS_INC"
elif [[ -n "$SAVED_IOS" ]]; then
  echo "⚠ 复用已有 iOS 切片（仍为旧版本，未随 $TAG 更新）"
  for f in "$MAC_LIB" "$MAC_INC/erika.h"; do
    [[ -e "$f" ]] || { echo "✗ 缺少 ${f}，release 布局可能变了" >&2; exit 1; }
  done
  # 必须让 Info.plist 登记 iOS 库，否则 SwiftPM binaryTarget 看不见这些切片。
  IOS_DEV_LIB="$(ls "$SAVED_IOS"/ios-arm64/*.a)"
  IOS_SIM_LIB="$(ls "$SAVED_IOS"/ios-arm64_x86_64-simulator/*.a 2>/dev/null \
    || ls "$SAVED_IOS"/ios-arm64*simulator/*.a)"
  # 头文件跟旧 iOS 二进制走，避免「新头 + 旧库」ABI 错位。
  IOS_INC="$SAVED_IOS/ios-arm64/Headers"
  [[ -f "$IOS_INC/erika.h" ]] || IOS_INC="$MAC_INC"
  create_args+=(-library "$IOS_DEV_LIB" -headers "$IOS_INC")
  create_args+=(-library "$IOS_SIM_LIB" -headers "$IOS_INC")
else
  for f in "$MAC_LIB" "$MAC_INC/erika.h"; do
    [[ -e "$f" ]] || { echo "✗ 缺少 ${f}，release 布局可能变了" >&2; exit 1; }
  done
  echo "⚠ $TAG 无 iOS 资产且本地无旧切片：xcframework 将仅含 macOS（iOS 打包会失败）" >&2
fi

echo "⚙ 合成 xcframework …"
mkdir -p "$(dirname "$OUT")"
rm -rf "$OUT"
xcodebuild -create-xcframework "${create_args[@]}" -output "$OUT" >/dev/null
printf '%s\n' "$TAG" > "$VERSION_MARKER"

# 供 Swift 侧 import 的 C 头（随 tag 更新，diff 可见）
mkdir -p "$SHIM_INCLUDE"
cp "$INC_FOR_HEADER/erika.h" "$SHIM_INCLUDE/erika.h"

# 内核版本常量（入库、diff 可见）：设置页内核行读它。每次 fetch 重写，
# 与 vendored 二进制保持同源——拉了新内核没提交这个文件，diff 会立刻暴露。
ERIKA_VERSION_SWIFT="$ROOT/Packages/ErikaKit/Sources/ErikaKit/ErikaVersion.swift"
cat > "$ERIKA_VERSION_SWIFT" <<EOF
// Auto-generated by Scripts/fetch-erika.sh — do not edit by hand.
// 每次拉取内核时随 vendored 二进制一起重写，保证版本串不与本地内核漂移。

/// 当前 vendored 的 Erika 内核 release tag（如 "\$TAG"）。
public enum ErikaVersion {
    public static let tag = "$TAG"
}
EOF

echo "✓ $OUT"
/usr/libexec/PlistBuddy -c "Print :AvailableLibraries" "$OUT/Info.plist" \
  | grep -E "LibraryIdentifier|SupportedPlatform" | sed 's/^ */  /'
echo "· tag=$TAG  macOS=$MACOS_ARCH  体积 $(du -sh "$OUT" | cut -f1)"
echo "· commit $(awk '/^commit:/{print $2}' "$WORK/$MAC_PKG/MANIFEST.txt")"

#!/usr/bin/env bash
#
# verify-ambience.sh —— 「氛围背景图是否每个界面都有」的**验收台**。
#
# 它做三件事，缺一不可：
#   1. **前置闸门**：确认这次运行有图可用（诊断日志里出现「氛围池已装载」）。
#      没有图时所有页面都该是纯色底——那种情况下跑出来的结果毫无意义，脚本会
#      直接判 INVALID 并退出，而不是把「没有图」误报成「页面没挂背景层」。
#   2. **逐页截图**：按覆盖契约（本文件 PAGES 表，唯一事实源）启动到目标页、
#      等稳定、截图。
#   3. **客观判定**：判据在 `Scripts/ambience-probe.swift`（色度中位数：氛围图是
#      彩色照片，纯色页面底是中性色），输出 image / flat / content 三态。
#
# 覆盖契约见 `Docs/AMBIENCE.md`；`--list` 打印同一张表。
#
# 用法：
#   Scripts/verify-ambience.sh --list                     # 打印覆盖契约（不跑）
#   Scripts/verify-ambience.sh --dry-run                  # 校验工具链与环境（不跑 App）
#   Scripts/verify-ambience.sh                            # 验 macOS（默认）
#   Scripts/verify-ambience.sh --platform ios --device "iPhone 17 Pro"
#   Scripts/verify-ambience.sh --pages ios.search,ios.settings
#   Scripts/verify-ambience.sh --from-image ~/shots/      # 复核已截好的图（不启动 App）
#
# 退出码：0 全部达标 / 1 有页面缺背景 / 2 前置无效（无图可用）/ 3 环境与用法 / 4 有页面判不了
#
# ⚠️ 两个前置条件不满足时脚本会明确报出来，不会给假结论：
#   * macOS：终端（或本 App）需要「屏幕录制」权限，否则截图里没有窗口内容。
#   * iOS：模拟器容器里要有一个**已登录**的会话（脚本靠诊断日志判断）。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUNDLE_ID="dev.jumusu.OcPlayer"
APP_NAME="OcPlayer"

PLATFORM="mac"
OUT=""
SETTLE=2
ROUTE_TIMEOUT=25
THRESHOLD=6
DRY_RUN=0
STRICT=0
LIST=0
KEEP_RUNNING=0
PAGE_FILTER=""
APP_MAC="$ROOT/.local-build/current/DerivedData/Build/Products/Debug/OcPlayer.app"
APP_IOS="$ROOT/.local-build/current/DerivedData/Build/Products/Debug-iphonesimulator/OcPlayer.app"
APP_OVERRIDE=""
FROM_IMAGE=""
DEVICE="iPhone 17 Pro"
REGIONS="left,right"

# ---------------------------------------------------------------------------
# 覆盖契约（**唯一事实源**）
#
# 字段：id | platform | gate | launch | expect | note
#   gate = section  ：现在就能跑（OCPLAYER_START_SECTION）
#   gate = route    ：需要 Debug 通道 OCPLAYER_START_ROUTE（尚未实现，见 Docs/AMBIENCE.md
#                     的 Phase 4）；脚本会自动检测二进制里有没有这个开关，没有就报 SKIP
#   gate = excluded ：设计上不做（脚本只登记、不判）
#   expect = required ：必须判为 image，否则本次验收失败
# ---------------------------------------------------------------------------
PAGES=$(cat <<'EOF'
mac.home|mac|section|home|required|首页：轮播本身就是氛围图来源
mac.moviepilot|mac|section|moviepilot|required|MoviePilot 分区
mac.bangumi|mac|section|bangumi|required|Bangumi 分区
mac.settings|mac|section|settings|required|设置 hub
mac.library|mac|route|library|required|媒体库网格页（push 进来，靠整窗层）
mac.settings.playback|mac|route|settings.playback|required|设置子页（push 进来）
mac.bangumi.calendar|mac|route|bangumi.calendar|required|每日放送（push 进来）
mac.detail|mac|route|detail|required|详情页：本条目 backdrop 覆盖整窗层
mac.search|mac|excluded|-|excluded|macOS 的搜索在首页工具栏里，没有独立页面
ios.home|ios|section|home|required|首页 Tab（轮播垫在栈内）
ios.moviepilot|ios|section|moviepilot|required|MoviePilot Tab
ios.bangumi|ios|section|bangumi|required|Bangumi Tab
ios.settings|ios|section|settings|required|设置 Tab
ios.search|ios|route|search|required|搜索 Tab 根页（当前缺；LaunchOptions 也还不认 search）
ios.library|ios|route|library|required|媒体库网格页（push）
ios.bangumi.profile|ios|route|bangumi.profile|required|Bangumi 个人页（push）
ios.bangumi.calendar|ios|route|bangumi.calendar|required|每日放送（push）
ios.settings.playback|ios|route|settings.playback|required|设置子页（push，10 个子页之一）
ios.settings.servers|ios|route|settings.jellyfin.servers|required|管理服务器（呈现式叶子页）
ios.settings.licenses|ios|route|settings.about.licenses|required|开源许可证（呈现式叶子页）
ios.onboarding|ios|excluded|-|excluded|未登录的引导页：会话尚未建立，没有图可用
ios.player|ios|excluded|-|excluded|播放器：画面本身即内容
ios.sheets|ios|excluded|-|excluded|sheet / 弹窗 / 菜单：系统材质浮动层，底下垫图看不见
EOF
)

usage() {
    cat <<'EOF'
用法：Scripts/verify-ambience.sh [选项]

  --list                 打印覆盖契约（页面 × 平台 × 门控 × 期望），不跑 App
  --dry-run              只校验工具链与环境（判据自检 + App 路径 + 设备），不跑 App
  --platform mac|ios     验哪个平台（默认 mac）
  --pages a,b            只跑指定 id（逗号分隔；配合 --list 查 id）
  --app PATH             指定 .app（macOS 与 iOS 模拟器各一个默认路径）
  --from-image DIR       不启动 App：直接判 DIR 下已截好的 <页面id>.png/.jpg
                         （用于复核别人给的截图，或在不方便开窗时验证判定链路）
  --device NAME|UDID     iOS 模拟器（默认 "iPhone 17 Pro"）
  --out DIR              产物目录（默认 /tmp/ocplayer-ambience-<时间戳>）
  --settle SECONDS       目标页到达后的额外等待秒数，默认 2（等淡入）
                         （"到达"由日志判定：分区页等氛围池装载，深链页等落地标记）
  --route-timeout SEC    深链落地的等待上限，默认 25
  --threshold N          判据的色度阈值，默认 6（0…255）
  --regions a,b,c        采样区域与顺序，默认 left,right（内容左右留白；top 被
                         状态栏/灵动岛占据、bottom 被 Tab 栏占据，只适合专项排查）
  --strict               把 SKIP（门控未实现）也算失败
  --keep-running         跑完不关 App

退出码：0 达标 / 1 缺背景 / 2 前置无效（无图可用）/ 3 环境与用法 / 4 判不了
EOF
}

die() { printf '错误：%s\n' "$*" >&2; exit 3; }
info() { printf '%s\n' "$*"; }

while (($#)); do
    case "$1" in
        --list) LIST=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --strict) STRICT=1 ;;
        --keep-running) KEEP_RUNNING=1 ;;
        --platform) PLATFORM="${2:?--platform 需要取值}"; shift ;;
        --pages) PAGE_FILTER="${2:?--pages 需要取值}"; shift ;;
        --app) APP_OVERRIDE="${2:?--app 需要取值}"; shift ;;
        --from-image) FROM_IMAGE="${2:?--from-image 需要取值}"; shift ;;
        --device) DEVICE="${2:?--device 需要取值}"; shift ;;
        --out) OUT="${2:?--out 需要取值}"; shift ;;
        --settle) SETTLE="${2:?--settle 需要取值}"; shift ;;
        --route-timeout) ROUTE_TIMEOUT="${2:?--route-timeout 需要取值}"; shift ;;
        --threshold) THRESHOLD="${2:?--threshold 需要取值}"; shift ;;
        --regions) REGIONS="${2:?--regions 需要取值}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "未知选项：$1（--help 看用法）" ;;
    esac
    shift
done

[[ "$PLATFORM" == "mac" || "$PLATFORM" == "ios" ]] || die "--platform 只支持 mac / ios"
[[ "$SETTLE" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--settle 要一个秒数"
[[ "$THRESHOLD" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--threshold 要一个数"
if [[ -n "$FROM_IMAGE" ]]; then
    [[ -d "$FROM_IMAGE" ]] || die "--from-image 不是目录：$FROM_IMAGE"
fi
if [[ -n "$APP_OVERRIDE" ]]; then
    APP_MAC="$APP_OVERRIDE"
    APP_IOS="$APP_OVERRIDE"
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
[[ -n "$OUT" ]] || OUT="/tmp/ocplayer-ambience-$STAMP"
mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# 工具链
# ---------------------------------------------------------------------------

PROBE=()

prepare_probe() {
    local binary="$OUT/ambience-probe"
    if command -v swiftc >/dev/null 2>&1; then
        # 编译一次、复用：判据以脚本源码为唯一事实源，产物只是加速。
        if swiftc -O "$ROOT/Scripts/ambience-probe.swift" -o "$binary" >"$OUT/probe-build.log" 2>&1; then
            PROBE=("$binary")
            return 0
        fi
        # 单文件顶层代码在 `swiftc` 下要求 main.swift 之类的入口；失败就退回直译执行。
        cp "$ROOT/Scripts/ambience-probe.swift" "$OUT/probe-main.swift"
        if swiftc -O "$OUT/probe-main.swift" -o "$binary" >>"$OUT/probe-build.log" 2>&1; then
            PROBE=("$binary")
            return 0
        fi
    fi
    if command -v swift >/dev/null 2>&1; then
        PROBE=(swift "$ROOT/Scripts/ambience-probe.swift")
        return 0
    fi
    die "找不到 swiftc / swift（需要 Xcode 命令行工具）"
}

# 判据自身先自检：判据坏了和「页面真没背景」在报告里长得一样，必须先排除前者。
probe_selftest() {
    "${PROBE[@]}" --selftest --threshold "$THRESHOLD" >"$OUT/probe-selftest.txt" 2>&1 || {
        cat "$OUT/probe-selftest.txt" >&2
        die "判据自检未通过（详见 $OUT/probe-selftest.txt）"
    }
    info "判据自检：$(tail -1 "$OUT/probe-selftest.txt")"
}

# 探测 App 里有没有某个 Debug 通道开关。
#
# **必须搜整个 .app 包**，不能只搜 `Contents/MacOS/OcPlayer`：Xcode 的 Debug 配置
# 默认开 "Debug Dylib"（`ENABLE_DEBUG_DYLIB`），App 代码全部落在
# `OcPlayer.debug.dylib` 里，主可执行文件只是个壳（实测主二进制里连
# `OCPLAYER_SELFTEST` 的字面量都找不到）。只搜主二进制会永远判"通道未实现"，
# 于是 route 门控的页面全部静默 SKIP——一个自我实现的假阴性。
binary_supports() {
    local app="$1" token="$2"
    [[ -d "$app" ]] || return 1
    LC_ALL=C grep -a -r -q -- "$token" "$app" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 前置闸门：有图可用吗？
# ---------------------------------------------------------------------------

mac_log_dir() { printf '%s' "$HOME/Library/Logs/OcPlayer"; }

ios_log_dir() {
    local container
    container="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
    [[ -n "$container" ]] || return 1
    printf '%s' "$container/Library/Logs/OcPlayer"
}

# 最近一份会话日志里是否有「氛围池已装载」，且写入时间不早于本次启动。
pool_loaded_since() {
    local dir="$1" since="$2"
    [[ -d "$dir" ]] || return 1
    local newest
    newest="$(ls -t "$dir"/diagnostics-*.jsonl 2>/dev/null | head -1 || true)"
    [[ -n "$newest" ]] || return 1
    grep -aq '氛围池已装载' "$newest" || return 1
    local mtime
    mtime="$(stat -f %m "$newest")"
    [[ "$mtime" -ge "$since" ]]
}

wait_for_pool() {
    local dir="$1" since="$2" deadline=$(( SECONDS + 20 ))
    while (( SECONDS < deadline )); do
        if pool_loaded_since "$dir" "$since"; then return 0; fi
        sleep 1
    done
    return 1
}

# 等**本次启动**的日志里出现某个标记。`since` 是启动时刻（epoch 秒），只认不早于
# 它的那份会话文件——否则会读到上一轮的日志、把"上次落地过"当成"这次落地了"。
#
# 为什么需要它：原先每页固定 `sleep $SETTLE` 就截图，而 App 冷启要恢复会话 +
# 探测服务器地址（每个候选 2s 超时）+ 两次两段式 push（各 0.45s），慢轮次下超过
# 固定等待——实测截到过**首页启动骨架屏**，而那时判定仍照跑（一张骨架屏照样能
# 判出"有背景"，但它根本不是被测的那一页）。等待条件必须挂在"目标真的到了"上。
wait_for_marker() {
    local dir="$1" since="$2" marker="$3" timeout="$4"
    local deadline=$(( SECONDS + timeout ))
    while (( SECONDS < deadline )); do
        local newest
        newest="$(ls -t "$dir"/diagnostics-*.jsonl 2>/dev/null | head -1 || true)"
        if [[ -n "$newest" ]] && [[ "$(stat -f %m "$newest")" -ge "$since" ]] \
            && grep -aq -- "$marker" "$newest"; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

# ---------------------------------------------------------------------------
# 启动 / 截图 / 收尾
# ---------------------------------------------------------------------------

UDID=""
APP_BINARY=""
LAUNCH_EPOCH=0

# 解析模拟器：`--device` 给名字时按**全名精确匹配**，给 UDID 时直接用。
#
# 这行解析踩过两个坑，都记在这里免得重犯：
#   ① **`.*` 贪婪**：模拟器列表每行是 "名称 (UDID) (状态) "，用 `\(.*\)$` 剥状态会把
#      UDID 那组一起吃掉（实测把 UDID 解析成了字符串 "Booted"）；
#   ② **BSD sed 的 `$` 不容忍行尾空格**：设备行末尾有个空格，` (.*)$` 直接匹配不上、
#      整个 sed 静默返回空。
# 所以改成「按 UUID 的**形状**切分」——不跟括号与空格较劲，名字拿到 shell 里比较：
# 名字里带括号的设备（`iPad Pro 13-inch (M5)`）也因此不会被误切。
resolve_ios_device() {
    if [[ "$DEVICE" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
        UDID="$DEVICE"
        return 0
    fi
    local uuid_pattern='[0-9A-Fa-f]\{8\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{12\}'
    UDID="$(xcrun simctl list devices available \
        | sed -n "s/^[[:space:]]*\(.*\) (\($uuid_pattern\)) ([^)]*)[[:space:]]*\$/\1|\2/p" \
        | while IFS='|' read -r name id; do
              [[ "$name" == "$DEVICE" ]] && { printf '%s' "$id"; break; }
          done)"
    if [[ -z "$UDID" ]]; then
        printf '找不到模拟器：%s\n可用机型（--device 要写全名，含括号里的代次）：\n' "$DEVICE" >&2
        xcrun simctl list devices available \
            | sed -n '/[0-9A-Fa-f]\{8\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{12\}/p' >&2
        exit 3
    fi
}

# iOS 侧的前置：启动模拟器（无头，不需要 Simulator.app）+ 装最新构建。
prepare_ios() {
    xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 \
        || die "模拟器启动失败：$UDID"
    xcrun simctl install "$UDID" "$APP_IOS" >/dev/null 2>&1 \
        || die "安装 App 失败：$APP_IOS"
}

# gate 决定走哪条启动通道：section = 现成的分区直落；route = 深链（Phase 4 落地后可用）。
launch_page() {
    local gate="$1" launch="$2"
    LAUNCH_EPOCH="$(date +%s)"
    if [[ "$PLATFORM" == "mac" ]]; then
        # 直接跑 .app 内的二进制：环境变量能带上（`open -a` 要配合 --env 且不可控），
        # 且进程是脚本的子进程，收尾一行 kill 就够。参数一个都不传——LaunchOptions
        # 的注释写明传文件路径会让窗口建不起来。
        if [[ "$gate" == "route" ]]; then
            OCPLAYER_START_ROUTE="$launch" "$APP_BINARY" >"$OUT/app-stdout.log" 2>&1 &
        else
            OCPLAYER_START_SECTION="$launch" "$APP_BINARY" >"$OUT/app-stdout.log" 2>&1 &
        fi
        APP_PID=$!
    else
        if [[ "$gate" == "route" ]]; then
            SIMCTL_CHILD_OCPLAYER_START_ROUTE="$launch" \
                xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" \
                >"$OUT/app-stdout.log" 2>&1
        else
            SIMCTL_CHILD_OCPLAYER_START_SECTION="$launch" \
                xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" \
                >"$OUT/app-stdout.log" 2>&1
        fi
    fi
}

stop_page() {
    if (( KEEP_RUNNING )); then return 0; fi
    if [[ "$PLATFORM" == "mac" ]]; then
        [[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null || true
        wait "$APP_PID" 2>/dev/null || true
        APP_PID=""
    else
        xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
    fi
}

# 截图。macOS 走「只截窗口」；iOS 走模拟器自己的截图口。
# 输出全局 CAPTURE_ARGS（额外传给判据的参数，如 --crop-rect）。
#
# **找不到窗口就报错，不退回整屏截图**：整屏里是桌面壁纸（妥妥的彩色），
# 判据会把它当成「有背景」——那是这套验收里最坏的一种假通过。窗口 rect 已知时
# 才允许退回「整屏截图 + 按 rect 裁剪」，因为那依旧只测窗口那块像素。
CAPTURE_ARGS=()
capture_page() {
    local out="$1"
    CAPTURE_ARGS=()
    if [[ "$PLATFORM" == "mac" ]]; then
        local window_id="" bounds="" info_out
        if info_out="$("${PROBE[@]}" --window "$APP_NAME" 2>/dev/null)"; then
            window_id="$(printf '%s\n' "$info_out" | awk -F= '/^window_id=/{print $2}')"
            bounds="$(printf '%s\n' "$info_out" | awk -F= '/^bounds=/{print $2}')"
        fi
        if [[ -z "$bounds" ]]; then
            info "  ✗ 找不到 ${APP_NAME} 的可见窗口（App 没起来 / 窗口被最小化？）"
            return 1
        fi
        if [[ -n "$window_id" ]] && screencapture -x -o -l "$window_id" "$out" 2>/dev/null \
            && [[ -s "$out" ]]; then
            return 0
        fi
        info "  （窗口直截不可用，退回整屏截图 + 按窗口 rect 裁剪）"
        screencapture -x "$out" 2>/dev/null || die "screencapture 失败（检查屏幕录制权限）"
        CAPTURE_ARGS=(--crop-rect "$bounds")
    else
        xcrun simctl io "$UDID" screenshot "$out" >/dev/null 2>&1 \
            || die "simctl 截图失败（模拟器 $UDID 是否已启动？）"
    fi
    [[ -s "$out" ]] || die "截图是空文件：$out"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

print_contract() {
    # 一行一页而不是对齐多列：中文是双宽字符，printf 的 %-Ns 按字符数补位，
    # 表格必然对不齐；一行一页既稳定又能写上说明。
    printf '覆盖契约（与 Docs/AMBIENCE.md 同源）\n\n'
    local current=""
    while IFS='|' read -r id platform gate launch expect note; do
        [[ -z "${id:-}" ]] && continue
        if [[ "$platform" != "$current" ]]; then
            current="$platform"
            printf '── %s ──\n' "$current"
        fi
        printf '  %-24s gate=%-8s launch=%-22s expect=%-8s %s\n' \
            "$id" "$gate" "$launch" "$expect" "$note"
    done <<<"$PAGES"
    printf '\n说明：gate=route 的页面走 Debug 深链 OCPLAYER_START_ROUTE（Phase 4 落地前自动 SKIP）。\n'
}

matched_pages() {
    while IFS='|' read -r id platform gate launch expect note; do
        [[ -z "${id:-}" ]] && continue
        [[ "$platform" == "$PLATFORM" ]] || continue
        if [[ -n "$PAGE_FILTER" ]]; then
            [[ ",$PAGE_FILTER," == *",$id,"* ]] || continue
        fi
        printf '%s|%s|%s|%s|%s|%s\n' "$id" "$platform" "$gate" "$launch" "$expect" "$note"
    done <<<"$PAGES"
}

main() {
    if (( LIST )); then
        print_contract
        return 0
    fi

    prepare_probe
    probe_selftest
    info "产物目录：$OUT"

    local app_path binary
    local supports_route=0
    if [[ -n "$FROM_IMAGE" ]]; then
        info "复核模式：只吃 $FROM_IMAGE 下已截好的 <页面id>.png/.jpg —— 不启动 App、不过前置闸门。"
    else
        if [[ "$PLATFORM" == "mac" ]]; then
            app_path="$APP_MAC"
            binary="$app_path/Contents/MacOS/$APP_NAME"
        else
            app_path="$APP_IOS"
            binary="$app_path/$APP_NAME"
            resolve_ios_device || exit 3
            info "模拟器：$DEVICE ($UDID)"
        fi
        local app_missing=0
        if [[ ! -d "$app_path" ]]; then
            if (( DRY_RUN )); then
                app_missing=1
                info "App：**不存在**（${app_path}）—— dry-run 继续，实跑前先构建："
            else
                die "找不到 App：$app_path
      先构建（本仓规矩：先清理再构建，一次只留一份）：
        Scripts/clean.sh
        SKIP_ERIKA_FETCH=1 Scripts/build-macos.sh debug
      iOS 模拟器：
        Scripts/clean.sh
        xcodebuild -project OcPlayer.xcodeproj -scheme OcPlayer-iOS -configuration Debug \\
          -destination 'platform=iOS Simulator,name=$DEVICE' \\
          -derivedDataPath .local-build/current/DerivedData build"
            fi
        fi
        APP_BINARY="$binary"
        (( app_missing )) || info "App：$app_path"

        if binary_supports "$app_path" "OCPLAYER_START_ROUTE"; then
            supports_route=1
            info "深链通道：OCPLAYER_START_ROUTE 可用（route 门控的页面会真跑）"
        else
            info "深链通道：未实现（route 门控的页面本次 SKIP；见 Docs/AMBIENCE.md Phase 4）"
        fi
    fi  # [[ -n "$FROM_IMAGE" ]]：复核模式下上面整块都不跑

    local rows=()
    while IFS= read -r row; do rows+=("$row"); done < <(matched_pages)
    (( ${#rows[@]} > 0 )) || die "没有匹配的页面（--platform $PLATFORM --pages ${PAGE_FILTER}）"

    # 前置闸门只对「本次能跑的第一个 section 页」做一次：图都没有的话，
    # 后面每个页面都会判 flat，那是没有信息量的噪声。
    local first_launch=""
    for row in "${rows[@]}"; do
        IFS='|' read -r _ _ gate launch _ _ <<<"$row"
        [[ "$gate" == "section" ]] && { first_launch="$launch"; break; }
    done

    if (( DRY_RUN )); then
        for row in "${rows[@]}"; do
            IFS='|' read -r id _ gate launch expect _ <<<"$row"
            local action="跑（gate=$gate launch=${launch}）"
            [[ -z "$FROM_IMAGE" && "$gate" == "route" && $supports_route -eq 0 ]] \
                && action="SKIP（深链未实现）"
            [[ "$gate" == "excluded" ]] && action="登记（设计上不做）"
            printf '  %-24s %s\n' "$id" "$action"
        done
        info "dry-run：工具链与环境校验通过，未启动 App（截图与判定留到实跑）。"
        return 0
    fi

    if [[ -z "$FROM_IMAGE" ]]; then
        if [[ "$PLATFORM" == "mac" ]]; then
            local running
            running="$(pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null | head -1 || true)"
            if [[ -n "$running" ]]; then
                die "已经有一个 ${APP_NAME} 在运行（pid ${running}）。
      验收要靠「按窗口名找窗口」，同时开两个实例会拿到错的那个窗口——先退出它再跑。"
            fi
            # 锁屏 / 屏保会让 screencapture 只给黑图（整屏截图全黑、窗口直截直接失败），
            # 于是每一页都被判成"缺背景"——一个看起来像真结论的假结论。宁可拒绝跑。
            if [[ "$("${PROBE[@]}" --screen-state 2>/dev/null)" == "locked=1" ]]; then
                die "屏幕已锁定 / 屏保中。
      锁屏后 screencapture 拿不到窗口内容（整屏截图是纯黑），继续跑会把每一页都判成
      「缺背景」——假结论比不跑更坏。请解锁屏幕（并让显示器保持点亮）后重跑。
      iOS 模拟器不受影响：--platform ios 不需要解锁。"
            fi
        fi
        [[ "$PLATFORM" == "ios" ]] && prepare_ios

        if [[ -n "$first_launch" ]]; then
            info "前置闸门：启动 $first_launch 并等待氛围池装载…"
            # 不固定 sleep：等"池子已装载"这个事实（`wait_for_pool` 内含 20s 上限）。
            launch_page section "$first_launch"
            local log_dir
            if [[ "$PLATFORM" == "mac" ]]; then log_dir="$(mac_log_dir)"; else log_dir="$(ios_log_dir || true)"; fi
            if [[ -z "${log_dir:-}" ]] || ! wait_for_pool "$log_dir" "$LAUNCH_EPOCH"; then
                stop_page
                cat >&2 <<EOF
前置闸门未通过：这次运行**没有图可用**，逐页判定没有意义，故判 INVALID。

  日志目录：${log_dir:-（取不到）}
  期望日志：diagnostics-*.jsonl 里出现「氛围池已装载 count=… source=…」

常见原因：
  * 未连接媒体服务器（App 停在引导页）——先在目标平台登录一次，会话在容器 / 钥匙串里持久化；
  * 服务器上没有任何带 backdrop 的条目（氛围池取材为全库随机 backdrop）；
  * 启动瞬间网络未就绪（冷启动抢跑）——重跑一次通常就好。
EOF
                return 2
            fi
            info "前置闸门：通过（氛围池已装载）"
            stop_page
            # 第一页会在下面的循环里重新启动一次：闸门那次只是为了确认有图。
        fi
    fi  # [[ -z "$FROM_IMAGE" ]]：复核模式没有前置闸门（判的是别人给的截图）

    local report="$OUT/report.txt"
    : >"$report"
    {
        echo "OcPlayer 氛围背景验收"
        echo "时间：$(date '+%Y-%m-%d %H:%M:%S')"
        echo "平台：$PLATFORM    设备：${UDID:-本机}"
        echo "App：$app_path"
        echo "代码：$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')" \
             "（工作区改动 $(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ') 处）"
        echo "判据：色度中位数 ≥ ${THRESHOLD}；区域顺序 $REGIONS"
        echo
        printf '%-26s %-10s %-9s %s\n' "页面" "判定" "区域" "指标"
        echo "--------------------------------------------------------------------------------"
    } >>"$report"

    local failures=0 skipped=0 inconclusive=0 total=0
    local ids=() verdicts=() regions_out=() metrics=()
    for row in "${rows[@]}"; do
        IFS='|' read -r id _ gate launch expect note <<<"$row"
        total=$(( total + 1 ))

        if [[ "$expect" == "excluded" ]]; then
            printf '%-26s %-10s %s\n' "$id" "跳过" "$note" | tee -a "$report"
            skipped=$(( skipped + 1 ))
            ids+=("$id"); verdicts+=("excluded"); regions_out+=("-"); metrics+=("$note")
            continue
        fi
        if [[ -z "$FROM_IMAGE" && "$gate" == "route" && $supports_route -eq 0 ]]; then
            printf '%-26s %-10s %s\n' "$id" "SKIP" "需要 OCPLAYER_START_ROUTE（未实现）" | tee -a "$report"
            skipped=$(( skipped + 1 ))
            (( STRICT )) && failures=$(( failures + 1 ))
            ids+=("$id"); verdicts+=("skip"); regions_out+=("-"); metrics+=("深链未实现")
            continue
        fi

        local shot="$OUT/$id.png"
        if [[ -n "$FROM_IMAGE" ]]; then
            # 复核模式：不启动 App，直接判给好的截图（同一套判据、同一份报告格式）。
            # 它同时是这条链路的自测入口——不方便开窗时也能验证「判定 → 汇总 → 退出码」。
            local source_image="" ext
            for ext in png jpg jpeg; do
                if [[ -f "$FROM_IMAGE/$id.$ext" ]]; then source_image="$FROM_IMAGE/$id.$ext"; break; fi
            done
            if [[ -z "$source_image" ]]; then
                printf '%-26s %-10s %s\n' "$id" "未提供截图" "$FROM_IMAGE/$id.png" | tee -a "$report"
                skipped=$(( skipped + 1 ))
                (( STRICT )) && failures=$(( failures + 1 ))
                ids+=("$id"); verdicts+=("no-image"); regions_out+=("-"); metrics+=("-")
                continue
            fi
            cp "$source_image" "$shot"
            info "▶ ${id}（复核 ${source_image}）"
        else
            local env_launch="$launch"
            echo "  （启动通道：gate=$gate launch=${env_launch}）" >>"$report"
            info "▶ ${id}（gate=$gate launch=${env_launch}）"
            if ! launch_page "$gate" "$env_launch"; then
                printf '%-26s %-10s %s\n' "$id" "启动失败" "见 app-stdout.log" | tee -a "$report"
                failures=$(( failures + 1 ))
                ids+=("$id"); verdicts+=("launch-failed"); regions_out+=("-"); metrics+=("-")
                continue
            fi

            # **等目标页真的到了再截图**（不靠固定 sleep，见 `wait_for_marker`）。
            # 两个条件都要满足：
            #   ① 本次会话的日志已就绪（否则可能截到启动骨架屏，甚至上一轮的残留画面）；
            #   ② 深链页额外等 `深链落地 target=<launch>`。
            # 深链超时**记为失败、不判定**：那时截到的多半是首页，而首页有背景——
            # 照判会得到"有背景"的假通过，正是这套验收最该避免的错误。
            local page_log_dir
            if [[ "$PLATFORM" == "mac" ]]; then page_log_dir="$(mac_log_dir)"; else page_log_dir="$(ios_log_dir || true)"; fi
            if [[ -z "${page_log_dir:-}" ]] || ! wait_for_marker "$page_log_dir" "$LAUNCH_EPOCH" "氛围池已装载" 20; then
                stop_page
                printf '%-26s %-10s %s\n' "$id" "启动超时" "会话未就绪（氛围池未装载）" | tee -a "$report"
                failures=$(( failures + 1 ))
                ids+=("$id"); verdicts+=("boot-timeout"); regions_out+=("-"); metrics+=("-")
                continue
            fi
            if [[ "$gate" == "route" ]]; then
                if ! wait_for_marker "$page_log_dir" "$LAUNCH_EPOCH" "深链落地 target=${env_launch}" "$ROUTE_TIMEOUT"; then
                    stop_page
                    printf '%-26s %-10s %s\n' "$id" "深链未落地" "等 ${ROUTE_TIMEOUT}s 未见 target=${env_launch}" | tee -a "$report"
                    failures=$(( failures + 1 ))
                    ids+=("$id"); verdicts+=("route-timeout"); regions_out+=("-"); metrics+=("-")
                    continue
                fi
            fi
            sleep "$SETTLE"
            if ! capture_page "$shot"; then
                stop_page
                printf '%-26s %-10s %s\n' "$id" "截图失败" "没拿到窗口内容，见上文" | tee -a "$report"
                failures=$(( failures + 1 ))
                ids+=("$id"); verdicts+=("capture-failed"); regions_out+=("-"); metrics+=("-")
                continue
            fi
            # 截图可用性抽检：整张纯黑 = 这次没拿到窗口内容（锁屏中途 / 显示器休眠 /
            # 权限被撤）。这时判定没有意义，必须报环境错误——否则会以"每页缺背景"
            # 的面目出现在报告里（实测踩过：一轮 9 页全判 flat，其实屏幕锁了）。
            if "${PROBE[@]}" --blank-check "$shot" >/dev/null 2>&1; then :; else
                stop_page
                die "截图全黑（疑似屏幕锁定 / 显示器休眠 / 屏幕录制权限被撤）：$shot
      App 本身未必有问题——这类环境故障要与「页面缺背景」分开处理。"
            fi
            stop_page
        fi

        # 探针命令用数组拼：空数组在 bash 3.2 + set -u 下展开会报 unbound variable，
        # 拼好后只展开一次，绕开 macOS 自带 bash 的这个坑。
        local -a probe_cmd=("${PROBE[@]}" "$shot" --regions "$REGIONS" --threshold "$THRESHOLD")
        if (( ${#CAPTURE_ARGS[@]} )); then
            probe_cmd+=("${CAPTURE_ARGS[@]}")
        fi
        local probe_out probe_code
        set +e
        probe_out="$("${probe_cmd[@]}" 2>&1)"
        probe_code=$?
        set -e
        printf '%s\n' "$probe_out" >"$OUT/$id.probe.txt"

        local verdict region chroma votes
        case $probe_code in
            0) verdict="有背景" ;;
            1) verdict="缺背景" ;;
            2) verdict="判不了" ;;
            *) verdict="探针错误" ;;
        esac
        region="$(printf '%s\n' "$probe_out" | awk -F= '/^region=/{print $2; exit}')"
        chroma="$(printf '%s\n' "$probe_out" | awk -F= '/^median_chroma=/{print $2; exit}')"
        votes="$(printf '%s\n' "$probe_out" | awk -F= '/^votes=/{print $2; exit}')"
        [[ -n "$region" ]] || region="-"
        [[ -n "$chroma" ]] || chroma="-"
        [[ -n "$votes" ]] || votes="-"

        printf '%-26s %-10s %-9s 色度中位数=%-6s 投票=%s\n' \
            "$id" "$verdict" "$region" "$chroma" "$votes" | tee -a "$report"
        ids+=("$id"); verdicts+=("$verdict"); regions_out+=("$region")
        metrics+=("chroma=$chroma votes=$votes")

        case $probe_code in
            0) ;;
            1) failures=$(( failures + 1 )) ;;
            2) inconclusive=$(( inconclusive + 1 )) ;;
            *) failures=$(( failures + 1 )) ;;
        esac
    done

    {
        echo
        echo "汇总：$total 页（跳过 ${skipped}，缺背景 ${failures}，判不了 ${inconclusive}）"
        if (( failures > 0 )); then
            echo "结论：**不合格** —— 上面判「缺背景」的页面需要补氛围层。"
            echo "      判据：色度中位数 < ${THRESHOLD} 的区域多于彩色区域。"
            echo "      若**每一页**都判缺背景，先怀疑截图没拿到窗口内容（macOS 屏幕录制权限："
            echo "      系统设置 → 隐私与安全性 → 屏幕录制），再怀疑氛围池没过前置闸门。"
        elif (( inconclusive > 0 )); then
            echo "结论：**需人工复核** —— 有页面判不了（采样区域全被文字/控件占据），"
            echo "      换 --regions 再跑（例如左边界被卡片占满时试 right,top,bottom）。"
        else
            echo "结论：合格 —— 本次覆盖到的 required 页面全部有背景图。"
        fi
        echo "截图：$OUT/<页面 id>.png（每页另有 <id>.probe.txt 是原始指标）"
    } >>"$report"

    # 机器可读的逐页汇总：改前改后各留一份就能直接 diff（人看的报告在 report.txt）。
    local summary="$OUT/summary.tsv"
    {
        printf 'id\tverdict\tregion\tmetrics\n'
        local index
        for index in "${!ids[@]}"; do
            printf '%s\t%s\t%s\t%s\n' \
                "${ids[$index]}" "${verdicts[$index]}" "${regions_out[$index]}" "${metrics[$index]}"
        done
    } >"$summary"

    # 报告尾巴单独打一段（带分隔标题），否则它和逐页输出连在一起会像是重复打印。
    printf '\n── 报告结尾（%s）──\n' "$report"
    tail -n 6 "$report"
    (( failures > 0 )) && return 1
    (( inconclusive > 0 )) && return 4
    return 0
}

main

import AppDesignKit
import CoreModel
import JellyfinKit
import MetadataKit
import Observation
import SwiftUI

#if os(macOS)
import AppKit
#endif

// MARK: - 详情页「整页翻页」
//
// 效果取自 animeflip 那版 macOS 详情页:详情页自己分成两页。
//
// ## 跨平台边界（2026-11-04 起）
//
// 这个文件**不再是 macOS 独有**：视觉层（`DetailPageArt` / `DetailPageArtScreen` /
// 选集带 / `DetailPagePager` 的状态机与动画编排）是纯 SwiftUI，iOS 也能编译。
//
// 只有两处是 macOS 专属 API，各自收在 `#if os(macOS)` 内：
//   * `DetailPagePager` 的滚轮监视器（`NSEvent` / `NSWindow`）—— iOS 的翻页输入
//     走触控手势；第二页内部使用原生滚动；
//   * `DetailPageWindowAnchor`（`NSViewRepresentable`）—— 只为把所在窗口报给监视器。
//
// **谁在哪个平台上真正用这套版式，由 `DetailLayoutStyle` 决定，不由这里的 `#if` 决定。**
// 别把「能不能编译」和「会不会被用」混成一件事。
//
//   * **第一页** —— 详情页的头图页:整幅剧照打底(左半高斯模糊、右半清晰),
//     LOGO / 标签 / 简介 / 播放钮浮在左侧,底部一条选集带。
//   * **第二页** —— 详情页的正文滚动区:简介、选集轨道、Bangumi、MoviePilot、
//     媒体信息、演员、类似推荐(即原有的 `ScrollView` 内容)。
//
// 两页之间不是滚动,而是**整屏翻页**:第一页在时滚一格就翻到第二页,第二页滚到顶
// 再往上滚一格翻回第一页。翻页本身是三段式编排(基准 1s,受 `reduceMotion` 缩放):
//
//   翻下去:0~0.45s 第一页前景渐隐 → 0.05~0.60s 模糊块向右扩张(左糊右清 → 整幅全糊)
//           → 0.60~1.00s 正文渐显
//   翻回来:0~0.45s 正文渐隐 → 0.20~0.75s 模糊块退回 → 0.60~1.00s 第一页前景渐显
//
// **背景层全程不淡出**(与 demo 一致):头图与模糊块一直画在最底下,翻过去之后
// 它就是第二页的固定背景。早先多了一步「头图淡出、沉回整窗氛围层」,结果 30pt 模糊
// 淡出时露出下面 20pt 的氛围层、中间还透出清晰图,肉眼就是「闪一下」——
// 那一步已经删掉。
//
// 与 demo 的差异(都是为了落进本 App 既有设计语言,不是简化):
//   1. **外观自适应**:demo 恒暗;本页第一页跟随 `.detail` 档氛围底——浅色压白雾配
//      深字、深色压黑纱配白字,所以 `EpisodeSelectCard` 等现成组件不用改色。
//   2. **正文页不另垫背景**:它本来就是「整窗氛围层 + 透明页面」,头图淡出正好沉回
//      同一张模糊剧照,翻页前后背景连续。
//   3. **只在有剧照时启用**:没有 backdrop 的条目仍走原来的横幅布局,不做翻页
//      (翻页的价值全在那张头图上,空底翻页只会翻出一片纯色)。
//   4. **滚轮裁决按设备方向归一**:demo 只读原始 delta,关掉「自然滚动」时方向会反。

/// 详情页翻页状态机:两页的可见性、模糊块扩张、正文滚动位置与滚轮裁决都在这里。
@MainActor
@Observable
final class DetailPagePager {
    enum Page {
        /// 第一页:头图 + LOGO/简介/播放钮 + 选集带
        case art
        /// 第二页:正文滚动区
        case body
    }

    private(set) var page: Page = .art
    private(set) var isTransitioning = false
    /// 第一页前景(LOGO / 简介 / 播放钮 / 选集带)可见性
    var artForegroundVisible = true
    /// 第二页正文可见性
    var bodyVisible = false
    /// 模糊块扩张开关:false = 覆盖左侧 68%;true = 扩张到越出右缘(整幅全糊)
    var blurExpanded = false
    /// 正文滚动偏移；iOS 只记录顶部 0 / 离开顶部 3，macOS 记录实际值。
    var bodyOffsetY: CGFloat = 0
    /// 系统「降低动态效果」:整套编排压成硬切
    var reduceMotion = false

    @ObservationIgnored private var bodyPullBeganAtTop = false
    @ObservationIgnored private var bodyPullCrossedThreshold = false

    @ObservationIgnored private var pendingDelta: CGFloat = 0
    @ObservationIgnored private var upAccum: CGFloat = 0
    /// 上一拍第二页是否已在顶部（用来识别「刚滚到顶」这一次跃迁）
    @ObservationIgnored private var wasBodyAtTop = true
    /// 「刚滚到顶」的凭据：消费掉之后，**再滚一次**才会翻回第一页。
    /// 进第二页时置起（等于「一进来就在顶上」，第一下上滚只当确认）。
    @ObservationIgnored private var topEntryToken = true
    /// 本次手势是否已经「有权翻回」。
    ///
    /// 触控板必须按**手势**判定，不能按事件：一路滚到顶的那串事件里 `.began`
    /// 发生在非顶部，此后全是 `.changed`；只有新一次手势的 `.began` 才落在顶部。
    /// 传统鼠标（非精确增量）没有 phase，每一格本身就是独立动作，永远算「新的一次」。
    /// 判断统一收在 `beginsNewScrollGesture(_:)`。
    @ObservationIgnored private var flipArmed = false
    /// 上一发参与裁决的滚轮事件时刻（单调时钟，秒）。
    ///
    /// 用来识别「新的一轮滚动动作」，见 `beginsNewScrollGesture(_:)`。
    @ObservationIgnored private var lastWheelEventAt: TimeInterval = 0
    @ObservationIgnored private var transitioningUntil = Date.distantPast
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    #if os(macOS)
    /// 滚轮监视器句柄与所在窗口——**只有 macOS 有**（iOS 走系统滚动，无本地事件监视器）。
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private weak var hostWindow: NSWindow?
    #endif

    /// 第一页触发翻页的累计增量(pt)
    private let flipThreshold: CGFloat = 5
    /// 第二页顶部触发翻回的累计上滚量(pt)
    private let flipUpThreshold: CGFloat = 18

    /// 第二页是否停在顶部。留 2pt 容差:吸附后 offset 会是 -0.0001 这类浮点毛刺。
    var isBodyAtTop: Bool { bodyOffsetY <= 2 }

    /// 判定「这一发滚轮是否开启了一轮新的滚动动作」（有权翻回第一页）。
    ///
    /// ## 要同时伺候三种输入
    ///
    /// 原判据是 `phase.contains(.began) || !hasPreciseScrollingDeltas`：前者认触控板的
    /// 手势相位，后者认「非精确增量 = 传统鼠标，每格独立」。其中**后半条必须保留** ——
    /// 传统鼠标两格之间的间隔能短到几十毫秒，光靠时间闸会把连着滚的两格并成一串。
    ///
    /// 而这条判据在装了 **Mos**（鼠标滚轮平滑）时又不够用：实测（Mos 4.2.1）
    /// Mos 把一格滚轮摊成一串 `hasPreciseScrollingDeltas == true`、`phase == []`、
    /// `momentumPhase == []` 的连续事件（`dy` 由 1 递增到峰值再衰减回 0）。
    /// 它既不像传统鼠标（precise 为真），也不像标准触控板手势（没有 phase）——
    /// 两个分支同时为假，`flipArmed` 永远 false，第二页再也翻不回第一页。
    ///
    /// ## 现在怎么判（三条互补，不重叠）
    ///
    /// - **非精确增量** → 新一轮。语义与改动前完全一致，不受 Mos 影响。
    /// - **有 phase** → `.began` 是新一轮，其余是同手势中段（触控板，与改动前一致）。
    /// - **精确增量 + 无 phase**（Mos 之类）→ 按时间间隔：与上一发隔 ≥ `wheelGestureGap` 才算新一轮。
    #if os(macOS)
    private func beginsNewScrollGesture(_ event: NSEvent) -> Bool {
        Self.isNewScrollGesture(phaseBegan: event.phase.contains(.began),
                                phaseIsEmpty: event.phase.isEmpty,
                                precise: event.hasPreciseScrollingDeltas,
                                timestamp: event.timestamp,
                                lastTimestamp: lastWheelEventAt)
    }
    #endif

    /// `beginsNewScrollGesture` 的纯值内核（可单测）。
    ///
    /// - Parameters:
    ///   - phaseBegan: 事件 phase 含 `.began`。
    ///   - phaseIsEmpty: 事件 phase 为空。
    ///   - precise: `hasPreciseScrollingDeltas`；false = 传统鼠标的一格一跳。
    ///   - timestamp: 本事件的单调时钟时刻（`NSEvent.timestamp`）。
    ///   - lastTimestamp: 上一发事件的时刻；0 表示还没收过事件。
    /// `nonisolated`：纯值、无状态，测试与非隔离上下文都能直接调。
    nonisolated static func isNewScrollGesture(phaseBegan: Bool,
                                   phaseIsEmpty: Bool,
                                   precise: Bool,
                                   timestamp: TimeInterval,
                                   lastTimestamp: TimeInterval) -> Bool {
        // ① 非精确增量 = 传统鼠标的一格：每格都是独立动作。
        //    不能受时间闸约束——连滚两格的间隔可能只有几十毫秒。
        if !precise { return true }
        // ② 有相位：以触控板的手势为准。
        if phaseBegan { return true }
        if !phaseIsEmpty { return false }
        // ③ 精确增量 + 无相位（Mos 之类的平滑流）：按时间间隔区分一轮。
        guard lastTimestamp > 0 else { return true }  // 第一发总是新一轮
        return timestamp - lastTimestamp >= wheelGestureGap
    }

    /// 「新一轮滚动动作」的最小间隔（秒）。60Hz 的平滑流约 16ms 一发，取 120ms
    /// 留足余量：既不会把一串拆散，也不会把用户明确的两下动作并成一串。
    nonisolated private static let wheelGestureGap: TimeInterval = 0.12

    /// 时序缩放:降低动态效果时压成 ~25ms,等价于硬切。
    private var speed: Double { reduceMotion ? 40 : 1 }

    private func duration(_ seconds: Double) -> Double { seconds / speed }

    private func anim(_ seconds: Double, delay: Double = 0) -> Animation {
        .easeInOut(duration: duration(seconds)).delay(duration(delay))
    }

    // MARK: - 翻页

    func flipToBody() {
        guard page == .art, !isTransitioning else { return }
        beginTransition()
        page = .body
        // 进第二页时等于「刚到位」：第一下上滚不该立刻把它顶回去
        wasBodyAtTop = true
        topEntryToken = true
        flipArmed = false
        upAccum = 0
        transitioningUntil = Date().addingTimeInterval(duration(1.0) + 0.05)
        withAnimation(anim(0.45)) { artForegroundVisible = false }
        withAnimation(anim(0.55, delay: 0.05)) { blurExpanded = true }
        withAnimation(anim(0.40, delay: 0.60)) { bodyVisible = true }
    }

    func flipToArt() {
        guard page == .body, !isTransitioning else { return }
        beginTransition()
        page = .art
        upAccum = 0
        topEntryToken = true
        flipArmed = false
        transitioningUntil = Date().addingTimeInterval(duration(1.0) + 0.05)
        withAnimation(anim(0.45)) { bodyVisible = false }
        withAnimation(anim(0.55, delay: 0.20)) { blurExpanded = false }
        withAnimation(anim(0.40, delay: 0.60)) { artForegroundVisible = true }
    }

    /// 换条目时复位(详情页会按 `.id(item.id)` 重建,这里兜一次 hot reload 场景)。
    func reset() {
        transitionTask?.cancel()
        transitionTask = nil
        isTransitioning = false
        page = .art
        artForegroundVisible = true
        bodyVisible = false
        blurExpanded = false
        bodyOffsetY = 0
        bodyPullBeganAtTop = false
        bodyPullCrossedThreshold = false
        pendingDelta = 0
        upAccum = 0
        transitioningUntil = .distantPast
    }

    private func beginTransition() {
        isTransitioning = true
        transitionTask?.cancel()
        let interval = duration(1.0) + 0.05
        transitionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) }
            catch { return }
            self?.isTransitioning = false
        }
    }

    // MARK: - 触控翻页

    /// 正文只发布三个区域，避免把每帧偏移传播到整个详情页。
    enum BodyScrollRegion: Equatable {
        case scrolled, top, pulled
    }

    nonisolated static func bodyScrollRegion(offsetY: CGFloat) -> BodyScrollRegion {
        guard offsetY.isFinite else { return .scrolled }
        if offsetY <= -40 { return .pulled }
        return offsetY <= 2 ? .top : .scrolled
    }

    func beginBodyScroll(atTop: Bool) {
        bodyPullBeganAtTop = page == .body && !isTransitioning && atTop
        bodyPullCrossedThreshold = false
    }

    func updateBodyScroll(region: BodyScrollRegion) {
        bodyOffsetY = region == .scrolled ? 3 : 0
        if bodyPullBeganAtTop, region == .pulled {
            bodyPullCrossedThreshold = true
        }
        #if OCPLAYER_SELFTEST
        if ProcessInfo.processInfo.environment["OCPLAYER_DETAIL_SCROLL_TRACE"] == "1" {
            print("DETAIL_SCROLL region=\(region) armed=\(bodyPullBeganAtTop) pulled=\(bodyPullCrossedThreshold)")
        }
        #endif
    }

    func handleBodyScrollPhase(from oldPhase: ScrollPhase, to phase: ScrollPhase,
                               offsetY: CGFloat) {
        let region = Self.bodyScrollRegion(offsetY: offsetY)
        // 某些触摸序列直接进入 interacting，不能依赖 tracking 必定单独回调。
        if phase == .tracking ||
            (phase == .interacting && oldPhase != .tracking && oldPhase != .interacting) {
            beginBodyScroll(atTop: region != .scrolled)
        }
        // 阶段回调也带有最新位置；几何区域回调尚未送达时仍可捕获下拉阈值。
        updateBodyScroll(region: region)
        #if OCPLAYER_SELFTEST
        if ProcessInfo.processInfo.environment["OCPLAYER_DETAIL_SCROLL_TRACE"] == "1" {
            print("DETAIL_SCROLL phase=\(oldPhase)->\(phase) offset=\(offsetY) armed=\(bodyPullBeganAtTop) pulled=\(bodyPullCrossedThreshold)")
        }
        #endif
        if (oldPhase == .interacting || oldPhase == .tracking),
           (phase == .decelerating || phase == .idle) {
            endBodyScroll()
        }
    }

    func endBodyScroll() {
        let shouldReturn = bodyPullBeganAtTop && bodyPullCrossedThreshold
        bodyPullBeganAtTop = false
        bodyPullCrossedThreshold = false
        if shouldReturn { flipToArt() }
    }

    /// 只消费明确的竖向滑动。正文必须在手指落下时就在顶部：
    /// 一路滚回顶部的同一次拖动，以及横向选集带，都不能翻页。
    nonisolated static func swipeTarget(page: Page, translation: CGSize,
                                       startedAtTop: Bool) -> Page? {
        let dx = translation.width
        let dy = translation.height
        guard dx.isFinite, dy.isFinite, abs(dy) >= 60,
              abs(dy) > abs(dx) * 1.5 else { return nil }
        switch page {
        case .art: return dy < 0 ? .body : nil
        case .body: return dy > 0 && startedAtTop ? .art : nil
        }
    }

    func handleSwipe(translation: CGSize, startedAtTop: Bool) {
        guard !isTransitioning else { return }
        switch Self.swipeTarget(page: page, translation: translation,
                                startedAtTop: startedAtTop) {
        case .body: flipToBody()
        case .art: flipToArt()
        case nil: break
        }
    }

    #if os(macOS)
    // MARK: - 滚轮

    /// 详情页所在窗口(由 `DetailPageWindowAnchor` 回报)。监视器只裁决这个窗口的事件,
    /// 弹出面板 / sheet / 另一窗口的滚轮一律放行。
    func attach(window: NSWindow?) {
        hostWindow = window
    }

    /// 安装滚轮监视器。`active` = 本页当前是栈顶:被别的页盖住时必须摘掉,
    /// 否则会把上层页面的滚轮全吞掉(macOS 26 上被盖页不发 onDisappear)。
    func updateMonitor(active: Bool) {
        if active {
            installMonitor()
        } else {
            removeMonitor()
        }
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            // 事件监视器的 block 由 AppKit 在主线程直接回调,但这个 block 本身不是
            // `@Sendable`;`assumeIsolated` 的 body 必须是 @Sendable,而 `NSEvent`
            // 不是 Sendable —— 用一个显式的「主线程独占」盒子把事件过桥,
            // 只让 Bool 穿出隔离域(给 AppKit 类型硬加 Sendable 更糟)。
            let consumed = MainActor.assumeIsolated {
                self.handleWheel(MainThreadEventBox(event).event)
            }
            return consumed ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// 滚轮裁决:返回 true = 已消化(丢弃);false = 放行给原生滚动。
    private func handleWheel(_ event: NSEvent) -> Bool {
        // 只裁决本窗口:sheet / 弹出面板 / 别的窗口持有滚轮时那是它们的事。
        // `event.window` 为 nil 时不能判成「别的窗口」——滚动事件经常不带 window
        // (触摸板惯性段、以及合成事件),那样会把本页的滚轮全放行出去,翻页永远不触发。
        if let hostWindow, let eventWindow = event.window, eventWindow !== hostWindow {
            return false
        }
        // 翻页动画期间全吞:两页叠在一起,这时候滚谁都没意义
        if Date() < transitioningUntil { return true }
        // 横向增量放行:选集带要能横向滚
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { return false }

        // 统一成「往下翻 = 正」。
        //
        // `scrollingDeltaY` 的符号取决于系统「自然滚动」设置:自然滚动开着时
        // (设备方向被反转,`isDirectionInvertedFromDevice == true`)手指上推 → 内容下滚
        // → delta 为负;关掉之后同一个手势 delta 变正。按这个标志归一一次,
        // 两种设置下都读得通(demo 只按原始 delta 写,关掉自然滚动时方向会反)。
        let raw = event.isDirectionInvertedFromDevice
            ? -event.scrollingDeltaY
            : event.scrollingDeltaY
        // 鼠标滚轮是非精确增量(每格 ±1~3 行),按行高折算成 pt,
        // 否则一格滚轮永远攒不到翻页阈值;触控板本来就是 pt,原样用。
        let advance = event.hasPreciseScrollingDeltas ? raw : raw * 10

        // 「这一发是否开启了一轮新的滚动动作」必须在更新时刻**之前**算（顺序易错，
        // 见 `DetailPageWheelGestureTests`）。横向滚轮在上面第 245 行就已放行返回，
        // 到不了这里；惯性与过渡期事件则会刷新时刻 —— 这是想要的：它们同样属于
        // 用户这一串动作的延续，不该被当成「停了很久之后的新一轮」。
        let startsNewGesture = beginsNewScrollGesture(event)
        lastWheelEventAt = event.timestamp

        switch page {
        case .art:
            if abs(advance) > 0.01 {
                pendingDelta += advance
                if abs(pendingDelta) >= flipThreshold {
                    let down = pendingDelta > 0
                    pendingDelta = 0
                    if down { flipToBody() }
                }
            }
            if event.phase == .ended { pendingDelta = 0 }
            // 第一页在时竖向滚轮全部消化:第一页下面没有可滚内容,
            // 放行只会把被它盖住的正文滚动区偷偷滚走
            return true

        case .body:
            // 惯性事件(phase 已空、momentumPhase 非空)一律不算数:翻回第一页必须
            // 是用户的主动滚轮/手指,否则正文滚到顶的余量会把页面顶回去。
            let isMomentum = event.phase.isEmpty && !event.momentumPhase.isEmpty
            let atTop = isBodyAtTop

            // 手势收尾：下一次上滚要重新「武装」
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                flipArmed = false
            }

            // 「不在顶 → 在顶」这一跃迁：这一下只当「到位」，不翻页。
            // 少了它，一路滚到顶的那串事件会把页面直接顶回第一页，
            // 用户想停在顶端看一眼当前集都做不到。
            if atTop, !wasBodyAtTop {
                wasBodyAtTop = true
                topEntryToken = false
                flipArmed = false
                upAccum = 0
                return true
            }
            wasBodyAtTop = atTop

            guard atTop else {
                topEntryToken = false
                flipArmed = false
                upAccum = 0
                return false // 不在顶：放行给原生 ScrollView
            }

            guard advance < -0.5, !isMomentum else {
                if advance > 0.5 {
                    // 往下滚一点就说明不是「刚到顶」了
                    topEntryToken = false
                    flipArmed = false
                }
                upAccum = 0
                return false
            }

            // 进第二页后还没滚过的那一下上滚：只当「确认在顶上」
            if topEntryToken {
                topEntryToken = false
                upAccum = 0
                return true
            }

            // 新一轮滚动动作 = 有权翻回第一页。
            //
            // 原判据 `phase.contains(.began) || !hasPreciseScrollingDeltas` 在装了 Mos
            // 的机器上两个分支同时为假（Mos 发的是一串 precise + 无 phase 的事件），
            // 导致 `flipArmed` 永远 false、第二页翻不回第一页。改成按时间间隔识别，
            // 判据细节见 `beginsNewScrollGesture(_:)`。
            if startsNewGesture {
                flipArmed = true
            }

            guard flipArmed else {
                upAccum = 0
                return true // 同一串手势里继续往上蹭：吞掉，但要等下一次主动滚动
            }

            upAccum += -advance
            if upAccum >= flipUpThreshold {
                upAccum = 0
                flipArmed = false
                flipToArt()
                return true
            }
            return true // 顶部吞掉继续累计
        }
    }
    #endif
}

#if os(macOS)
/// 主线程独占的事件盒子。`NSEvent` 不是 `Sendable`,而 `MainActor.assumeIsolated`
/// 的 body 必须是;事件监视器的 block 又保证只在主线程回调,所以这里显式声明
/// 「不安全地视为 Sendable」,只用来把参数带进隔离域,不跨线程传递。
private final class MainThreadEventBox: @unchecked Sendable {
    let event: NSEvent
    init(_ event: NSEvent) { self.event = event }
}
#endif

// MARK: - 头图:清晰剧照 + 可扩张的模糊块 + 外观自适应压雾
struct DetailPageArt: View {
    let viewport: CGSize
    /// 清晰层取图(大图,1600 宽)
    let target: (url: URL?, authHeader: String?)
    /// 模糊层取图。**必须与整窗氛围层同参**(800 宽 URL + 512 解码,见
    /// `DetailAmbienceImage`),否则模糊层命中不了 `prewarmAmbience` 预热过的那份缓存,
    /// 进页首帧就会露出下面那张糊底、等自己加载完再补 —— 也就是「全模糊闪一下、
    /// 再猛地变清晰」那串闪烁的来源。
    let blurTarget: (url: URL?, authHeader: String?)
    /// 模糊块是否已扩张到整幅(翻页中)
    var expanded = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            sharpImage
            blurBlock
            scrim
        }
        .frame(width: viewport.width, height: viewport.height)
        .clipped()
    }

    /// 清晰层:右半是这张图的主体,取比模糊层高两档的解码尺寸。
    private var sharpImage: some View {
        Group {
            if target.url != nil {
                RemoteImage(
                    url: target.url,
                    authHeader: target.authHeader,
                    maxPixelSize: 1920,
                    preserveCurrentImageOnReload: true
                )
                .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Metrics.placeholderFill)
            }
        }
        .frame(width: viewport.width, height: viewport.height)
        .clipped()
    }

    /// 模糊层:同一张图的模糊版 + 压雾,右缘自带渐变软边;`expanded` 时软边
    /// 向右扫出屏幕 → 「左糊右清」变「整幅全糊」。
    ///
    /// ## 扫动的是**遮罩**,不是图像
    ///
    /// 早先的实现是把图像套进一个宽度会变的 `frame` 里再 `clipped`:块宽从 0.68W
    /// 涨到 1.55W,而图像只有视口那么宽,于是「块比图宽」的那段时间右边是空的;
    /// 软边扫过去之后,左侧又跟着块宽被重新裁一遍 —— 肉眼就是「模糊跑一半、左边
    /// 没那么糊了」。
    ///
    /// 现在图像**始终铺满视口、尺寸不变**(模糊也只算一次),只有 mask 里那条
    /// 「实心段 + 软边」的遮罩条在变宽。实心段的左边界恒在 0,所以已经糊住的
    /// 区域一直是完整的 30pt 模糊,不会再变浅。
    private var blurBlock: some View {
        Group {
            if blurTarget.url != nil {
                RemoteImage(
                    url: blurTarget.url,
                    authHeader: blurTarget.authHeader,
                    maxPixelSize: DetailAmbienceImage.decodePixels,
                    preserveCurrentImageOnReload: true
                )
                .aspectRatio(contentMode: .fill)
                .frame(width: viewport.width, height: viewport.height)
                // 模糊会让边缘发虚透光,放大一点把虚边推出可视区
                .scaleEffect(1.15)
                .blur(radius: 30)
                .saturation(1.02)
                // 模糊结果整块栅格化一次:遮罩动画只动裁剪,不必逐帧重算 30pt 高斯
                .drawingGroup()
                .clipped()
                .overlay(veilTint)
            } else {
                Rectangle().fill(Metrics.placeholderFill)
            }
        }
        // 图像与遮罩都按视口定容:块本身永远不参与 ZStack 的居中计算
        .frame(width: viewport.width, height: viewport.height)
        .mask(alignment: .leading) { maskStrip }
    }

    /// 遮罩条 = 实心段 + 软边。两段各自用 `frame(width:)` 动，而不是改
    /// `LinearGradient` 的 stops ——**stops 的 location 变化 SwiftUI 不插值**，
    /// 会硬跳；`frame` 才是可动画的。
    ///
    /// 软边宽度恒定（视口的 34%），只有实心段在长：初始 0.34W（配合软边正好铺到
    /// 0.68W，即「左糊右清」），展开时 1.75W（软边整条扫出右缘，整幅全糊）。
    /// 实心段左边界恒在 0，所以已经糊住的区域一直是完整的模糊，不会变浅。
    private var maskStrip: some View {
        let fadeWidth = viewport.width * 0.34
        let solidWidth = viewport.width * (expanded ? 1.75 : 0.34)
        return HStack(spacing: 0) {
            Rectangle()
                .fill(.black)
                .frame(width: solidWidth)
            LinearGradient(
                colors: [.black, .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
        }
        .frame(height: viewport.height, alignment: .leading)
        .fixedSize()
    }

    /// 模糊层上的压雾:让左侧文字在任意剧照上都有对比度,深浅各压一档。
    /// 压得比 demo(0.34)轻一档:模糊本来就是给文字让位的,再叠厚白纱会把
    /// 「左糊右清」的分界也糊掉。
    private var veilTint: Color {
        colorScheme == .light ? Color.white.opacity(0.22) : Color.black.opacity(0.24)
    }

    /// 文字兜底压雾:与 `.detail` 档氛围底同口径——浅色压白雾(配深字)、深色压黑纱
    /// (配白字),右缘特意留淡,清晰剧照仍是视觉主体。
    ///
    /// 浅色档不能压太重:白雾盖在彩色剧照上会把整幅冲成一片粉白(实测 0.80/0.44 时
    /// 左侧糊得只剩色块,连标题都读不出来)。0.62 起手、中段迅速退到 0.1 以内,
    /// 靠**文字自身的深色**和一层极轻的毛玻璃底衬保对比度,而不是继续加雾。
    private var scrim: some View {
        Group {
            if colorScheme == .light {
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0.62), location: 0),
                        .init(color: .white.opacity(0.30), location: 0.36),
                        .init(color: .white.opacity(0.06), location: 0.66),
                        .init(color: .white.opacity(0.00), location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            } else {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.58), location: 0),
                        .init(color: .black.opacity(0.30), location: 0.36),
                        .init(color: .black.opacity(0.06), location: 0.66),
                        .init(color: .black.opacity(0.00), location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
        // 底部再压一档:选集带上方的提示文字落在剧照亮部也读得清
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [
                    .clear,
                    (colorScheme == .light ? Color.white : Color.black).opacity(0.42),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: viewport.height * 0.30)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        // 扫成全糊之后，上面那层左浓右淡的压雾就只是「左边特别白」了——正文是
        // 通栏的，右侧也要有可读对比度。补一层均匀底衬，随 expanded 淡入。
        .overlay {
            (colorScheme == .light ? Color.white : Color.black)
                .opacity(expanded ? (colorScheme == .light ? 0.34 : 0.30) : 0)
        }
    }
}

// MARK: - 第一页:LOGO / 元数据 / 标签 / 简介 / 播放钮 + 底部选集带
//
// 版式照 animeflip demo 的 `HeroForeground`:一层 ZStack、两个兄弟。
//
//   leftColumn —— LOGO / 原文标题 / 元数据 / 标签 / 简介 / 播放钮,顶端留白,底下 Spacer
//   bottomBar  —— 季胶囊 + 集数方格 + 选集缩略图带,自己贴底
//
// demo 里**没有任何底板层**:选集带直接浮在剧照上,靠剧照自己的压雾给文字兜底。
// 这里照搬——不加材质底、不加分割线、不加提示行、不加额外操作行。
struct DetailPageArtScreen: View {
    let viewport: CGSize
    let model: DetailViewModel
    let server: (any MediaServer)?
    let leadingInset: CGFloat

    let playLabel: String
    let playProgress: Double?
    let played: Bool
    let canPlay: Bool
    let canTogglePlayed: Bool
    let isUpdatingPlayed: Bool

    let onPlay: () -> Void
    let onTogglePlayed: () -> Void
    let onSelectEpisode: (MediaItem) -> Void
    let onPlayEpisode: (MediaItem) -> Void

    /// 本页选集带的分区浏览态（只影响这条带渲染哪一段）。
    @State private var chunkNav = EpisodeChunkNavigation()

    /// 与详情页主按钮同一组尺寸（`Metrics.bannerActionHeight` / 常规宽度 228）。
    private var actionHeight: CGFloat { Metrics.bannerActionHeight }
    private var playWidth: CGFloat { 228 }

    var body: some View {
        ZStack {
            leftColumn
            // 剧集：底部是选集带；其他类型（电影等）没有选集，底部就只放播放钮 ——
            // 两者占同一条底边，换条目进来时按钮不会在画面上跳位置。
            bottomBar
        }
    }

    // MARK: 左栏

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            logoBlock
                .padding(.top, viewport.height * 0.085)
            introBlock
                .padding(.top, 34)
            // 剧集页的播放钮跟着简介走（下面还有选集带）；电影页不留这一行，
            // 播放钮在底部条上——省出来的竖直空间全给简介/剧照。
            if isSeries {
                playButtons
                    .padding(.top, 30)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// 剧集：底部是季胶囊 + 集号方格 + 缩略图带。其他类型没有选集。
    private var isSeries: Bool { model.shown.kind == .series }

    private var logoBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            ItemTitleLogoView(
                item: model.shown,
                server: server,
                maxHeight: 108,
                maxWidth: 620,
                fontSize: 42,
                adaptiveText: true
            )
            if let original = originalTitle {
                Text(original)
                    .font(.system(size: 13, weight: .medium))
                    .tracking(5)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            metaRow
            if !genres.isEmpty {
                tagChips
                    .padding(.top, 2)
            }
        }
    }

    /// 原文标题：与条目名不同才显示（番剧库多为日文原名）。
    private var originalTitle: String? {
        guard let original = model.shown.originalTitle,
              !original.isEmpty,
              original != model.shown.name
        else { return nil }
        return original
    }

    private var genres: [String] {
        Array(model.displayGenres.prefix(4))
    }

    private var overview: String? {
        guard let text = model.displayOverview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    private var metaRow: some View {
        HStack(spacing: 9) {
            ForEach(Array(metaParts.enumerated()), id: \.element) { index, part in
                if index > 0 {
                    Text("·").foregroundStyle(.secondary.opacity(0.6))
                }
                Text(part).foregroundStyle(.secondary)
            }
            if let rating = model.displayRating {
                Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    .foregroundStyle(BangumiStatusColor.rating)
            }
            if let official = model.shown.officialRating {
                Text(official)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        // 详情未落地前整行隐匿（占住行高）：`shown` 从列表条目切到详情条目时
        // 「N 季 / 评分 / 分级」才补齐，半成品行先现身会明显右移一下。
        .opacity(model.detail == nil ? 0 : 1)
        .motion(Motion.standard, value: model.detail != nil)
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if let year = model.shown.year { parts.append(String(year)) }
        if !model.displayGenres.isEmpty {
            parts.append(model.displayGenres.prefix(3).joined(separator: " / "))
        }
        if let runtime = model.shown.runtimeSeconds { parts.append(RuntimeText.format(runtime)) }
        if model.shown.kind == .series, let count = model.shown.childCount {
            parts.append("\(count) 季")
        }
        return parts
    }

    /// 标签 chips：压在剧照上，用玻璃胶囊托住（demo 的 `ocGlassCapsule`）。
    private var tagChips: some View {
        HStack(spacing: 8) {
            ForEach(genres, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.82))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .liquidGlassCapsule(isInteractive: false)
            }
        }
    }

    private var introBlock: some View {
        Group {
            if let overview {
                Text(overview)
                    .font(.system(size: 15))
                    .lineSpacing(7)
                    .foregroundStyle(.primary.opacity(0.78))
                    // 剧集页身下还有选集带，留 3 行；其他类型播放钮已经让到最底部，
                    // 中间这块空着也是空着 —— 简介直接铺满、不再截断。
                    .lineLimit(isSeries ? 3 : nil)
                    .frame(width: viewport.width * introWidthRatio, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 简介栏宽：剧集页要跟右侧清晰剧照分界，取 36%；电影页没有选集带压底，
    /// 可以放宽到 44%，长简介读起来不至于是窄窄一条。
    private var introWidthRatio: CGFloat { isSeries ? 0.36 : 0.44 }

    // MARK: 播放行动区（demo 的 HeroResumeButton + HeroMarkPlayedButton）

    private var playButtons: some View {
        HStack(alignment: .center, spacing: 10) {
            playButton
            if canTogglePlayed {
                markPlayedButton
            }
        }
        .frame(height: actionHeight, alignment: .center)
    }

    private var playButton: some View {
        Button(action: onPlay) {
            ZStack(alignment: .leading) {
                // 进度块画在玻璃之上，玻璃只负责底色与折射。用 primary 的一档淡底
                // 而不是实心白：太实会把液态玻璃整段盖成一块死色，前后两截材质对不上。
                if let playProgress {
                    Rectangle()
                        .fill(Color.primary.opacity(0.16))
                        .frame(width: playWidth * min(max(playProgress, 0), 1))
                }
                Text(playLabel)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: playWidth, height: actionHeight)
            // 只有外层是胶囊圆角；进度矩形保持一条到底的竖直硬边
            .clipShape(Capsule())
            .liquidGlassCapsule()
            .contentShape(Capsule())
        }
        .modifier(DetailPlayButtonStyle())
        .disabled(!canPlay)
        .opacity(canPlay ? 1 : 0.55)
        .accessibilityLabel(playProgress == nil ? playLabel : "继续播放")
        .accessibilityValue(playProgress.map { String(format: "已看 %d%%", Int(($0 * 100).rounded())) } ?? "")
    }

    private var markPlayedButton: some View {
        Button(action: onTogglePlayed) {
            ZStack {
                if played {
                    Capsule().fill(Color.primary.opacity(0.16))
                }
                if isUpdatingPlayed {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: played ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.primary.opacity(0.82))
                        .symbolEffect(.bounce, value: played)
                }
            }
            .frame(width: actionHeight, height: actionHeight)
            .clipShape(Capsule())
            .liquidGlassCapsule()
            .contentShape(Capsule())
        }
        .modifier(DetailPlayButtonStyle())
        .disabled(isUpdatingPlayed)
        .opacity(isUpdatingPlayed ? 0.85 : 1)
        .help(played ? "标为未看" : "已看过")
        .accessibilityLabel(played ? "标为未看" : "已看过")
    }

    // MARK: 底部：通栏选集条（demo 的 bottomBar）

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isSeries {
                HStack(spacing: 12) {
                    seasonPicker
                    episodeRangePicker
                    Spacer(minLength: 0)
                }
                episodeThumbRail
            } else {
                // 电影这类没有选集：播放钮落在剧集页选集带的同一条底边上，
                // 左缘与简介对齐（靠下面的 `alignment: .bottomLeading`）。
                playButtons
            }
        }
        .padding(.horizontal, leadingInset)
        .padding(.bottom, bottomInset)
        // 两种内容都按左下角贴底：选集带的季胶囊/集号方格本来就是左对齐的，
        // 电影页那颗播放钮也要贴在左下（用 .bottom 会被居中）。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// 底距。iOS 选集带在标签栏预留空间之上再留 34；macOS 保持 22。
    /// 电影页只有一颗播放钮，仍抬高到 74。
    private var bottomInset: CGFloat {
        guard isSeries else { return 74 }
        #if os(iOS)
        return 34
        #else
        return 22
        #endif
    }

    /// 季选择：点击弹出列表，点选切换。
    @ViewBuilder
    private var seasonPicker: some View {
        if model.seasons.count > 1 {
            Menu {
                ForEach(model.seasons) { season in
                    Button {
                        model.selectSeason(season.id)
                        // 换季把分区浏览态清回「跟随选中集」：旧段号对新季没有意义
                        chunkNav.followSelection()
                    } label: {
                        if season.id == model.selectedSeasonID {
                            Label(season.name, systemImage: "checkmark")
                        } else {
                            Text(season.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(model.selectedSeasonName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .liquidGlassCapsule()
                .contentShape(Capsule())
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("切换季")
            .accessibilityLabel("切换季，当前 \(model.selectedSeasonName)")
        } else {
            Text(model.selectedSeasonName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }

    /// 集数方格：一段 > 30 集才先出段标签（1-30 / 31-60 …），后面是这一段的集号方格。
    private var episodeRangePicker: some View {
        HStack(spacing: 8) {
            if model.episodeChunks.count > 1 {
                ForEach(model.episodeChunks) { chunk in
                    rangeTab(chunk)
                }
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(activeSlots) { slot in
                            episodeSquare(slot)
                                .id(slot.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .frame(maxWidth: 760)
                .followsEpisodeSelection(proxy: proxy, selectedID: model.selectedEpisodeID,
                                         slotIDs: activeSlotIDs, activeIndex: activeChunkIndex)
            }
        }
    }

    private func rangeTab(_ chunk: EpisodeChunk) -> some View {
        let isOn = chunk.index == activeChunkIndex
        return Button {
            chunkNav.browsedIndex = chunk.index
        } label: {
            Text(chunk.rangeLabel)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isOn ? AppAccent.onSolid : .primary.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isOn ? AppAccent.solid : Color.primary.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
        .help(chunk.accessibilityLabel)
        .accessibilityLabel(chunk.accessibilityLabel)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func episodeSquare(_ slot: EpisodeSlot) -> some View {
        let isSelected = slot.id == model.selectedEpisodeID
        if let number = episodeNumber(of: slot) {
            if let episode = slot.episode {
                let isPlayed = episode.playState?.played == true
                Button {
                    onSelectEpisode(episode)
                } label: {
                    squareLabel(number, isSelected: isSelected, enabled: true, isPlayed: isPlayed)
                }
                .buttonStyle(.plain)
                .help(model.displayEpisodeTitle(episode))
                .accessibilityLabel("第 \(number) 集")
                .accessibilityValue(isPlayed ? "已看完" : "未看完")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            } else {
                // 占位格不可选（不是一个能播的条目）：淡一档、不带按钮 trait
                squareLabel(number, isSelected: false, enabled: false)
                    .help("未入库")
            }
        }
    }

    private func squareLabel(_ number: Int, isSelected: Bool, enabled: Bool, isPlayed: Bool = false) -> some View {
        Text(String(number))
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .frame(width: 32, height: 32)
            .foregroundStyle(
                isSelected
                    ? AnyShapeStyle(AppAccent.onSolid)
                    : (enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            )
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AppAccent.solid : Color.primary.opacity(isPlayed ? 0.22 : (enabled ? 0.10 : 0.04)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isSelected ? 0 : (isPlayed ? 0.32 : 0.08)), lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                // 勾独立于选中态，选中已看集时仍能辨认观看状态。
                if isPlayed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(isSelected ? AppAccent.onSolid : AppAccent.solid)
                        .padding(3)
                        .accessibilityHidden(true)
                }
            }
    }

    private var thumbRailFadeWidth: CGFloat { min(36, leadingInset) }

    private var episodeThumbRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                thumbRailContent
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .modifier(EpisodeRailEdgeFade(width: thumbRailFadeWidth))
            // 将渐隐区放进栏外留白，原有内容边界内保持清晰。
            .padding(.horizontal, -thumbRailFadeWidth)
            .followsEpisodeSelection(proxy: proxy, selectedID: model.selectedEpisodeID,
                                     slotIDs: activeSlotIDs, activeIndex: activeChunkIndex)
        }
    }

    private var thumbRailContent: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(activeSlots) { slot in
                thumbCard(slot)
                    // `scrollTo` 的落点靠它：不给 id 就滚不到具体某一集
                    .id(slot.id)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        // 抵消外扩视口，第一张与最后一张停靠时仍与上方集号栏对齐。
        .padding(.horizontal, thumbRailFadeWidth)
    }

    @ViewBuilder
    private func thumbCard(_ slot: EpisodeSlot) -> some View {
        if let episode = slot.episode {
            DetailHeroEpisodeThumb(
                number: episode.episodeNumber,
                title: model.displayEpisodeTitle(episode),
                overview: model.displayEpisodeOverview(episode),
                thumbTarget: model.episodeThumbTarget(for: episode, width: 400),
                isSelected: episode.id == model.selectedEpisodeID,
                isPlayed: episode.playState?.played == true,
                progress: progress(of: episode),
                isPlayable: true,
                onSelect: { onSelectEpisode(episode) },
                onPlay: { onPlayEpisode(episode) }
            )
        } else if let placeholder = slot.placeholder {
            DetailHeroEpisodeThumb(
                number: placeholder.number,
                title: placeholder.displayTitle,
                overview: placeholder.overview,
                thumbTarget: model.placeholderThumbTarget(for: placeholder, width: 400),
                isSelected: false,
                isPlayed: false,
                progress: nil,
                isPlayable: false,
                onSelect: {},
                onPlay: {}
            )
        }
    }

    // MARK: 选集带的派生值

    /// 当前分区号：用户手点过就听用户的，否则跟随选中集（纯值计算在 `MetadataKit`）。
    private var activeChunkIndex: Int {
        chunkNav.activeIndex(
            in: model.episodeChunks,
            selectedEpisodeID: model.selectedEpisodeID,
            ascending: true
        )
    }

    /// 当前分区要渲染的格子（≤30 张）。
    private var activeSlots: [EpisodeSlot] {
        chunkNav.railSlots(in: model.episodeChunks, activeIndex: activeChunkIndex, ascending: true)
    }

    /// 当前这一段所有格子的 id。作为 `onChange` 的监视值用（数据晚到 / 换季 /
    /// 换段都会让它变），比逐个监听 `episodeSlots` 更稳：只有真正参与渲染的那一段
    /// 才触发重定位。
    private var activeSlotIDs: [String] { activeSlots.map(\.id) }

    private func episodeNumber(of slot: EpisodeSlot) -> Int? {
        if let episode = slot.episode { return episode.episodeNumber }
        return slot.placeholder?.number
    }

    /// 已看比例。与服务端 `PlayedPercentage` 同口径，缺百分比时按时长折算；
    /// 已看完 / 不足 30 秒都没有续播意义，返回 nil（不画进度）。
    private func progress(of episode: MediaItem) -> Double? {
        guard let state = episode.playState, !state.played else { return nil }
        guard state.positionSeconds >= 30 else { return nil }
        if state.percentage > 0 { return min(max(state.percentage, 0), 1) }
        guard let runtime = episode.runtimeSeconds, runtime > 0 else { return nil }
        return min(max(state.positionSeconds / runtime, 0), 1)
    }
}

// MARK: - 选中集跟随滚动

/// 只把仍有屏外内容的一侧柔化，首尾卡片完全进入视口时恢复清晰边缘。
private struct EpisodeRailEdgeFade: ViewModifier {
    let width: CGFloat

    private struct Edges: Equatable {
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
    }

    @State private var edges = Edges()

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Edges.self) { geometry in
                guard width > 0 else { return Edges() }
                let leading = geometry.contentOffset.x + geometry.contentInsets.leading
                let trailing = geometry.contentSize.width + geometry.contentInsets.trailing
                    - geometry.contentOffset.x - geometry.containerSize.width
                return Edges(
                    leading: min(max(leading / width, 0), 1),
                    trailing: min(max(trailing / width, 0), 1)
                )
            } action: { _, newEdges in
                edges = newEdges
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black.opacity(1 - edges.leading), .black],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: width)
                    Rectangle().fill(.black)
                    LinearGradient(
                        colors: [.black, .black.opacity(1 - edges.trailing)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: width)
                }
                .allowsHitTesting(false)
            }
    }
}

/// 让一条横向选集轨道跟着「当前选中集」走。
///
/// 第一页底部有**两条**轨道（上：集号方格；下：缩略图带），它们是两个独立的
/// `ScrollView`。点方格时若只有选中态变化、下面的缩略图带不动，选到第 10 集时
/// 那张卡还留在屏幕外——用户要的就是这里联动。两条轨道挂同一个修饰符，
/// 于是「点方格 → 带子跟过去」「点缩略图 → 方格跟过去」自然成为双向。
///
/// 触发时机四类，都收在这里（视图侧只挂一次，不散落）：
///   * `onAppear` —— 进页就定位到当前选中集（含从「继续播放」进来的续播集）
///   * 选中集变化 —— 手点、换集、换季重置都走这一条
///   * 分段变化 —— 换季 / 点段标签后重定位到统一段落
///   * 段内格子变化 —— 剧集数据晚到时（首帧还是空段）补一次定位
private struct SelectionFollower: ViewModifier {
    let proxy: ScrollViewProxy
    let selectedID: MediaItem.ID?
    let slotIDs: [String]
    let activeIndex: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .onAppear { scroll(animated: false) }
            .onChange(of: selectedID) { _, _ in scroll(animated: true) }
            .onChange(of: activeIndex) { _, _ in scroll(animated: false) }
            .onChange(of: slotIDs) { _, _ in scroll(animated: false) }
    }

    /// 选中集不在本段（跨段浏览到别处）时什么也不做：那时没有可滚的目标，
    /// 硬滚只会把用户正在看的那一段拽走。
    private func scroll(animated: Bool) {
        guard let selectedID, slotIDs.contains(selectedID) else { return }
        if animated, !reduceMotion {
            withAnimation(Motion.standard) {
                proxy.scrollTo(selectedID, anchor: .center)
            }
        } else {
            proxy.scrollTo(selectedID, anchor: .center)
        }
    }
}

extension View {
    /// 横向选集轨道跟随选中集（见 `SelectionFollower`）。
    fileprivate func followsEpisodeSelection(
        proxy: ScrollViewProxy,
        selectedID: MediaItem.ID?,
        slotIDs: [String],
        activeIndex: Int
    ) -> some View {
        modifier(SelectionFollower(
            proxy: proxy,
            selectedID: selectedID,
            slotIDs: slotIDs,
            activeIndex: activeIndex
        ))
    }
}

// MARK: - 选集带缩略图（animeflip demo 的 EpisodeThumb 口径）

/// 160×90 剧照 + 一行「第N话 标题」。
///
/// 选中态照 demo：外框 2pt 强调色描边 + 底部一条进度、右上角已看角标；悬停轻微上浮。
/// 与 demo 的差别只有一处配色——demo 用珊瑚色，本 App 的强调色是**中性**的
/// （`AppAccent.solid` / `.tint`），选中与进度都跟着走，不引入第二套色相。
///
/// 单击选中、双击开播（与正文页的 `EpisodeSelectCard` 同一套交互）。
private struct DetailHeroEpisodeThumb: View {
    let number: Int?
    let title: String
    let overview: String?
    let thumbTarget: (url: URL?, authHeader: String?)
    let isSelected: Bool
    let isPlayed: Bool
    /// 已看比例（nil = 没有续播进度）
    let progress: Double?
    /// 占位（库里没有这一集）时整卡不可点，也不带按钮 trait
    let isPlayable: Bool
    let onSelect: () -> Void
    let onPlay: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private let cardWidth: CGFloat = 160
    private let cardHeight: CGFloat = 90

    var body: some View {
        Group {
            if isPlayable {
                Button(action: onSelect) { card }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { onPlay() })
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText)
                    .accessibilityHint("轻点以选中，双击直接播放")
                    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            } else {
                card
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(labelText)，未入库")
            }
        }
        .help(helpText)
        .onHover { hovering = $0 }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 7) {
            artwork
            Text(labelText)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .frame(width: cardWidth, alignment: .leading)
        }
        .frame(width: cardWidth)
    }

    private var artwork: some View {
        ZStack {
            if thumbTarget.url != nil {
                RemoteImage(
                    url: thumbTarget.url,
                    authHeader: thumbTarget.authHeader,
                    maxPixelSize: 400
                )
                .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Metrics.placeholderFill)
            }

            // 底部渐隐：标题与角标压在图上也要读得清
            LinearGradient(
                colors: [.clear, .black.opacity(0.34)],
                startPoint: .center,
                endPoint: .bottom
            )

            if isPlayable {
                playBadge
            } else {
                Text("未入库")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
            }

            if progress != nil {
                progressBar
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isPlayed { playedBadge.padding(6) }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary.opacity(hovering && isPlayable ? 0.22 : 0.08)),
                    lineWidth: isSelected ? 2 : 1
                )
        }
        .shadow(color: .black.opacity(hovering ? 0.28 : 0.14), radius: hovering ? 12 : 6, y: hovering ? 5 : 2)
        .scaleEffect(hovering && isPlayable ? 1.03 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
        .opacity(isPlayable ? 1 : 0.72)
    }

    private var playBadge: some View {
        Circle()
            .fill(.white.opacity(0.16))
            .frame(width: 32, height: 32)
            .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: 1))
            .overlay(
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(hovering || isSelected ? 1 : 0.88))
                    .offset(x: 1)
            )
            .scaleEffect(hovering ? 1.08 : 1)
    }

    private var playedBadge: some View {
        Circle()
            .fill(AppAccent.solid)
            .frame(width: 18, height: 18)
            .overlay(
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(AppAccent.onSolid)
            )
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
    }

    private var progressBar: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(.white.opacity(0.24))
            GeometryReader { geo in
                Rectangle()
                    .fill(.white)
                    .frame(width: geo.size.width * (progress ?? 0))
            }
        }
        .frame(height: 3)
    }

    /// 「第3话 危险边缘的慢舞」；没有标题时只写集号。
    private var labelText: String {
        guard let number else { return title }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "第 \(number) 集" { return "第\(number)话" }
        return "第\(number)话 \(trimmed)"
    }

    private var helpText: String {
        let text = overview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? labelText : text
    }

    private var accessibilityText: String {
        var parts = [labelText]
        if isPlayed { parts.append("已看完") }
        else if let progress { parts.append("已播放 \(Int((progress * 100).rounded()))%") }
        if isSelected { parts.append("已选中") }
        return parts.joined(separator: "，")
    }
}

// MARK: - 窗口锚点

/// 把详情页所在窗口回报给状态机:滚轮监视器只裁决这个窗口的事件。
#if os(macOS)
struct DetailPageWindowAnchor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AnchorView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? AnchorView)?.onResolve = onResolve
    }

    final class AnchorView: NSView {
        var onResolve: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 出栈时 window 变 nil,正好把监视器一起摘掉
            onResolve?(window)
        }
    }
}

#endif

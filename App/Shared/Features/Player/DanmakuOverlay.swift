import DanmakuRenderKit
import PlaybackKit
import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformFont = UIFont
#endif

/// App 层弹幕 overlay（见 Packages/DanmakuRenderKit/PROVENANCE.md）。
///
/// 为什么不用内核弹幕的旧因已定位:转换器给每条弹幕合成稳定唯一 `id`,内核拿它当
/// shell stable_tracks 的 key,viewport 重排时个别弹幕的轨道偏好互相顶掉 → 单独几条
/// 突然换位置(跳轨)。去掉 `id` 后跳轨曾消失过一次,但内核 DFM+ 的滑窗重排问题
/// 再次出现,当前版本**禁用内核弹幕渲染,一律走本 overlay**:DanmakuRenderKit 的
/// 轨道模型是入轨时「追击判定」、入轨后不换轨,结构上不会有重排换轨。
/// `PlaybackController.resolveOverlayDanmakuRoute()` 当前恒 true,内核修复后恢复
/// 旧判定（内核支持则听偏好,不支持则强制 overlay——如 libmpv 只能走这条路）。
///
/// 时间桥：内核每帧发 positionChanged（`PlaybackEngine.latestMediaTime`），本控制器
/// 30Hz 采样它决定谁出场。暂停/缓冲＝媒体时间冻结 → 冻结检测暂停视图动画；
/// seek＝时间跳变 → 清屏重同步。速率变化透传 `playingSpeed`。
///
/// ⚠️ 对内核的要求只有两条：`latestMediaTime` 读取要**便宜**（30Hz 采样不能被
/// 一整帧渲染阻塞），以及 playing/buffering 状态由真实事件驱动。换内核时先验这两条。
@MainActor
final class DanmakuOverlayController {
    struct Comment: Equatable {
        let time: Double
        let mode: Mode
        let color: UInt32
        let text: String

        enum Mode { case scroll, top, bottom }
    }

    /// 渲染偏好（由 PlaybackController 镜像下发，保持与内核路径同一套 UserDefaults）。
    struct Preferences {
        var enabled = true
        var opacity: Double = 0.85
        var displayArea: Double = 0.75
        var blockTop = false
        var blockBottom = false
        var blockScroll = false
        var allowStacking = false
        /// 全局时间偏移（秒），正数让弹幕更晚出现。
        var offsetSeconds: Double = 0
        /// 基础字号
        var fontSize: Double = 22.0
    }

    var engineProvider: () -> (any PlaybackEngine)?
    /// 真实播放状态（playing/buffering 由内核事件驱动，不靠媒体时间猜——
    /// 24fps 视频配 60Hz 采样会每隔一次看到 delta=0，时间猜测会以 ~15Hz
    /// 抖动 pause/play，而库的 pause 会移除全部动画、play 重加，抖起来
    /// 就是满屏「一抽一抽」）。
    var playbackStateProvider: () -> (playing: Bool, buffering: Bool)?
    private(set) var preferences = Preferences()

    private(set) lazy var view: DanmakuView = {
        let view = DanmakuView(frame: .zero)
        // 复用池：默认 false 时每条弹幕都新建 NSView，密集段落的 alloc/addSubview
        // 抖动会顶到主线程帧预算（上游 Mac 示例同样打开）。
        view.enableCellReusable = true
        applyPreferences(to: view)
        return view
    }()

    private var comments: [Comment] = []

    /// 弹幕数据是否已装载（HUD「时间偏移」区块的显隐用；overlay 路线下
    /// controller 的内核轨道恒为空，不能拿轨道数判断）。
    var hasComments: Bool { !comments.isEmpty }
    /// 下一条待出场弹幕的下标（comments 已按 time 排序）。
    private var pointer = 0
    /// 匹配返回的时间轴校正（dandanplay shift），与 HUD 全局偏移分开工。
    private var trackOffsetSeconds: Double = 0
    private var timer: Timer?
    private var lastMediaSample: Double?
    /// 上次发射机会的 effective 阈值。与本次阈值差 >2s = 媒体时间发生了 tick
    /// 没看见的跳变，spawnUpTo 据此跳过积压（结构性兜底，见其注释）。
    private var lastSpawnThreshold: Double?
    private var viewPausedBySync = false

    /// 每 5s 打一条 overlay 状态日志（诊断内存爬升用）：已发射条数 / 子视图数 / 复用池大小。
    /// 子视图数在播放途中持续增长 = cell 没有被正确回收复用。
    private var lastStateLogAt: TimeInterval = 0
    /// 单帧发射超过此数即判定「爆发补发」（正常节奏单帧只发几条），写 warning 日志。
    private static let burstSpawnThreshold = 40
    /// seek 跳变判定阈值（秒）：tick 的 delta 检测与 spawnUpTo 的积压兜底共用同一标准。
    private static let seekJumpSeconds = 2.0
    /// 弹幕诊断日志开关（PlaybackPreferences 默认关，设置页「弹幕诊断日志」控制）。
    private var diagnosticsEnabled: Bool { PlaybackPreferences.danmakuDiagnosticsEnabled }

    init(engineProvider: @escaping () -> (any PlaybackEngine)?,
         playbackStateProvider: @escaping () -> (playing: Bool, buffering: Bool)? = { nil }) {
        self.engineProvider = engineProvider
        self.playbackStateProvider = playbackStateProvider
    }

    // MARK: - 数据

    /// 解析 Erika JSON（与内核 `addDanmakuTrack(json:)` 同一份输入）。
    /// `trackOffsetSeconds` 是匹配源的 shift，与用户全局偏移叠加生效。
    func replace(json: String, trackOffsetSeconds: Double) {
        comments = Self.parse(json).sorted { $0.time < $1.time }
        self.trackOffsetSeconds = trackOffsetSeconds
        PlaybackLog.append("danmaku overlay 装载 \(comments.count) 条 trackOffset=\(trackOffsetSeconds)s")
        resync(reason: "replace")
    }

    func clear() {
        comments = []
        pointer = 0
        lastMediaSample = nil
        lastSpawnThreshold = nil
        view.clean()
        // 复用池里的 cell 带着整条已渲染弹幕的模型/测量，不清的话关播放器后
        // 上一集的 cell 树整棵留在单例持有的 DanmakuView 上（vendored 层修补，
        // 见 DanmakuRenderKit PROVENANCE.md）。
        view.clearPool()
    }

    func reset() {
        clear()
        stopTimer()
    }

    /// 视图从窗口移除时调用:只停采样 timer,不动弹幕数据。
    /// overlay 随播放器状态会经历 disappear → reappear(如窗口还原动画期间),
    /// 数据在 controller 生命周期里跨这些阶段保留,重新 appear 后 startTimer 继续播。
    func pauseSampling() {
        stopTimer()
    }

    private static func parse(_ json: String) -> [Comment] {
        struct Item: Decodable {
            let time: Double
            let type: Int
            let color: Int64?
            let content: String
        }
        struct Payload: Decodable { let comments: [Item]? }
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            // 解析失败原先静默返回空列表——网关响应异常时看起来像「没有弹幕」，
            // 留一条日志区分「真没有」和「解析挂了」。
            PlaybackLog.info("弹幕 JSON 解析失败 size=\(json.count)")
            return []
        }
        return (payload.comments ?? []).compactMap { item in
            guard item.time.isFinite, item.time >= 0, !item.content.isEmpty else { return nil }
            let mode: Comment.Mode
            switch item.type {
            case 5: mode = .top
            case 4: mode = .bottom
            default: mode = .scroll
            }
            // color 可能是负数（服务端按有符号 int 写 0xFFFFFFFF 类颜色），
            // UInt32(负数) 会直接 trap，必须先夹进 [0, 0xFFFFFF] 再转。
            let color = max(0, min(item.color ?? 0xFF_FF_FF, 0xFF_FF_FF))
            return Comment(time: item.time, mode: mode,
                           color: UInt32(color) & 0xFF_FF_FF,
                           text: item.content)
        }
    }

    // MARK: - 偏好

    func update(_ transform: (inout Preferences) -> Void) {
        var next = preferences
        transform(&next)
        let offsetChanged = next.offsetSeconds != preferences.offsetSeconds
        let fontSizeChanged = next.fontSize != preferences.fontSize
        preferences = next
        applyPreferences(to: view)
        if offsetChanged || fontSizeChanged { resync(reason: "preferences") }
    }

    private func applyPreferences(to view: DanmakuView) {
        let p = preferences
        view.displayArea = CGFloat(max(0.1, min(1, p.displayArea)))
        view.enableFloatingDanmaku = !p.blockScroll
        view.enableTopDanmaku = !p.blockTop
        view.enableBottomDanmaku = !p.blockBottom
        view.isOverlap = p.allowStacking
        view.paddingTop = 10
        view.paddingBottom = 16
        view.trackHeight = CGFloat(p.fontSize) * 1.35
        #if os(macOS)
        view.alphaValue = CGFloat(max(0.05, min(1, p.opacity)))
        #else
        view.alpha = CGFloat(max(0.05, min(1, p.opacity)))
        #endif
        view.isHidden = !p.enabled
        if !p.enabled { view.clean() }
    }

    func setRate(_ rate: Double) {
        view.playingSpeed = Float(max(0.25, min(4, rate)))
    }

    // MARK: - 采样同步

    /// 当前是否处于活跃档（60Hz）。暂停/缓冲/禁用/空数据时降到 2Hz 轮询。
    private var timerIsFast = true

    func startTimer() {
        guard timer == nil else { return }
        armTimer(fast: true)
    }

    /// 活跃时 60Hz 平滑采样发射（消除 30Hz 定时器的成团发射突发感）；
    /// 暂停/缓冲/禁用/空数据这些没有可做事的状态降到 2Hz——只留「发觉状态恢复」
    /// 的轮询，不再每秒空醒主线程 60 次。
    private func armTimer(fast: Bool) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: fast ? 1.0 / 60.0 : 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        timerIsFast = fast
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// 弹幕是否处于「有事可做」的活跃状态。
    private var isDanmakuActive: Bool {
        guard let engine = engineProvider(), preferences.enabled, !comments.isEmpty else { return false }
        if let playback = playbackStateProvider(), !playback.playing || playback.buffering { return false }
        return true
    }

    private func tick() {
        // 频率按状态升降：恢复播放回到 60Hz 由这里的轮询发觉（≤0.5s 延迟）。
        let active = isDanmakuActive
        if timerIsFast != active { armTimer(fast: active) }

        guard let engine = engineProvider(), preferences.enabled, !comments.isEmpty else { return }
        let now = mediaSeconds(engine)

        // 暂停/缓冲跟随真实播放状态：暂停时停视图动画，恢复时续播
        //（pause 会把 cell 模型帧钉在呈现位置，play 从那里续，不瞬移）。
        if let playback = playbackStateProvider() {
            let shouldPause = !playback.playing || playback.buffering
            if shouldPause != viewPausedBySync {
                if shouldPause { view.pause() } else { view.play() }
                viewPausedBySync = shouldPause
            }
        }

        guard let last = lastMediaSample else {
            lastMediaSample = now
            return
        }
        lastMediaSample = now

        let delta = now - last
        if delta < -0.5 || delta > Self.seekJumpSeconds {
            // seek：媒体时间跳变，清屏重同步。
            resync(reason: "seek")
            return
        }
        if viewPausedBySync { return }
        // 5s 状态采样（诊断内存爬升）：cell 回收/复用是否失衡。
        // 平时关（诊断开关）不打——每 5s 一条属「排查时才需要」的高频日志。
        if diagnosticsEnabled {
            let wall = Date().timeIntervalSinceReferenceDate
            if wall - lastStateLogAt >= 5 {
                lastStateLogAt = wall
                PlaybackLog.info(
                    "弹幕 overlay 状态 已发射=\(pointer) 子视图=\(view.subviews.count) "
                        + "池=\(view.pooledCellCount) 总数=\(comments.count)"
                )
            }
        }
        spawnUpTo(now)
    }

    private func mediaSeconds(_ engine: any PlaybackEngine) -> Double {
        Double(engine.latestMediaTime.microseconds) / 1_000_000
    }

    /// 出场判定用的有效媒体时间（两个偏移都让弹幕更晚出现 → 时间轴右移）。
    private func effectiveSeconds(_ raw: Double) -> Double {
        raw - trackOffsetSeconds - preferences.offsetSeconds
    }

    /// seek / 换数据 / 改偏移后：清屏，指针对齐当前媒体时间。
    /// `reason` 只进诊断日志，用于区分对齐触发源（replace/seek/preferences/backlog）。
    private func resync(reason: String = "seek") {
        guard preferences.enabled, let engine = engineProvider() else { return }
        view.stop()
        view.play()
        viewPausedBySync = false
        let now = effectiveSeconds(mediaSeconds(engine))
        pointer = comments.firstIndex { $0.time > now } ?? comments.count
        if diagnosticsEnabled {
            // 对齐点即「从此刻起才发射的弹幕时间轴」。续播起播若这里对齐到 ~0
            // 而实际播放已在续播位，后面 tick 会把 0~续播位 的弹幕一次补发。
            PlaybackLog.info(
                "弹幕时间轴对齐 reason=\(reason) "
                    + "mediaTime=\(String(format: "%.1f", now))s "
                    + "pointer=\(pointer)/\(comments.count) "
                    + "trackOffset=\(String(format: "%.1f", trackOffsetSeconds))s"
            )
        }
        // 置为对齐点而非 nil：resync 后首拍 tick 仍要做 seek 跳变检测。置 nil 的话，
        // 续播 seek 若落在「注入对齐」与首拍之间（日志实证的爆发根因），跳变会被
        // 首拍静默吞掉，第二拍就把 0~续播位 的弹幕一次补发。
        lastMediaSample = now
        lastSpawnThreshold = now
        startTimer()
    }

    private func spawnUpTo(_ mediaSeconds: Double) {
        let threshold = effectiveSeconds(mediaSeconds)
        // 结构性兜底：正常节奏下两次发射机会之间媒体时间只前进不到一帧，差出
        // seekJumpSeconds 说明发生了 tick 没看见的跳变（暂停中 seek、内核时间源
        // 异常等）。积压的是「早已过点」的过期弹幕，补发就是「起播爆一大片」的
        // 用户观感——清屏重对齐跳过它，而不是喷出来。
        if let last = lastSpawnThreshold, threshold - last > Self.seekJumpSeconds {
            PlaybackLog.warning(
                "弹幕积压跳变已跳过 last=\(String(format: "%.1f", last))s "
                    + "now=\(String(format: "%.1f", threshold))s "
                    + "pointer=\(pointer)/\(comments.count)"
            )
            lastSpawnThreshold = threshold
            resync(reason: "backlog")
            return
        }
        lastSpawnThreshold = threshold
        let start = pointer
        while pointer < comments.count, comments[pointer].time <= threshold {
            view.shoot(danmaku: makeModel(for: comments[pointer]))
            pointer += 1
        }
        let spawned = pointer - start
        // 单帧发射远超正常节奏 = 时间轴对齐错位导致补发（典型：续播起播对齐到 0），
        // 与「弹幕时间轴对齐」日志对照即可定位根因。
        if diagnosticsEnabled, spawned >= Self.burstSpawnThreshold {
            PlaybackLog.warning(
                "弹幕爆发发射 spawned=\(spawned) "
                    + "mediaTime=\(String(format: "%.1f", mediaSeconds))s "
                    + "pointer=\(pointer)/\(comments.count) "
                    + "threshold=\(String(format: "%.1f", threshold))s"
            )
        }
    }

    private func makeModel(for comment: Comment) -> DanmakuCellModel {
        OverlayDanmakuModel(comment: comment, fontSize: CGFloat(preferences.fontSize))
    }
}

// MARK: - Cell

/// 单条弹幕的模型：文本 / 颜色 / 字号 / 类型 / 停留时长，尺寸预测量。
final class OverlayDanmakuModel: DanmakuCellModel {
    let comment: DanmakuOverlayController.Comment
    let font: PlatformFont
    let color: PlatformColor
    let size: CGSize
    let marginX: CGFloat
    let marginY: CGFloat
    let identifier: String
    let displayTime: Double
    let type: DanmakuCellType
    var track: UInt?

    init(comment: DanmakuOverlayController.Comment, fontSize: CGFloat) {
        self.comment = comment
        #if os(macOS)
        font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        color = NSColor(calibratedRed: CGFloat((comment.color >> 16) & 0xFF) / 255,
                        green: CGFloat((comment.color >> 8) & 0xFF) / 255,
                        blue: CGFloat(comment.color & 0xFF) / 255, alpha: 1)
        #else
        font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        color = UIColor(red: CGFloat((comment.color >> 16) & 0xFF) / 255,
                        green: CGFloat((comment.color >> 8) & 0xFF) / 255,
                        blue: CGFloat(comment.color & 0xFF) / 255, alpha: 1)
        #endif
        identifier = "\(comment.time)#\(comment.text)"
        // 自然飞行节奏：滚动弹幕 7 秒（更灵动不拥堵），固定弹幕 4 秒。
        displayTime = comment.mode == .scroll ? 7.0 : 4.0
        switch comment.mode {
        case .scroll: type = .floating
        case .top: type = .top
        case .bottom: type = .bottom
        }
        let attributed = NSAttributedString(string: comment.text, attributes: [.font: font])
        var measured = attributed.size()
        // 描边与阴影在字形外扩，测量宽度与高度预留边距，避免边缘裁切。
        let mX = max(8.0, fontSize * 0.35)
        let mY = max(4.0, fontSize * 0.15)
        self.marginX = mX
        self.marginY = mY
        measured.width += mX
        measured.height += mY
        size = measured
    }

    var cellClass: DanmakuCell.Type { OverlayDanmakuCell.self }

    func isEqual(to cellModel: DanmakuCellModel) -> Bool {
        guard let other = cellModel as? OverlayDanmakuModel else { return false }
        return identifier == other.identifier
    }
}

/// 单条弹幕的高清绘制：
/// 1. 彻底关闭透明上下文上的 LCD 亚像素平滑（Font Smoothing），杜绝白边泛白；
/// 2. 双通道分层绘制：底层纯黑描边 + 顶层原色填充，确保弹幕原色鲜亮纯正；
/// 3. 亮度自适应描边（亮色字纯黑描边，极深字柔和浅描边）；
/// 4. 柔和投影增强高亮与复杂视频背景穿透力。
final class OverlayDanmakuCell: DanmakuCell {
    override func displaying(_ context: CGContext, _ size: CGSize, _ isCancelled: Bool) {
        guard !isCancelled, let model = model as? OverlayDanmakuModel else { return }

        // 透明位图上下文禁止字体平滑（Font Smoothing 默认假设白底，在透明图层上会引起暗色背景泛白）
        context.setAllowsFontSmoothing(false)
        context.setShouldSmoothFonts(false)

        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.setAllowsFontSubpixelPositioning(true)
        context.setShouldSubpixelPositionFonts(true)
        context.setAllowsFontSubpixelQuantization(true)
        context.setShouldSubpixelQuantizeFonts(true)
        context.setLineJoin(.round)
        context.setLineCap(.round)

        #if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        #endif

        let text = NSString(string: model.comment.text)

        // 计算文字亮度：浅色/亮色文字用纯黑坚实描边，深色/黑字用高亮描边避免黑成一团
        let r = CGFloat((model.comment.color >> 16) & 0xFF) / 255
        let g = CGFloat((model.comment.color >> 8) & 0xFF) / 255
        let b = CGFloat(model.comment.color & 0xFF) / 255
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        let strokeColor: PlatformColor = luminance < 0.25
            ? PlatformColor(white: 0.85, alpha: 1.0)
            : PlatformColor.black

        #if os(macOS)
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -1.0)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        #else
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = CGSize(width: 0, height: 1.0)
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.45)
        #endif

        // 双通道分层绘制：
        // 第 1 遍：底层绘制空心纯黑描边（正数 strokeWidth 表示仅描边不填充）+ 阴影
        // 第 2 遍：顶层绘制 100% 原始色彩实体文字填充（无 strokeWidth，保留弹幕原色）
        let strokeWidthPercent: Double = 8.0

        let strokeAttributes: [NSAttributedString.Key: Any] = [
            .font: model.font,
            .foregroundColor: strokeColor,
            .strokeColor: strokeColor,
            .strokeWidth: strokeWidthPercent,
            .shadow: shadow,
        ]

        let fillAttributes: [NSAttributedString.Key: Any] = [
            .font: model.font,
            .foregroundColor: model.color,
        ]

        let origin = CGPoint(x: model.marginX / 2, y: model.marginY / 2)
        text.draw(at: origin, withAttributes: strokeAttributes)
        text.draw(at: origin, withAttributes: fillAttributes)
    }
}

// MARK: - SwiftUI 宿主

/// 弹幕 overlay 的 SwiftUI 壳：垫在视频表面之上、手势层之下。
struct DanmakuOverlayHost: View {
    let controller: DanmakuOverlayController

    var body: some View {
        DanmakuOverlayRepresentable(controller: controller)
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .onDisappear {
                // 只停 60Hz 采样 timer,保留已装载的弹幕数据:
                // overlay 在窗口还原动画等场景会先 disappear 再 reappear,
                // 丢数据会导致重开后进度指针错位或弹幕整体丢失。
                controller.pauseSampling()
            }
    }
}

private struct DanmakuOverlayRepresentable: PlatformViewRepresentable {
    let controller: DanmakuOverlayController

    #if os(macOS)
    func makeNSView(context: Context) -> DanmakuView {
        controller.startTimer()
        return controller.view
    }

    func updateNSView(_ nsView: DanmakuView, context: Context) {}

    static func dismantleNSView(_ nsView: DanmakuView, coordinator: ()) {
        nsView.pause()
    }
    #else
    func makeUIView(context: Context) -> DanmakuView {
        controller.startTimer()
        return controller.view
    }

    func updateUIView(_ uiView: DanmakuView, context: Context) {}

    static func dismantleUIView(_ uiView: DanmakuView, coordinator: ()) {
        uiView.pause()
    }
    #endif
}

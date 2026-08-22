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
/// 为什么不用内核弹幕：Erika DFM+ 的滑窗重放是非单调的——窗口前移让"过去"的
/// 轨道占用变少，之前被丢弃的弹幕会追认回轨道，挤掉在屏弹幕的轨道偏好，
/// 表现为窗口完全不动也跳轨。DanmakuRenderKit 的轨道模型是入轨时「追击判定」、
/// 入轨后不换轨，结构上杜绝这类问题。**不支持内核弹幕的内核（如 libmpv）
/// 只能走这条路**，`PlaybackController` 会强制它。
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
    }

    var engineProvider: () -> (any PlaybackEngine)?
    /// 真实播放状态（playing/buffering 由内核事件驱动，不靠媒体时间猜——
    /// 24fps 视频配 30Hz 采样会每隔一次看到 delta=0，时间猜测会以 ~15Hz
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
    /// 下一条待出场弹幕的下标（comments 已按 time 排序）。
    private var pointer = 0
    /// 匹配返回的时间轴校正（dandanplay shift），与 HUD 全局偏移分开工。
    private var trackOffsetSeconds: Double = 0
    private var timer: Timer?
    private var lastMediaSample: Double?
    private var viewPausedBySync = false
    private var fontSize: CGFloat = 25

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
        resync()
    }

    func clear() {
        comments = []
        pointer = 0
        lastMediaSample = nil
        view.clean()
    }

    func reset() {
        clear()
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
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return (payload.comments ?? []).compactMap { item in
            guard item.time.isFinite, item.time >= 0, !item.content.isEmpty else { return nil }
            let mode: Comment.Mode
            switch item.type {
            case 5: mode = .top
            case 4: mode = .bottom
            default: mode = .scroll
            }
            return Comment(time: item.time, mode: mode,
                           color: UInt32(item.color ?? 0xFF_FF_FF) & 0xFF_FF_FF,
                           text: item.content)
        }
    }

    // MARK: - 偏好

    func update(_ transform: (inout Preferences) -> Void) {
        var next = preferences
        transform(&next)
        let offsetChanged = next.offsetSeconds != preferences.offsetSeconds
        preferences = next
        applyPreferences(to: view)
        if offsetChanged { resync() }
    }

    private func applyPreferences(to view: DanmakuView) {
        let p = preferences
        view.displayArea = CGFloat(max(0.1, min(1, p.displayArea)))
        view.enableFloatingDanmaku = !p.blockScroll
        view.enableTopDanmaku = !p.blockTop
        view.enableBottomDanmaku = !p.blockBottom
        view.isOverlap = p.allowStacking
        view.trackHeight = fontSize * 1.4
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

    func startTimer() {
        guard timer == nil else { return }
        // Timer 本来就在主线程 runloop 上跑，直接 assumeIsolated 进 tick，
        // 不再每拍包一个 Task（30Hz 的分配 + 调度延迟都是白付的）。
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
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
        if delta < -0.5 || delta > 2.0 {
            // seek：媒体时间跳变，清屏重同步。
            resync()
            return
        }
        if viewPausedBySync { return }
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
    private func resync() {
        guard preferences.enabled, let engine = engineProvider() else { return }
        view.stop()
        view.play()
        viewPausedBySync = false
        let now = effectiveSeconds(mediaSeconds(engine))
        pointer = comments.firstIndex { $0.time > now } ?? comments.count
        lastMediaSample = nil
        startTimer()
    }

    private func spawnUpTo(_ mediaSeconds: Double) {
        let threshold = effectiveSeconds(mediaSeconds)
        while pointer < comments.count, comments[pointer].time <= threshold {
            view.shoot(danmaku: makeModel(for: comments[pointer]))
            pointer += 1
        }
    }

    private func makeModel(for comment: Comment) -> DanmakuCellModel {
        OverlayDanmakuModel(comment: comment, fontSize: fontSize)
    }
}

// MARK: - Cell

/// 单条弹幕的模型：文本 / 颜色 / 字号 / 类型 / 停留时长，尺寸预测量。
final class OverlayDanmakuModel: DanmakuCellModel {
    let comment: DanmakuOverlayController.Comment
    let font: PlatformFont
    let color: PlatformColor
    let size: CGSize
    let identifier: String
    let displayTime: Double
    let type: DanmakuCellType
    var track: UInt?

    init(comment: DanmakuOverlayController.Comment, fontSize: CGFloat) {
        self.comment = comment
        #if os(macOS)
        font = NSFont.systemFont(ofSize: fontSize)
        color = NSColor(calibratedRed: CGFloat((comment.color >> 16) & 0xFF) / 255,
                        green: CGFloat((comment.color >> 8) & 0xFF) / 255,
                        blue: CGFloat(comment.color & 0xFF) / 255, alpha: 1)
        #else
        font = UIFont.systemFont(ofSize: fontSize)
        color = UIColor(red: CGFloat((comment.color >> 16) & 0xFF) / 255,
                        green: CGFloat((comment.color >> 8) & 0xFF) / 255,
                        blue: CGFloat(comment.color & 0xFF) / 255, alpha: 1)
        #endif
        identifier = "\(comment.time)#\(comment.text)"
        displayTime = comment.mode == .scroll ? 10 : 5
        switch comment.mode {
        case .scroll: type = .floating
        case .top: type = .top
        case .bottom: type = .bottom
        }
        let attributed = NSAttributedString(string: comment.text, attributes: [.font: font])
        var measured = attributed.size()
        // 描边在字形外扩，测量宽度不够会在 cell 边缘截字。
        measured.width += 6
        size = measured
    }

    var cellClass: DanmakuCell.Type { OverlayDanmakuCell.self }

    func isEqual(to cellModel: DanmakuCellModel) -> Bool {
        guard let other = cellModel as? OverlayDanmakuModel else { return false }
        return identifier == other.identifier
    }
}

/// 单条弹幕的绘制。macOS 关键点有二：
/// 1. DanmakuAsyncLayer 给的是裸 CGContext，`NSAttributedString.draw` 需要
///    先包 NSGraphicsContext.current，否则画进空气（上游 Mac 示例同款）。
/// 2. 描边用**两遍绘制**：正 strokeWidth 纯描边一遍 + 填充一遍。macOS 对
///    负 strokeWidth（描边+填充一次画）的渲染有重影/毛刺类毛病，上游因此
///    也是两遍。
final class OverlayDanmakuCell: DanmakuCell {
    override func displaying(_ context: CGContext, _ size: CGSize, _ isCancelled: Bool) {
        guard !isCancelled, let model = model as? OverlayDanmakuModel else { return }
        #if os(macOS)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        #endif
        let text = NSString(string: model.comment.text)
        let fill: [NSAttributedString.Key: Any] = [
            .font: model.font,
            .foregroundColor: model.color,
        ]
        var stroke = fill
        stroke[.strokeColor] = PlatformColor.black.withAlphaComponent(0.9)
        // 正值 = 只画描边不填充（负值在 macOS 上单次混合绘制有渲染毛病）。
        stroke[.strokeWidth] = 3
        text.draw(at: .zero, withAttributes: stroke)
        text.draw(at: .zero, withAttributes: fill)
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
    #else
    func makeUIView(context: Context) -> DanmakuView {
        controller.startTimer()
        return controller.view
    }

    func updateUIView(_ uiView: DanmakuView, context: Context) {}
    #endif
}

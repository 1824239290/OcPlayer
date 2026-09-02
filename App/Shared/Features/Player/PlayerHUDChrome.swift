import PlaybackKit
import Foundation
import Observation
import SwiftUI

#if os(macOS)
import AppKit
#endif

enum PlayerHUDPalette {
    static let primary = Color.white
    static let secondary = Color.white.opacity(0.76)
    static let tertiary = Color.white.opacity(0.5)
    static let panelBackground = Color.black.opacity(0.72)
    static let outline = Color.white.opacity(0.16)
}

/// 静态 Glass 承载层：没有固定不透明底色，统一从已经压暗的画面取样。
struct PlayerHUDGlassSurface<SurfaceShape: Shape, Content: View>: View {
    let shape: SurfaceShape
    let content: Content

    init(in shape: SurfaceShape, @ViewBuilder content: () -> Content) {
        self.shape = shape
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    shape.stroke(PlayerHUDPalette.outline, lineWidth: 0.75)
                }
        }
    }
}

/// 只有真实 Button 使用 interactive Glass。
struct PlayerHUDGlassIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    private var side: CGFloat {
        #if os(iOS)
        44
        #else
        42
        #endif
    }

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, iOS 26.0, *) {
            button
                .glassEffect(
                    .regular.interactive(),
                    in: Circle()
                )
        } else {
            button
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().stroke(PlayerHUDPalette.outline, lineWidth: 0.75)
                }
        }
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PlayerHUDPalette.primary)
                .frame(width: side, height: side)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// 信息、错误和调试内容需要绝对稳定的对比度，不参与视频取样。
struct PlayerHUDPanel<SurfaceShape: Shape, Content: View>: View {
    let shape: SurfaceShape
    let content: Content

    init(in shape: SurfaceShape, @ViewBuilder content: () -> Content) {
        self.shape = shape
        self.content = content()
    }

    var body: some View {
        content
            .background(PlayerHUDPalette.panelBackground, in: shape)
            .overlay {
                shape.stroke(PlayerHUDPalette.outline, lineWidth: 0.75)
            }
    }
}

/// 单独的观察边界：打开信息面板时，position 更新不会让 PlayerScreen 和主 HUD 一起失效。
///
/// 由原「播放信息」（标题 / 时间 / 分辨率）和「播放统计」（裸计数行）合并而来：
/// 上半部是用户可读的播放元信息，底部「内核统计」保留 8 个原始计数器——0 和
/// 「不支持」在排查时是两回事，不做智能省略（见 `PlaybackStats`）。计数器来自
/// `latestStats`，它不是 observable 属性，整面板包一层 TimelineView 每秒强制重读，
/// 顺带让进度行跟上整秒；其余字段仍是 observable，变化即时反映。
struct PlayerHUDInfoPanel: View {
    @Environment(PlaybackController.self) private var controller

    let title: String
    let kicker: String
    let isNarrow: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            PlayerHUDPanel(in: RoundedRectangle(cornerRadius: 14)) {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(PlayerHUDPalette.primary)
                        if !kicker.isEmpty {
                            Text(kicker)
                                .font(.caption)
                                .foregroundStyle(PlayerHUDPalette.secondary)
                        }
                    }

                    PlayerHUDInfoSection(title: "播放") {
                        infoRow("状态", stateValue)
                        infoRow("进度", progressValue)
                        infoRow("倍速", playerHUDRateLabel(controller.rate))
                        infoRow("音量", volumeValue)
                        infoRow("章节", chaptersValue)
                    }

                    PlayerHUDInfoSection(title: "视频") {
                        if let params = controller.state.videoParams {
                            infoRow("分辨率", "\(params.width)×\(params.height) · \(PlayerVideoColorLabel.aspect(width: params.width, height: params.height))")
                            infoRow("动态范围", PlayerVideoColorLabel.dynamicRange(transfer: params.transfer))
                            infoRow(
                                "色彩",
                                "\(PlayerVideoColorLabel.primaries(params.primaries)) · \(PlayerVideoColorLabel.transfer(params.transfer))"
                            )
                        } else {
                            infoRow("分辨率", "—")
                        }
                        infoRow("画面", controller.state.hasSurface ? "已出画" : "未出画")
                    }

                    PlayerHUDInfoSection(title: "音频") {
                        infoRow("音轨", audioTrackValue)
                    }

                    PlayerHUDInfoSection(title: "字幕") {
                        infoRow("字幕", subtitleValue)
                    }

                    PlayerHUDInfoSection(title: "内核统计") {
                        statsGrid
                    }
                }
                .padding(14)
            }
            .frame(maxWidth: 340, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isNarrow ? 16 : 28)
        .padding(.top, isNarrow ? 70 : 82)
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("播放信息")
    }

    private var stateValue: String {
        var value = stateLabel
        // 与 PlayerScreen 的缓冲圈同一判定，避免「转圈但状态行不动」。
        if controller.state.isBuffering && controller.state.state == .playing {
            value += " · 缓冲中"
        }
        return value
    }

    private var stateLabel: String {
        switch controller.state.state {
        case .idle: "空闲"
        case .opening: "打开中"
        case .ready: "就绪"
        case .playing: "播放中"
        case .paused: "已暂停"
        case .stopped: "已停止"
        case .closed: "已关闭"
        case .error: "错误"
        }
    }

    private var progressValue: String {
        let timeline = controller.state.timeline
        var value = "\(playerHUDTimeLabel(timeline.displayPosition)) / \(playerHUDTimeLabel(timeline.duration))"
        if timeline.duration > .zero {
            value += " · \(Int((timeline.progress * 100).rounded()))%"
        }
        return value
    }

    private var volumeValue: String {
        if controller.muted { return "已静音" }
        return "\(Int((controller.volume * 100).rounded()))%"
    }

    private var chaptersValue: String {
        let chapters = controller.chapters
        return chapters.isEmpty ? "无" : "\(chapters.count) 章"
    }

    private var audioTrackValue: String {
        guard let track = controller.state.audioTracks.first(where: { $0.selected }) else {
            return "无独立音轨"
        }
        var value = track.displayTitle
        if let sampleRate = track.sampleRate, sampleRate > 0 {
            value += " · \(sampleRate / 1000) kHz"
        }
        return value
    }

    private var subtitleValue: String {
        guard let track = controller.state.subtitleTracks.first(where: { $0.selected }) else {
            return "关闭"
        }
        return track.source == .external ? "\(track.displayTitle)（外挂）" : track.displayTitle
    }

    private var statsGrid: some View {
        let stats = controller.engine?.latestStats ?? PlaybackStats()
        let items: [(label: String, value: UInt64)] = [
            ("解码", stats.decodedVideoFrames),
            ("渲染", stats.renderedVideoFrames),
            ("硬解", stats.hardwareVideoFrames),
            ("软解", stats.softwareVideoFrames),
            ("零拷贝", stats.zeroCopyVideoFrames),
            ("音频帧", stats.pushedAudioFrames),
            ("渲染失败", stats.renderFailures),
            ("音频失败", stats.audioFailures),
        ]
        return LazyVGrid(
            columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading),
            ],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(items, id: \.label) { item in
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label)
                        .font(.caption2)
                        .foregroundStyle(PlayerHUDPalette.tertiary)
                    Text(item.value.formatted())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PlayerHUDPalette.primary)
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(PlayerHUDPalette.tertiary)
            Spacer(minLength: 12)
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PlayerHUDPalette.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 信息面板的分区标题 + 行容器。
private struct PlayerHUDInfoSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PlayerHUDPalette.tertiary)
            content
        }
    }
}

/// `VideoParams` 的 AVCol 原始编码 → 可读标签。认不出的码退回原始值：
/// 宁可显示 "TRC 23" 也不猜错。
enum PlayerVideoColorLabel {
    /// HDR 判定只认传输函数：PQ（SMPTE 2084）与 HLG（ARIB STD-B67）。
    static func dynamicRange(transfer: UInt32) -> String {
        switch transfer {
        case 16: "HDR (PQ)"
        case 18: "HLG"
        default: "SDR"
        }
    }

    static func transfer(_ raw: UInt32) -> String {
        switch raw {
        case 1: "BT.1886"
        case 4: "Gamma 2.2"
        case 6: "BT.601"
        case 13: "sRGB"
        case 16: "PQ"
        case 18: "HLG"
        default: "TRC \(raw)"
        }
    }

    static func primaries(_ raw: UInt32) -> String {
        switch raw {
        case 1: "BT.709"
        case 6: "BT.601"
        case 9: "BT.2020"
        case 11: "DCI-P3"
        case 12: "Display P3"
        default: "原色 \(raw)"
        }
    }

    /// 宽高比标签：gcd 约成整比（16:9）优先，约出的数太大退小数（854×480 → 1.78:1）。
    static func aspect(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "—" }
        let divisor = gcd(width, height)
        let w = width / divisor
        let h = height / divisor
        if w <= 50, h <= 50 { return "\(w):\(h)" }
        return String(format: "%.2f:1", Double(width) / Double(height))
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var a = a
        var b = b
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return a
    }
}

func playerHUDRateLabel(_ value: Double) -> String {
    "\(value.formatted(.number.precision(.fractionLength(0...2))))×"
}

func playerHUDTimeLabel(_ duration: Duration) -> String {
    duration.formatted(
        .time(pattern: duration > .seconds(3600) ? .hourMinuteSecond : .minuteSecond)
    )
}

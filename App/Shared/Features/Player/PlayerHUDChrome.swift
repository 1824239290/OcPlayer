import ErikaKit
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

/// 单独的观察边界：打开信息卡时，position 更新不会让 PlayerScreen 和主 HUD 一起失效。
struct PlayerHUDInfoPanel: View {
    @Environment(PlaybackController.self) private var controller

    let title: String
    let kicker: String
    let isNarrow: Bool

    var body: some View {
        PlayerHUDPanel(in: RoundedRectangle(cornerRadius: 14)) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(PlayerHUDPalette.primary)
                if !kicker.isEmpty {
                    Text(kicker)
                        .font(.caption)
                        .foregroundStyle(PlayerHUDPalette.secondary)
                }
                Text(
                    "\(stateLabel) · \(playerHUDTimeLabel(controller.state.displayPosition)) / "
                        + playerHUDTimeLabel(controller.state.duration)
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PlayerHUDPalette.secondary)
                if let params = controller.state.videoParams {
                    Text("\(params.width)×\(params.height)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(PlayerHUDPalette.secondary)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: 320, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isNarrow ? 16 : 28)
        .padding(.top, isNarrow ? 70 : 82)
        .allowsHitTesting(false)
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
}

struct PlayerHUDStatsPanel: View {
    @Environment(PlaybackController.self) private var controller

    var body: some View {
        // engine.latestStats 不是 observable 属性，整棵面板只会跟着 state/其他属性
        // 变化才偶发刷新，数字常停在旧值。用 TimelineView 每秒强制重读一次。
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            PlayerHUDPanel(in: RoundedRectangle(cornerRadius: 14)) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(controller.statsLine())
                    Text(verbatim: "surface=\(controller.state.hasSurface) · \(videoDescription)")
                }
                .font(.caption2.monospaced())
                .foregroundStyle(PlayerHUDPalette.primary)
                .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.horizontal, 28)
        .padding(.top, 90)
        .allowsHitTesting(false)
    }

    private var videoDescription: String {
        controller.state.videoParams.map { "\($0.width)×\($0.height)" } ?? "-"
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

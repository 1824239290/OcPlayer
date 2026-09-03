import SwiftUI

/// iOS 画面手势（长按 2x / 横滑 seek / 左右半屏纵滑亮度音量）的纯逻辑。
/// 不碰 UIKit，方便在 macOS 测试靶上直接跑；UIKit 侧只在 PlayerScreen 的 iOS 分支。
enum PlayerPanGestureModel {
    enum Mode: Equatable {
        /// 横向拖动快进快退（拖动中只出预览，松手才 seek）。
        case seek
        /// 左半屏上滑增亮。
        case brightness
        /// 右半屏上滑增音量。
        case volume
    }

    /// 按主轴方向 + 起点落在哪半屏分类。宽高无效时返回 nil（不进任何模式）。
    static func mode(translation: CGSize, startX: CGFloat, width: CGFloat) -> Mode? {
        guard width > 1 else { return nil }
        if abs(translation.width) >= abs(translation.height) { return .seek }
        return startX < width / 2 ? .brightness : .volume
    }

    /// 横滑映射：满屏宽 = max(60s, 时长的 1/4)。纯比例映射在长片上一格跨半小时，
    /// 用 60s 兜底也让短视频不用拖满全屏。
    static func seekTarget(
        startSeconds: Double,
        translation: CGFloat,
        width: CGFloat,
        duration: Double
    ) -> Double {
        guard width > 1, duration > 0 else { return startSeconds }
        let fullSwipe = max(60, duration / 4)
        let delta = Double(translation / width) * fullSwipe
        return min(max(startSeconds + delta, 0), duration)
    }

    /// 纵滑映射：满屏高 = 全量程（0…1），上滑（translation 为负）增大。
    static func verticalTarget(start: Double, translation: CGFloat, extent: CGFloat) -> Double {
        guard extent > 1 else { return start }
        return min(max(start - Double(translation / extent), 0), 1)
    }

    static func fraction(seconds: Double, duration: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(seconds / duration, 0), 1)
    }

    /// 轻点判定：按压时长短、位移在 slop 内（单击 / 双击共用的前置条件）。
    static func isQuickTap(
        elapsed: TimeInterval,
        translation: CGSize,
        slop: CGFloat,
        maxDuration: TimeInterval
    ) -> Bool {
        elapsed < maxDuration
            && abs(translation.width) < slop
            && abs(translation.height) < slop
    }

    /// 双击判定：两击间隔落在窗口内。
    static func isDoubleTap(interval: TimeInterval, window: TimeInterval) -> Bool {
        interval >= 0 && interval <= window
    }
}

/// 一次滑动的全程状态（nil = 手指不在屏上 / 无活动手势）。
/// 拖动中每帧更新，驱动预览条与 OSD；松手按 mode 落盘。
struct PlayerPanSession: Equatable {
    let mode: PlayerPanGestureModel.Mode
    let startSeconds: Double
    let durationSeconds: Double
    /// 亮度 / 音量的起点（0…1）。
    var verticalStart: Double = 0
    var verticalValue: Double = 0
    /// seek 预览位置（秒），拖动中持续更新，松手才真正 seek。
    var previewSeconds: Double = 0
}

#if os(iOS)
/// 横滑 seek 的独立进度条：拖动期间单独浮在底部，HUD 保持原显隐（bilibili 式）。
struct PlayerSeekPreviewBar: View {
    let fraction: Double
    let targetSeconds: Double
    let durationSeconds: Double

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Text(
                    "\(playerHUDTimeLabel(.seconds(targetSeconds)))"
                        + " / \(playerHUDTimeLabel(.seconds(durationSeconds)))"
                )
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(PlayerHUDPalette.primary)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule()
                            .fill(.white)
                            .frame(width: max(0, min(1, fraction)) * proxy.size.width)
                    }
                }
                .frame(height: 4)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 64)
        }
        .allowsHitTesting(false)
        .transition(.section)
    }
}

/// 亮度 / 音量纵滑的 OSD 徽章：顶部居中，拖动期间实时反映当前值。
struct PlayerAdjustOSDBadge: View {
    let systemImage: String
    let value: Double

    var body: some View {
        PlayerHUDPanel(in: Capsule()) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule()
                            .fill(.white)
                            .frame(width: proxy.size.width * max(0, min(1, value)))
                    }
                }
                .frame(width: 84, height: 4)
                Text("\(Int((value * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(PlayerHUDPalette.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            .foregroundStyle(PlayerHUDPalette.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .fixedSize()
        .allowsHitTesting(false)
        .transition(.section)
    }
}
#endif

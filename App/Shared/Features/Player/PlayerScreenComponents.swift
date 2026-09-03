import PlaybackKit
import SwiftUI

/// 播放准备态的全屏 loading 层：解析地址中（转圈 + 标题 + 取消）/ 解析失败（错误 + 重试）。
/// 一处定义两处复用——RootView 的准备态覆盖层，与 PlayerScreen 内部 opening/idle 态。
struct PlayerLoadingLayer: View {
    let preparation: PlaybackPreparation
    /// 准备态（解析地址）时的取消入口；引擎 open 阶段（PlayerScreen 内部）传 nil，
    /// 那段由 PlaybackController 管，用户可点 HUD「×」走 closePlayer 退出。
    let onCancel: (() -> Void)?
    /// 失败态的重试入口；loading 态可传 nil。
    let onRetry: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                switch preparation {
                case .loading(let title):
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    if let onCancel {
                        PlayerGlassCancelButton(action: onCancel)
                    }
                case .failed(let title, let error):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.red)
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
                        if let onCancel {
                            PlayerGlassCancelButton(action: onCancel)
                        }
                        if let onRetry {
                            Button(action: onRetry) {
                                Label(UIStrings.retry, systemImage: "arrow.clockwise")
                                    .font(.callout.weight(.semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                    }
                }
            }
            .padding(30)
        }
    }
}

/// 液态玻璃取消按钮，loading 层 loading/failed 两态共用。
private struct PlayerGlassCancelButton: View {
    let action: () -> Void
    var body: some View {
        PlayerHUDGlassSurface(in: Capsule()) {
            Button("取消", action: action)
                .buttonStyle(.plain)
                .font(.callout.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
        }
    }
}

struct PlayerVideoSurface: View {
    let engine: (any PlaybackEngine)?
    let title: String
    let setupError: String?
    /// 关闭流程中置 false：停播到 dismiss 之间引擎已空，占位图（画中画样式
    /// 图标 + 标题）若照常渲染会裸露闪现，此时落到底层纯黑即可。
    var showsPlaceholder: Bool = true

    @ViewBuilder
    var body: some View {
        if let engine {
            // 画面视图由内核适配器自己造（attach / resize / 帧驱动都在它内部）。
            // 换片会换引擎实例，视图必须跟着引擎身份重建——SwiftUI 复用旧视图时
            // 新引擎不会 attach（无渲染循环 → 无状态事件 → UI 卡在 idle）。
            engine.makeSurfaceView()
                .id(ObjectIdentifier(engine))
                .ignoresSafeArea()
        } else if showsPlaceholder {
            VStack(spacing: 14) {
                Image(systemName: "play.rectangle.on.rectangle")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.white.opacity(0.5))
                Text(title)
                    .foregroundStyle(.white.opacity(0.7))
                if let setupError {
                    Text(setupError)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(.horizontal, 40)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(30)
        }
    }
}

struct PlayerPlaybackErrorBadge: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack {
            Spacer()
            PlayerHUDPanel(in: RoundedRectangle(cornerRadius: 18)) {
                HStack(spacing: 14) {
                    Label(controller.state.lastError ?? controller.setupError ?? "播放出错",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(PlayerHUDPalette.primary, Color.red)
                    Button(action: app.retryPlayback) {
                        Label(UIStrings.retry, systemImage: "arrow.clockwise")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(controller.lastRequest == nil || app.playbackPreparation != nil)
                }
                .padding(12)
            }
            .padding(.bottom, 140)
        }
    }
}

/// 长按右键临时 2 倍速的提示徽章（「▶▶ 2.0x」胶囊，对齐 bilibili 式样）。
/// 不挂在 HUD 里：加速期间 HUD 保持原显隐状态（可能整层隐藏），徽章独立浮在顶部中央。
/// 常挂载 + `.opacity` 切换——macOS 上 `.transition` 的移除不被动画化（见 PlayerScreen 注释）。
struct PlayerHoldFastForwardBadge: View {
    @Environment(PlaybackController.self) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isShowing: Bool { controller.isHoldFastForwarding }

    var body: some View {
        PlayerHUDPanel(in: Capsule()) {
            HStack(spacing: 6) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(String(format: "%.1fx", controller.rate))
                    .font(.system(size: 14, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(PlayerHUDPalette.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .opacity(isShowing ? 1 : 0)
        .scaleEffect(isShowing ? 1 : 0.92)
        .motionAnimation(Motion.standard, value: isShowing, reduceMotion: reduceMotion)
        .allowsHitTesting(false)
        .accessibilityHidden(!isShowing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("2 倍速快进中")
    }
}

struct PlayerScreenshotToast: View {
    let message: String?

    var body: some View {
        VStack {
            Spacer()
            if let message {
                PlayerHUDPanel(in: Capsule()) {
                    Text(message)
                        .font(.callout)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .foregroundStyle(PlayerHUDPalette.primary)
                }
                .padding(.bottom, 120)
            }
        }
        .allowsHitTesting(false)
    }
}

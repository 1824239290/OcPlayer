import ErikaKit
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
                        Button("取消", action: onCancel)
                            .buttonStyle(.bordered)
                            .tint(.white.opacity(0.6))
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
                            Button("取消", action: onCancel)
                                .buttonStyle(.bordered)
                                .tint(.white.opacity(0.6))
                        }
                        if let onRetry {
                            Button(action: onRetry) {
                                Label("重试", systemImage: "arrow.clockwise")
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

struct PlayerVideoSurface: View {
    let engine: ErikaEngine?
    let title: String
    let setupError: String?

    @ViewBuilder
    var body: some View {
        if let engine {
            // MetalHostView holds an engine by identity. Rebuild the host whenever
            // playback creates a new engine so the new surface is attached.
            VideoSurfaceView(engine: engine)
                .id(ObjectIdentifier(engine))
                .ignoresSafeArea()
        } else {
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
                        Label("重试", systemImage: "arrow.clockwise")
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

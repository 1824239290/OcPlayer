import ErikaKit
import SwiftUI

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
                    .disabled(controller.lastRequest == nil || app.isPlaybackOpening)
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

import SwiftUI

/// 按钮按压的子阶段，从调用方视角看。
public enum ActionPhase: Equatable, Sendable {
    case idle
    case busy
    case done
}

/// 卡片的主行动按钮。标签**原地**变形——文字、转圈、对勾——所以按钮永远不会
/// 改变尺寸或位置。
///
/// 转圈是手画的（`MiniSpinner`）而不是 `ProgressView`：系统转圈的颜色在
/// macOS 上改不动，压在品牌橙的填充上会是一团糊的灰。
public struct PrimaryActionButton: View {
    public let title: String
    public let phase: ActionPhase
    public let isEnabled: Bool
    public let action: () -> Void

    @State private var isHovering = false

    public init(title: String, phase: ActionPhase, isEnabled: Bool, action: @escaping () -> Void) {
        self.title = title
        self.phase = phase
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack { label }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                // 深色字压在品牌橙上：两种外观下都成立（橙色够亮）。
                .foregroundStyle(.black.opacity(0.86))
                .background {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(fill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: 0.8)
                        .blendMode(.plusLighter)
                }
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.52)
        .saturation(isEnabled ? 1 : 0.5)
        .shadow(
            color: glowColor.opacity(isEnabled ? (isHovering ? 0.55 : 0.30) : 0),
            radius: isHovering ? 26 : 15,
            y: 8
        )
        .scaleEffect(isHovering && isEnabled ? 1.014 : 1)
        .motion(Motion.glass, value: isHovering)
        .motion(Motion.lift, value: phase)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var label: some View {
        switch phase {
        case .busy:
            MiniSpinner()
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .idle:
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .transition(.opacity)
        }
    }

    private var fill: LinearGradient {
        switch phase {
        case .done:
            LinearGradient(
                colors: [Color(red: 0.55, green: 0.90, blue: 0.62), Color(red: 0.28, green: 0.74, blue: 0.47)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            LinearGradient(
                colors: [LoginWallStyle.accent, LoginWallStyle.accentDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var glowColor: Color {
        phase == .done ? Color(red: 0.35, green: 0.85, blue: 0.55) : LoginWallStyle.accent
    }
}

/// 不定转圈，手画以便跟着按钮的墨色走（`ProgressView` 在 macOS 上做不到）。
public struct MiniSpinner: View {
    public var color: Color
    public var size: CGFloat

    @State private var isSpinning = false

    public init(color: Color = .black, size: CGFloat = 17) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.72)
            .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(isSpinning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isSpinning)
            .onAppear { isSpinning = true }
    }
}

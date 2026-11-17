import SwiftUI

/// 玻璃输入框：它表现得像卡片的一部分——聚焦时自己变亮、描边转成品牌橙，
/// 而不是画系统那圈聚焦环。
///
/// 配色全部走语义色（`.primary` 的百分比）而不是硬编码白：日间模式是浅色玻璃上
/// 的深色字，夜间是深色玻璃上的白字，同一套透明度两边都成立。
public struct GlassField: View {
    public let icon: String
    public let placeholder: String
    @Binding public var text: String
    public var isSecure: Bool
    public var onSubmit: (() -> Void)?

    @FocusState private var isFocused: Bool
    @State private var isRevealed = false

    private let cornerRadius: CGFloat = 12

    public init(
        icon: String,
        placeholder: String,
        text: Binding<String>,
        isSecure: Bool = false,
        onSubmit: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.placeholder = placeholder
        self._text = text
        self.isSecure = isSecure
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isFocused ? AnyShapeStyle(LoginWallStyle.accent) : AnyShapeStyle(.tertiary))
                .frame(width: 17)

            field
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .tint(LoginWallStyle.accent)
                .focused($isFocused)
                .onSubmit { onSubmit?() }

            if isSecure {
                Button {
                    isRevealed.toggle()
                    isFocused = true
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(isRevealed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isRevealed ? "隐藏密码" : "显示密码")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
        .background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.primary.opacity(isFocused ? 0.10 : 0.055))
        }
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(borderStyle, lineWidth: 1)
        }
        .shadow(color: LoginWallStyle.accent.opacity(isFocused ? 0.22 : 0), radius: 9, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .onTapGesture { isFocused = true }
        .motion(Motion.fast, value: isFocused)
    }

    @ViewBuilder
    private var field: some View {
        if isSecure && !isRevealed {
            SecureField("", text: $text, prompt: prompt)
        } else {
            TextField("", text: $text, prompt: prompt)
        }
    }

    private var prompt: Text {
        Text(placeholder).foregroundStyle(.tertiary)
    }

    private var borderStyle: AnyShapeStyle {
        if isFocused {
            AnyShapeStyle(
                LinearGradient(
                    colors: [LoginWallStyle.accent.opacity(0.85), LoginWallStyle.accentDeep.opacity(0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            AnyShapeStyle(.primary.opacity(0.11))
        }
    }
}

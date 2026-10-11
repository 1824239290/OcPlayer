import SwiftUI

/// 胶囊搜索框：放大镜 + 输入 + 清空钮 + 胶囊底/描边，聚焦时放大镜与描边走 accent。
///
/// 资源搜索页与弹幕选择 sheet 曾各写一份同构实现（连清空钮的图标与三级色都一样），
/// 只是聚焦高亮一份有一份没有——统一后聚焦高亮全站生效（调用方给一个
/// `@FocusState` Bool 即可，不需要聚焦语义时传 `.constant(false)`）。
public struct CapsuleSearchField: View {
    public let placeholder: String
    @Binding public var text: String
    public var focus: FocusState<Bool>.Binding
    public var onSubmit: () -> Void
    public var onChange: () -> Void

    public init(
        _ placeholder: String,
        text: Binding<String>,
        focus: FocusState<Bool>.Binding,
        onSubmit: @escaping () -> Void = {},
        onChange: @escaping () -> Void = {}
    ) {
        self.placeholder = placeholder
        _text = text
        self.focus = focus
        self.onSubmit = onSubmit
        self.onChange = onChange
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(focus.wrappedValue ? Color.accentColor : Color.secondary)
                .font(.callout)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused(focus)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                #endif
                .autocorrectionDisabled()
                .onSubmit(onSubmit)
                .onChange(of: text) { _, _ in onChange() }
            if !text.isEmpty {
                Button {
                    text = ""
                    onChange()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                focus.wrappedValue ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                lineWidth: 0.5
            )
        )
    }
}

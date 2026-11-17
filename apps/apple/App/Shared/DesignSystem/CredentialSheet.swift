import SwiftUI

/// 地址与凭证录入共用 Bangumi 风格的固定顶栏、可滚动表单与底部操作。
struct FormSheetShell<Content: View, ConfirmLabel: View>: View {
    let title: String
    var symbol = "slider.horizontal.3"
    var subtitle: String? = nil
    var size: AppSheetSize = .form
    var isSubmitting = false
    var confirmEnabled = true
    var onConfirm: () -> Void
    @ViewBuilder var confirmLabel: () -> ConfirmLabel
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            AppSheetHeader(title: title, symbol: symbol, subtitle: subtitle, canDismiss: !isSubmitting)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .disabled(isSubmitting)
            }
            .scrollDismissesKeyboard(.interactively)
            AppSheetDivider()
            AppSheetFooter {
                Button("取消") { dismiss() }
                    .buttonStyle(AppSheetButtonStyle())
                    .disabled(isSubmitting)
            } actions: {
                Button(action: onConfirm) { confirmLabel() }
                    .buttonStyle(AppSheetButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!confirmEnabled || isSubmitting)
            }
        }
        .appSheetSurface(size: size)
        .interactiveDismissDisabled(isSubmitting)
    }
}

/// 「标签 + 输入框 + 说明文字」字段组（URL / 文本 / 密码三态）。
struct LabeledCredentialField: View {
    enum Kind {
        case url
        case plain
        case secure
    }

    let label: String
    @Binding var text: String
    var prompt: String
    var caption: String?
    var kind: Kind = .plain
    /// iOS 键盘类型由 kind 决定；用户名类字段传 .username。
    #if os(iOS)
    var textContentType: UITextContentType?
    #else
    var textContentType: NSTextContentType?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline.weight(.semibold))
            Group {
                switch kind {
                case .url, .plain:
                    TextField("", text: $text, prompt: Text(prompt))
                        .textContentType(textContentType ?? (kind == .url ? .URL : nil))
                case .secure:
                    SecureField("", text: $text, prompt: Text(prompt))
                        .textContentType(textContentType ?? .password)
                }
            }
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .textFieldStyle(AppSheetTextFieldStyle())
            .frame(maxWidth: .infinity)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

import SwiftUI

/// 地址 / 凭证录入弹窗的统一外壳与字段组。
///
/// 「NavigationStack + ScrollView + 标签/输入/说明字段组 + 取消/确认 toolbar +
/// macOS 520pt 定宽」这套骨架曾逐行同构三份（MoviePilot 服务器、弹幕网关、
/// 添加服务器地址），新增录入弹窗从这里拼，别再抄。
struct FormSheetShell<Content: View, ConfirmLabel: View>: View {
    let title: String
    /// 确认钮可用性（表单校验）与动作。
    var confirmEnabled: Bool = true
    var onConfirm: () -> Void
    @ViewBuilder var confirmLabel: () -> ConfirmLabel
    @ViewBuilder var content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: onConfirm) {
                        confirmLabel()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!confirmEnabled)
                }
            }
        }
        #if os(macOS)
        .frame(width: 520)
        #endif
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
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: .infinity)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

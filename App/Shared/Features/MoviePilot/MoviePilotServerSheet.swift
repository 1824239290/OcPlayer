import MoviePilotKit
import SwiftUI

/// MoviePilot 服务器与账号编辑弹窗：「保存并登录」当场验证，
/// 失败文案内联展示且不关弹窗（与弹幕网关弹窗的「先保存后生效」不同——
/// MoviePilot 的凭据对不对只有登录了才知道）。
/// 密码不回显：退出登录后本地已清空，登录中也无需带回。
struct MoviePilotServerSheet: View {
    @Environment(MoviePilotCoordinator.self) private var moviepilot
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL: String
    @State private var username: String
    @State private var password = ""

    init(initialURL: String, initialUsername: String) {
        _serverURL = State(initialValue: initialURL)
        _username = State(initialValue: initialUsername)
    }

    var body: some View {
        @Bindable var mp = moviepilot
        return FormSheetShell(
            title: "MoviePilot",
            symbol: "server.rack",
            subtitle: "连接服务器并登录账号。",
            size: AppSheetSize(minHeight: 460, idealHeight: 540),
            isSubmitting: mp.isLoggingIn,
            confirmEnabled: isValid && !mp.isLoggingIn,
            onConfirm: {
                Task {
                    let error = await mp.login(
                        serverURLString: serverURL,
                        username: username,
                        password: password
                    )
                    if error == nil {
                        dismiss()
                    }
                }
            },
            confirmLabel: {
                if mp.isLoggingIn {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("保存并登录")
                }
            }
        ) {
            LabeledCredentialField(
                label: "服务器地址",
                text: $serverURL,
                prompt: "http://192.168.1.10:3000",
                caption: "http(s) 根地址，局域网 IP 部署可直接 http。",
                kind: .url
            )

            Divider()

            LabeledCredentialField(
                label: "用户名",
                text: $username,
                prompt: "登录账号",
                textContentType: .username
            )
            LabeledCredentialField(
                label: "密码",
                text: $password,
                prompt: "登录密码",
                caption: "用于登录 MoviePilot；只有开启“记住密码”时才会保存密码。",
                kind: .secure
            )

            if let error = mp.authError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    private var isValid: Bool {
        MoviePilotStore.normalizedURL(from: serverURL) != nil
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

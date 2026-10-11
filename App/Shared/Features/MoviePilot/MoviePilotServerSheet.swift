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

            VStack(alignment: .leading, spacing: 8) {
                Text("账号")
                    .font(.subheadline.weight(.semibold))
                TextField("", text: $username, prompt: Text("用户名"))
                    .textContentType(.username)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                SecureField("", text: $password, prompt: Text("密码"))
                    .textContentType(.password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Text("token 有效期 8 天；密码只存本机，过期后自动用它静默续登，不上传任何第三方。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = mp.authError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        #if os(macOS)
        .frame(height: 400)
        #endif
    }

    private var isValid: Bool {
        MoviePilotStore.normalizedURL(from: serverURL) != nil
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

import SwiftUI

/// 登录流程：① 服务器地址 → ② Quick Connect（主）+ 账号密码（兜底）。
///
/// Quick Connect 在服务器确认后自动开始轮询；它没开 / 超时也不挡密码登录。
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            HStack {
                Spacer()
                card
                Spacer()
            }
            Spacer(minLength: 40)
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(.background)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 22) {
            // 头部
            VStack(alignment: .leading, spacing: 6) {
                Label("OcPlayer", systemImage: "cat.fill")
                    .font(.largeTitle.weight(.bold))
                Text("连接你的 Jellyfin 媒体库")
                    .foregroundStyle(.secondary)
            }

            if app.loginSession == nil {
                serverForm
                    .transition(.opacity)
            } else {
                loginForms
                    .transition(.opacity)
            }

            if let error = app.onboardingError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(28)
        .frame(width: 460)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 30, y: 12)
        .motionAnimation(.easeInOut(duration: 0.2), value: app.loginSession != nil, reduceMotion: reduceMotion)
        .motionAnimation(.easeInOut(duration: 0.2), value: app.onboardingError, reduceMotion: reduceMotion)
    }

    // MARK: 第一步：服务器地址

    private var serverForm: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 12) {
            Text("服务器地址").font(.headline)
            TextField("例如 192.168.1.10:8096", text: $serverAddress)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await connect() } }
            Text("局域网地址不带 http:// 也行；https 前缀会保留。")
                .font(.caption)
                .foregroundStyle(.tertiary)
            HStack {
                Spacer()
                Button {
                    Task { await connect() }
                } label: {
                    if app.isProbingServer {
                        ProgressView().controlSize(.small).padding(.horizontal, 8)
                    } else {
                        Text("连接")
                    }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(serverAddress.trimmingCharacters(in: .whitespaces).isEmpty || app.isProbingServer)
            }

            HStack {
                Spacer()
                Button("先不登录，直接用播放器") { app.skipLogin() }
                    .font(.callout)
            }
        }
    }

    // MARK: 第二步：Quick Connect + 账号密码

    private var loginForms: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 服务器已确认的条子
            HStack(spacing: 10) {
                Circle().fill(.green).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.loginSession?.serverName ?? "Jellyfin")
                        .font(.headline)
                    Text(app.loginSession?.baseURL.absoluteString ?? "")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("换个服务器") { app.resetOnboarding() }
                    .font(.callout)
            }
            .padding(12)
            .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            quickConnectPanel

            divider

            VStack(alignment: .leading, spacing: 10) {
                Text("或用账号密码登录").font(.headline)
                TextField("用户名", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .onSubmit { Task { await submitPassword() } }
                SecureField("密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await submitPassword() } }
                HStack {
                    Spacer()
                    Button {
                        Task { await submitPassword() }
                    } label: {
                        if app.isAuthenticating {
                            ProgressView().controlSize(.small).padding(.horizontal, 8)
                        } else {
                            Text("登录")
                        }
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(username.isEmpty || app.isAuthenticating)
                }
            }
        }
    }

    private var quickConnectPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Connect").font(.headline)
            if let code = app.quickConnectCode {
                VStack(spacing: 8) {
                    Text(code)
                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                        .kerning(6)
                    Text("在手机 / 网页端 Jellyfin 的「Quick Connect」里输入这串代码确认")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("等待确认…").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
                .transition(.opacity)
            } else {
                HStack {
                    Text("正在向服务器申请配对码…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    ProgressView().controlSize(.small)
                }
                .padding(16)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
                .transition(.opacity)
            }
        }
        .motionAnimation(.easeInOut(duration: 0.2), value: app.quickConnectCode, reduceMotion: reduceMotion)
    }

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(.separator).frame(height: 1)
            Text("或").font(.caption).foregroundStyle(.tertiary)
            Rectangle().fill(.separator).frame(height: 1)
        }
    }

    // MARK: - 动作

    private func connect() async {
        await app.connectServer(serverAddress)
    }

    private func submitPassword() async {
        await app.signIn(username: username, password: password)
    }
}

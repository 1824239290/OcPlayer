import JellyfinKit
import SwiftUI

/// 登录流程：① 服务器地址 → ② Quick Connect（主）+ 账号密码（兜底）。
///
/// Quick Connect 在服务器确认后自动开始轮询；它没开 / 超时也不挡密码登录。
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var serverAddress = ""
    /// 协议选择:HTTP / HTTPS。控制服务器 baseURL 的 scheme。
    @State private var serverScheme: JellyfinServerScheme = .http
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
        // 常规宽度（Mac/iPad）保最小尺寸；紧凑宽度（iPhone）不设 min，让卡片自适应屏宽。
        .frame(minWidth: sizeClass == .compact ? nil : 720,
               minHeight: sizeClass == .compact ? nil : 560)
        .background(.background)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 22) {
            // 头部
            VStack(alignment: .leading, spacing: 6) {
                Label("OcPlayer", systemImage: "cat.fill")
                    .font(.largeTitle.weight(.bold))
                Text("连接 Jellyfin / Emby 媒体库")
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
        // 常规宽度锁 460pt；紧凑宽度改为上限 460 并留屏幕边缘留白，窄机上不会溢出。
        .frame(maxWidth: 460)
        .padding(.horizontal, sizeClass == .compact ? 16 : 0)
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
            savedServersSection

            Text("服务器地址").font(.headline)
            TextField("例如 192.168.1.10:8096", text: $serverAddress)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await connect() } }
                // 手写 http(s):// 前缀时连接以手动为准（见下方提示），
                // 让 segmented Picker 同步到实际生效的协议，避免 UI 显示与行为脱节。
                .onChange(of: serverAddress) { _, newValue in
                    let lower = newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if lower.hasPrefix("https://") {
                        serverScheme = .https
                    } else if lower.hasPrefix("http://") {
                        serverScheme = .http
                    }
                }
            Text("可以不打前缀;选择器决定协议,手动打了 http:// 或 https:// 则以手动为准。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            // 协议选择:选哪个,服务器所有请求(API / 图片 / 播放流)统一走哪个。
            // 手动输入 http:// 或 https:// 前缀会覆盖这里的选择。
            Picker("协议", selection: $serverScheme) {
                Text("HTTP").tag(JellyfinServerScheme.http)
                Text("HTTPS").tag(JellyfinServerScheme.https)
            }
            .pickerStyle(.segmented)
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
                    Text(app.loginSession?.serverName ?? "服务器")
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

            // Emby 没有 Quick Connect：只显示账号密码，不渲染 QC 面板和分隔条。
            if app.loginSession?.supportsQuickConnect != false {
                quickConnectPanel
                divider
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(app.loginSession?.supportsQuickConnect == false ? "账号密码登录" : "或用账号密码登录")
                    .font(.headline)
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
            // 三个终态各有落点。原来只有「有码 / 没码」两种，服务器把 QC 关掉时
            // 这块会永远转着「正在申请配对码…」，同时卡片底部又冒一条红色报错——
            // 两句说的是同一件事，而转圈那句还是错的。
            if let reason = app.quickConnectError {
                quickConnectPanelBox {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        Text(reason)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button(UIStrings.retry) { Task { await app.startQuickConnect() } }
                            .font(.callout)
                    }
                }
            } else if let code = app.quickConnectCode {
                quickConnectPanelBox {
                    VStack(spacing: 8) {
                        Text(code)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .kerning(6)
                            .textSelection(.enabled)
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
                }
            } else {
                quickConnectPanelBox {
                    HStack {
                        Text("正在向服务器申请配对码…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .motionAnimation(.easeInOut(duration: 0.2), value: app.quickConnectCode, reduceMotion: reduceMotion)
        .motionAnimation(.easeInOut(duration: 0.2), value: app.quickConnectError, reduceMotion: reduceMotion)
    }

    /// 三种状态共用同一个盒子，切换时框体不跳。
    private func quickConnectPanelBox<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
            .transition(.opacity)
    }

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(.separator).frame(height: 1)
            Text("或").font(.caption).foregroundStyle(.tertiary)
            Rectangle().fill(.separator).frame(height: 1)
        }
    }

    // MARK: 已保存的服务器

    /// 登录页上方的档案列表：token 还在的一键重连，失效的探活后进密码登录。
    /// 数据来自 `ServerStore`——登出不删档案，这里就是「记忆」的展示面。
    @ViewBuilder
    private var savedServersSection: some View {
        let profiles = app.store.profiles
        if !profiles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("已保存的服务器").font(.headline)
                ForEach(profiles) { profile in
                    savedServerRow(profile)
                }
            }
        }
    }

    private func savedServerRow(_ profile: ServerProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: profile.kind == .emby ? "tv" : "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(profile.serverName).font(.callout.weight(.medium))
                    Text(profile.kind.displayName)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    // 档案无 token = 上次退出过登录，点它走密码登录而不是一键切。
                    if app.store.token(for: profile) == nil {
                        Text("需重新登录")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(profile.baseURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("连接") {
                Task { await app.switchToServer(profile) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 动作

    private func connect() async {
        await app.connectServer(serverAddress, scheme: serverScheme)
    }


    private func submitPassword() async {
        await app.signIn(username: username, password: password)
    }
}

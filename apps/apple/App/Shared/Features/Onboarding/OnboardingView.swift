import AppDesignKit
import JellyfinKit
import SwiftUI

/// 服务器连接与登录流程。欢迎视觉只用本地矢量绘制，首次使用也完整可见。
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var serverAddress = ""
    /// 协议选择:HTTP / HTTPS。控制服务器 baseURL 的 scheme。
    @State private var serverScheme: ServerScheme = .http
    @State private var username = ""
    @State private var password = ""
    @State private var quickConnectExpanded = false
    @FocusState private var serverFocused: Bool
    @FocusState private var usernameFocused: Bool
    @FocusState private var passwordFocused: Bool

    private enum InputField: Hashable { case server, username, password }

    private var focusedInput: InputField? {
        if passwordFocused { return .password }
        if usernameFocused { return .username }
        if serverFocused { return .server }
        return nil
    }

    /// 报错时抖一下卡片。用递增计数当触发器（见 `ShakeModifier`）。
    @State private var shakeTrigger = 0

    var body: some View {
        ZStack {
            OnboardingBackdrop().ignoresSafeArea()
            content
        }
        .onChange(of: app.onboardingError) { _, newValue in
            if newValue != nil { shakeTrigger += 1 }
        }
        .onChange(of: app.loginSession != nil) { _, _ in
            quickConnectExpanded = false
        }
    }

    // MARK: - 自适应欢迎页

    private var content: some View {
        GeometryReader { proxy in
            let wide = proxy.size.width >= 960 && !dynamicTypeSize.isAccessibilitySize
            ScrollViewReader { scroll in
                ScrollView {
                    Group {
                        if wide {
                            HStack(alignment: .center, spacing: 56) {
                                OnboardingWelcomeView(compact: false)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                card
                                    .frame(width: 420)
                            }
                            .frame(maxWidth: 1080)
                            .padding(.horizontal, 48)
                            .padding(.vertical, 48)
                        } else {
                            VStack(spacing: 28) {
                                OnboardingWelcomeView(compact: true)
                                card
                                    .frame(maxWidth: 460)
                            }
                            .frame(maxWidth: 520)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 28)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
                #if os(iOS)
                .onChange(of: focusedInput) { _, _ in
                    revealFocusedInput(using: scroll)
                }
                .onChange(of: proxy.size.height) { _, _ in
                    revealFocusedInput(using: scroll)
                }
                #endif
            }
        }
    }

    private func revealFocusedInput(using scroll: ScrollViewProxy) {
        guard let focusedInput else { return }
        withAnimation(reduceMotion ? nil : Motion.standard) {
            scroll.scrollTo(focusedInput, anchor: .center)
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if app.loginSession == nil {
                serverForm
                    .transition(.section)
            } else {
                loginForms
                    .transition(.section)
            }

            if let error = app.onboardingError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(red: 1, green: 0.46, blue: 0.42))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(sizeClass == .compact ? 22 : 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(colorScheme == .dark
                      ? Color(red: 0.095, green: 0.09, blue: 0.11)
                      : Color.white.opacity(0.92))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.06), radius: 32, y: 16)
        .motion(Motion.standard, value: app.loginSession != nil)
        .motion(Motion.standard, value: app.onboardingError)
        .shake(trigger: shakeTrigger)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("连接服务器")
                    .foregroundStyle(app.loginSession == nil ? .primary : .secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text("登录账号")
                    .foregroundStyle(app.loginSession == nil ? .secondary : .primary)
            }
            .font(.caption.weight(.medium))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(app.loginSession == nil ? "第 1 步，连接服务器" : "第 2 步，登录账号")

            Text(app.loginSession == nil ? "连接你的媒体库" : "欢迎回来")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(app.loginSession == nil
                 ? "输入 Jellyfin 或 Emby 服务器地址，开始浏览与播放。"
                 : "登录后，即可访问这台服务器上的影片与剧集。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 第一步：服务器地址

    private var serverForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            savedServersSection

            Text("服务器地址")
                .font(.callout.weight(.medium))

            GlassField(
                icon: "server.rack",
                placeholder: "例如 192.168.1.10:8096",
                text: $serverAddress,
                onSubmit: { Task { await connect() } }
            )
            .id(InputField.server)
            .focused($serverFocused)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .accessibilityLabel("服务器地址")
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

            // 协议选择:选哪个,服务器所有请求(API / 图片 / 播放流)统一走哪个。
            // 手动输入 http:// 或 https:// 前缀会覆盖这里的选择。
            Picker("协议", selection: $serverScheme) {
                Text("HTTP").tag(ServerScheme.http)
                Text("HTTPS").tag(ServerScheme.https)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("支持 IP、域名和端口；完整链接中的协议会自动识别。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            PrimaryActionButton(
                title: "连接服务器",
                phase: app.isProbingServer ? .busy : .idle,
                isEnabled: !serverAddress.trimmingCharacters(in: .whitespaces).isEmpty && !app.isProbingServer
            ) {
                Task { await connect() }
            }

            Rectangle()
                .fill(.primary.opacity(0.08))
                .frame(height: 1)
                .padding(.vertical, 4)

            Button { app.skipLogin() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.circle")
                    Text("直接使用本地播放器")
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            Text("无需登录，稍后可在设置中连接媒体库。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 第二步：账号密码，可选 Quick Connect

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
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Button("换个服务器") { app.resetOnboarding() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(LoginWallStyle.accent)
            }
            .padding(12)
            .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 10) {
                Text("账号密码登录")
                    .font(.headline)

                GlassField(icon: "person", placeholder: "用户名", text: $username,
                           onSubmit: { Task { await submitPassword() } })
                    .id(InputField.username)
                    .focused($usernameFocused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .textContentType(.username)
                    #endif
                    .accessibilityLabel("用户名")
                GlassField(icon: "lock", placeholder: "密码", text: $password, isSecure: true,
                           onSubmit: { Task { await submitPassword() } })
                    .id(InputField.password)
                    .focused($passwordFocused)
                    #if os(iOS)
                    .textContentType(.password)
                    #endif
                    .accessibilityLabel("密码")

                PrimaryActionButton(
                    title: "登录",
                    phase: app.isAuthenticating ? .busy : .idle,
                    isEnabled: !username.isEmpty && !app.isAuthenticating
                ) {
                    Task { await submitPassword() }
                }
            }

            if app.loginSession?.supportsQuickConnect == true {
                Rectangle().fill(.primary.opacity(0.08)).frame(height: 1)
                Button {
                    quickConnectExpanded.toggle()
                    if quickConnectExpanded {
                        app.startQuickConnect()
                    } else {
                        app.stopQuickConnect()
                    }
                } label: {
                    HStack {
                        Label("使用 Quick Connect", systemImage: "link")
                        Spacer(minLength: 0)
                        Image(systemName: quickConnectExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(quickConnectExpanded ? "已展开" : "已收起")

                if quickConnectExpanded {
                    quickConnectPanel
                        .transition(.section)
                }
            }
        }
        .motion(Motion.standard, value: quickConnectExpanded)
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
                        Button(UIStrings.retry) { app.startQuickConnect() }
                            .buttonStyle(.plain)
                            .font(.callout)
                            .foregroundStyle(LoginWallStyle.accent)
                    }
                }
            } else if let code = app.quickConnectCode {
                quickConnectPanelBox {
                    VStack(spacing: 8) {
                        Text(code)
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                            .kerning(6)
                            .foregroundStyle(LoginWallStyle.accent)
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
                        Spacer(minLength: 0)
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .motion(Motion.standard, value: app.quickConnectCode)
        .motion(Motion.standard, value: app.quickConnectError)
    }

    /// 三种状态共用同一个盒子，切换时框体不跳。
    private func quickConnectPanelBox<Content: View>(
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
            }
            .transition(.section)
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
                        .background(.primary.opacity(0.10), in: RoundedRectangle(cornerRadius: 4))
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
                if !profile.addresses.isEmpty {
                    // 固定过就说「已固定」：这句是这台服务器连上去之后走哪条地址的
                    // 唯一提示，写「自动选择」会和实际行为打架。
                    Text(profile.pinnedURL == nil
                         ? "共 \(profile.addresses.count + 1) 个地址 · 自动选择"
                         : "共 \(profile.addresses.count + 1) 个地址 · 已固定")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            Button("连接") {
                Task { await app.switchToServer(profile) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.primary.opacity(0.10), lineWidth: 1)
        }
    }

    // MARK: - 动作

    private func connect() async {
        await app.connectServer(serverAddress, scheme: serverScheme)
    }

    private func submitPassword() async {
        await app.signIn(username: username, password: password)
    }
}

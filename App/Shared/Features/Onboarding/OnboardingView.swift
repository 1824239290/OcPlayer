import AppDesignKit
import JellyfinKit
import SwiftUI

/// 登录流程：① 服务器地址 → ② Quick Connect（主）+ 账号密码（兜底）。
///
/// Quick Connect 在服务器确认后自动开始轮询；它没开 / 超时也不挡密码登录。
///
/// ## 视觉
///
/// 本机媒体库海报铺成的**静态海报墙**做背景（随指针 3D 倾斜，macOS），中间悬浮一块
/// 毛玻璃卡片。墙上没有时钟、没有跑马灯——不动的时候一帧都不多画。
///
/// 墙上的图全部来自本机图片缓存，所以**登录页完全离线可用**，也不产生任何网络请求；
/// 本机没有缓存时退到程序化封面。理由见 `LoginWallCatalogLoader`。
///
/// 流程本身与换皮前逐字一致：字段、按钮、状态、动作都没动。
struct OnboardingView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var serverAddress = ""
    /// 协议选择:HTTP / HTTPS。控制服务器 baseURL 的 scheme。
    @State private var serverScheme: ServerScheme = .http
    @State private var username = ""
    @State private var password = ""

    /// 海报墙素材。**先摆程序化封面**，真海报在后台扫出来之后再逐张换上——
    /// 首帧就是一面完整的墙，不会先白一下。
    @State private var catalog = LoginWallCatalogLoader.proceduralCatalog(
        count: LoginWallCatalogLoader.fallbackSize
    )
    /// 报错时抖一下卡片。用递增计数当触发器（见 `ShakeModifier`）。
    @State private var shakeTrigger = 0

    var body: some View {
        ZStack {
            // 装饰层单独成组并退出安全区：墙要铺到窗口边缘（含 macOS 标题栏底下），
            // 而卡片留在安全区内。与本仓其它整窗氛围层（`BackdropAmbienceView`）同一条口径。
            backdrop

            content
        }
        // 常规宽度（Mac/iPad）保最小尺寸；紧凑宽度（iPhone）不设 min，让卡片自适应屏宽。
        .frame(minWidth: sizeClass == .compact ? nil : 720,
               minHeight: sizeClass == .compact ? nil : 560)
        .task {
            catalog = await LoginWallCatalogLoader.load(app: app)
        }
        .onChange(of: app.onboardingError) { _, newValue in
            if newValue != nil { shakeTrigger += 1 }
        }
    }

    // MARK: - 背景

    /// 整摞装饰层，**自己持有指针状态**。
    ///
    /// 指针必须落在这一层里，不能留在 `OnboardingView`：鼠标每动一次就写一次
    /// `pointer`，如果这个 `@State` 挂在登录页上，整页（包括右边那张卡片，以及卡片
    /// 里那个 `NSViewRepresentable` 的协议分段控件）都会被重新求值——实测这一条就
    /// 占了指针移动时一半以上的 CPU。指针是纯装饰的输入，它的作废范围就该只到墙为止。
    private var backdrop: some View {
        LoginWallBackdrop(catalog: catalog, motionEnabled: !reduceMotion)
            .ignoresSafeArea()
    }

    // MARK: - 卡片

    private var content: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 40)
                    HStack {
                        Spacer(minLength: 0)
                        card
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 40)
                }
                // 内容矮时垂直居中，高时（Quick Connect + 密码 + 已保存服务器）
                // 就地滚动——紧凑布局上这几块叠起来会超过一屏。
                .frame(minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
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
        .padding(26)
        // 常规宽度锁 460pt；紧凑宽度改为上限 460 并留屏幕边缘留白，窄机上不会溢出。
        .frame(maxWidth: 460)
        .padding(.horizontal, sizeClass == .compact ? 16 : 0)
        .glassPanel(cornerRadius: 26)
        // 卡片后面的颜色绽放：比卡片大一圈，让卡片像被自己的光托着，而不是贴上去的。
        .background {
            LoginWallGlowView(color: LoginWallStyle.accent)
                .frame(width: 620, height: 660)
        }
        .shadow(color: .black.opacity(0.55), radius: 42, y: 20)
        .motion(Motion.standard, value: app.loginSession != nil)
        .motion(Motion.standard, value: app.onboardingError)
        .shake(trigger: shakeTrigger)
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [LoginWallStyle.accent, LoginWallStyle.accentDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: "cat.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.black.opacity(0.82))
                }
                .shadow(color: LoginWallStyle.accent.opacity(0.45), radius: 12, y: 4)

            VStack(alignment: .leading, spacing: 2) {
                Text("OcPlayer")
                    .font(.system(size: 17, weight: .semibold))
                Text("连接 Jellyfin / Emby 媒体库")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 第一步：服务器地址

    private var serverForm: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: 12) {
            savedServersSection

            GlassField(
                icon: "server.rack",
                placeholder: "服务器地址，例如 192.168.1.10:8096",
                text: $serverAddress,
                onSubmit: { Task { await connect() } }
            )
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

            Text("可以不打前缀;选择器决定协议,手动打了 http:// 或 https:// 则以手动为准。")
                .font(.caption)
                .foregroundStyle(.tertiary)

            PrimaryActionButton(
                title: "连接",
                phase: app.isProbingServer ? .busy : .idle,
                isEnabled: !serverAddress.trimmingCharacters(in: .whitespaces).isEmpty && !app.isProbingServer
            ) {
                Task { await connect() }
            }

            HStack {
                Spacer()
                Button("先不登录，直接用播放器") { app.skipLogin() }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
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

            // Emby 没有 Quick Connect：只显示账号密码，不渲染 QC 面板和分隔条。
            if app.loginSession?.supportsQuickConnect != false {
                quickConnectPanel
                divider
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(app.loginSession?.supportsQuickConnect == false ? "账号密码登录" : "或用账号密码登录")
                    .font(.headline)

                GlassField(icon: "person", placeholder: "用户名", text: $username,
                           onSubmit: { Task { await submitPassword() } })
                    .autocorrectionDisabled()
                GlassField(icon: "lock", placeholder: "密码", text: $password, isSecure: true,
                           onSubmit: { Task { await submitPassword() } })

                PrimaryActionButton(
                    title: "登录",
                    phase: app.isAuthenticating ? .busy : .idle,
                    isEnabled: !username.isEmpty && !app.isAuthenticating
                ) {
                    Task { await submitPassword() }
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

    private var divider: some View {
        HStack(spacing: 12) {
            Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
            Text("或").font(.caption).foregroundStyle(.tertiary)
            Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
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

// MARK: - 背景层

/// 海报墙那一摞装饰层，**指针状态的作废边界**。
///
/// 鼠标移动只写这里的 `pointer`，所以每帧重算的只有这一层；右边那张登录卡完全
/// 不受影响（它不在这个视图的子树里）。这是登录页在指针移动时把 CPU 从 70% 压下来的
/// 关键结构——不是靠少画几张图，而是靠**别把卡片的求值卷进来**。
///
/// 每一层自己 `allowsHitTesting(false)`（墙、氛围、颗粒、遮罩各自的类型里声明），
/// 所以指针追踪与登录卡都照常收到事件。
private struct LoginWallBackdrop: View {
    let catalog: [LoginWallPoster]
    /// 关掉时连追踪器都不装——不是装了再把倾斜归零，那样每帧照样重算。
    let motionEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme
    /// 归一化 −1...1 的指针位置，驱动墙的倾斜。
    @State private var pointer = CGPoint.zero

    var body: some View {
        ZStack {
            LoginWallStyle.backdrop(for: colorScheme)

            // 墙是静止的：这里没有任何东西跑在时钟上。它只在指针移动时倾斜。
            LoginWallView(catalog: catalog, pointer: pointer, motionEnabled: motionEnabled)
            LoginWallAtmosphereView()
            LoginWallFilmGrainView()
            // 静态合成，所以它完全不在 60Hz 的时钟里。
            LoginWallScrimView()
        }
        .overlay {
            // 压在墙上面、忽略点击，只负责汇报指针。铺满整窗——指针位置按整窗归一化，
            // 只按内容区算的话倾斜会偏。
            if motionEnabled {
                LoginWallPointerTracker { location in
                    withAnimation(Motion.pointerTilt) { pointer = location ?? .zero }
                }
            }
        }
    }
}

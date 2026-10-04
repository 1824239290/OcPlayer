import BangumiKit
import DiagnosticsKit
import Foundation
import JellyfinKit

extension AppModel {
    // MARK: - 初始化 / 登录流程

    /// 启动时调用：有档案 + token 就静默恢复，否则进 onboarding。
    func bootstrap() async {
        guard phase == .boot else { return }
        // ⚠️ 测试宿主跑的是真实 App（`TEST_HOST = OcPlayer.app`），`RootView.task` 会照常
        // 调到这里。而 `MediaServerFactory.restore` 会读**真实**的服务器档案与令牌：
        // 于是跑一次测试就可能恢复出开发者本机的真实会话、连真实服务器，并因读取令牌
        // 触发凭据迁移（实测：一次全量 AppTests 就在真实 Application Support 里建出了
        // `credentials.json`）。测试进程不该动用户数据，所以这一整段在测试下不跑。
        //
        // 测试全都直接构造 `AppModel` 并手动设 `phase` / `server` 驱动（无一处依赖
        // `bootstrap`），跳过它不影响任何既有用例的覆盖。
        guard !RuntimeEnvironment.isRunningTests else {
            phase = .onboarding
            return
        }
        // Bangumi 数据库异步建库 + 恢复登录态（不阻塞 Jellyfin 会话恢复）。
        // 从 init 挪到这里：构造 AppModel 不再有副作用，测试拿到的实例是干净的。
        bangumi.setup()
        // 媒体元数据库同样异步建库（与下面的会话恢复并行，不阻塞首屏）。
        metadata.setup()
        // TMDb 补全服务挂在同一个库上。建库是异步的，所以这里等它完成再装配；
        // 等待发生在后台任务里，不阻塞首屏（TMDb 只是可选增强）。
        let metadataCoordinator = metadata
        let tmdbCoordinator = tmdb
        Task { @MainActor in
            _ = await metadataCoordinator.waitUntilReady()
            tmdbCoordinator.attach(store: metadataCoordinator.activeStore)
        }
        // 把淘汰挂到每日存储维护上。维护是单例、拿不到 AppModel（也不该拿），
        // 所以注入一个闭包。
        //
        // **注入点必须在这里，不能在 `OcPlayerApp.init()`**：那个位置经 `@State`
        // 拿到的 AppModel 未必是 SwiftUI 真正注入环境的那一个（本文件与
        // `AppModel.presentedPlayer` 的注释都记着这个坑，实测 ObjectIdentifier
        // 不同）——捕获错了对象，维护会对着一个从没 setup 过的协调器空转，
        // 而且**不报任何错**。bootstrap 跑在真实实例上，并天然只在生产路径执行
        // （测试宿主整段跳过），正是这个注入该在的地方。
        AppStorageMaintenance.shared.setDatabaseMaintenance { [metadata, tmdb] in
            await MainActor.run { metadata.refreshSize() }
            await metadata.runMaintenance()
            // 顺手清掉过期的 TMDb 实体（不是必须，只是把死数据还给用户）。
            await tmdb.runMaintenance()
        }
        // Bangumi OAuth 与弹幕共用网关：配置要在任何登录/刷新之前注入。
        await bangumi.applyGatewayConfiguration(bangumiGatewayConfiguration)
        // 网络路径变化 → 地址结论作废（下一个请求重新探活）。
        startEndpointMonitor()
        if let restored = MediaServerFactory.restore(from: store) {
            await activate(server: restored)
        } else {
            phase = .onboarding
        }
    }

    // MARK: - 登录流程

    /// Onboarding 第一步：验证服务器地址。
    func connectServer(_ rawURL: String, scheme: ServerScheme? = nil) async {
        loginAttemptGeneration &+= 1
        let attempt = loginAttemptGeneration
        isProbingServer = true
        onboardingError = nil
        defer {
            if loginAttemptGeneration == attempt {
                isProbingServer = false
            }
        }
        do {
            let session = try await MediaServerLogin.start(urlString: rawURL, preferredScheme: scheme)
            guard loginAttemptGeneration == attempt, phase == .onboarding else { return }
            loginSession = session
            // Emby 没有 Quick Connect 端点，直接进密码登录，不开轮询。
            if session.supportsQuickConnect {
                await startQuickConnect()
            }
        } catch let error as JellyfinError {
            if loginAttemptGeneration == attempt {
                onboardingError = error.errorDescription
                AppDiagnostics.logWarning("服务器探测失败 url=\(rawURL)", fields: ["error": .string(error.errorDescription ?? "\(error)")])
            }
        } catch {
            if loginAttemptGeneration == attempt {
                onboardingError = "\(error)"
                AppDiagnostics.logWarning("服务器探测异常 url=\(rawURL)", fields: ["error": .string("\(error)")])
            }
        }
    }

    /// 服务器确认后自动开始 Quick Connect 轮询（失败了也不阻塞密码登录）。
    func startQuickConnect() async {
        guard let session = loginSession else { return }
        quickConnectTask?.cancel()
        quickConnectCode = nil
        quickConnectError = nil
        quickConnectTask = Task { [weak self] in
            do {
                for try await event in session.quickConnectEvents {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case let .polling(code):
                        self.quickConnectCode = code
                    case let .authenticated(secret):
                        await self.completeLogin { try await session.signIn(quickConnectSecret: secret) }
                        return
                    }
                }
                // 流正常结束但没走到 authenticated：服务器停止发码 / 配对超时。
                // 不报到这里的话，面板会一直转「正在申请配对码…」，看不出已经没戏了。
                guard let self, self.loginSession === session, !self.isAuthenticating,
                      self.phase == .onboarding
                else { return }
                self.quickConnectError = "Quick Connect 配对已超时，请用下方账号密码登录。"
            } catch is CancellationError {
            } catch let error as JellyfinError {
                // Quick Connect 没开 / 超时：只写到 quickConnectError，让面板自己说明；
                // 不覆盖正在进行的密码登录 / 已成功的状态（用户在输密码时 QC 后台超时也算正常）。
                if let self, self.loginSession === session,
                   !self.isAuthenticating, self.phase == .onboarding {
                    self.quickConnectError = error.errorDescription
                        ?? "此服务器未启用 Quick Connect，请用下方账号密码登录。"
                }
            } catch {
                if let self, self.loginSession === session,
                   !self.isAuthenticating, self.phase == .onboarding {
                    self.quickConnectError = "\(error)"
                }
            }
        }
    }

    /// 账号密码登录（Quick Connect 之外的兜底）。
    func signIn(username: String, password: String) async {
        guard let session = loginSession else { return }
        await completeLogin { try await session.signIn(username: username, password: password) }
    }

    func completeLogin(_ authenticate: () async throws -> LoginResult) async {
        guard let session = loginSession, !isAuthenticating else { return }
        isAuthenticating = true
        onboardingError = nil
        defer {
            if self.loginSession == nil || self.loginSession === session {
                self.isAuthenticating = false
            }
        }
        do {
            let result = try await authenticate()
            guard loginSession === session, phase == .onboarding else { return }
            let server = try session.finish(result, store: self.store)
            quickConnectTask?.cancel()
            quickConnectTask = nil
            quickConnectCode = nil
            loginSession = nil
            // 换了服务器就先丢掉旧会话的数据与浏览栈：新服务器的首屏是异步拉的，
            // 不清的话拉取完成前 UI 会一直显示上一台的内容，像“登录后没刷新”。
            // 同一台服务器重登（token 过期）则保留数据，避免无谓的白屏。
            if self.server?.profile.id != server.profile.id {
                stopPlaybackForSessionChange()
                resetBrowseState()
            }
            // phase 已切到 ready，首屏数据靠 initialDataTask 异步驱动 home.isLoading
            // 的 loading 态——不阻塞登录 Task，让 Quick Connect 的轮询流尽快结束。
            await activate(server: server)
        } catch let error as JellyfinError {
            if loginSession === session { onboardingError = error.errorDescription }
        } catch {
            if loginSession === session { onboardingError = "\(error)" }
        }
    }

    /// 会话级变更（登出 / 换服务器 / 重连）共用的播放清理：停掉在播引擎与在途的
    /// 打开流程。不做的话会留下无 UI 覆盖、仍在出声的播放会话。
    func stopPlaybackForSessionChange() {
        cancelPlaybackOpen()
        retryPlaybackItem = nil
        _ = finishReporting()
        playback?.stopPlayback()
    }

    /// 清空随旧会话走的浏览数据与会话任务（媒体库 / 首页 / 导航栈 / 快照 / 氛围）。
    /// 服务器数据按 profile 隔离，条目 id 只在原服务器里有意义，不能跨会话复用。
    /// 播放侧的清理由调用方按需配 `stopPlaybackForSessionChange()`。
    /// signOut 曾有第二份几乎相同的手工清单，两处已各自漂移——现在只有这一份。
    ///
    /// **这里是唯一的会话边界**：凡是"只对当前服务器成立"的状态都必须列在里面，
    /// 否则就会出现「401 之后还拿着旧 server / 旧快照 / 旧氛围图」这类僵尸会话。
    func resetBrowseState() {
        initialDataTask?.cancel()
        initialDataTask = nil
        nextEpisodeTask?.cancel()
        nextEpisodeTask = nil
        externalSubtitleTask?.cancel()
        externalSubtitleTask = nil
        sessionGeneration &+= 1
        server = nil
        serverEndpointURL = nil
        libraries = []
        librariesError = nil
        libraryPages = [:]
        home = HomeData()
        // 详情快照按 item id 索引，而 id 只在原服务器里有意义——两台同库的服务器
        // 可能撞 id，留着会让新会话的详情页显示旧服务器的剧集。快照连同它的
        // 最近使用顺序表一起清。
        clearDetailSnapshots()
        // 氛围图的 URL 里带着**旧服务器的 authHeader**：不清掉，新会话首屏会拿
        // 旧凭据去请求图片（既拿不到图，也把旧凭据用在了新会话上）。
        resetWindowAmbienceStack()
        homeAmbience = nil
        pendingMoviePilotQuery = nil
        // 在飞的「淡出 → 落地」闭包属于旧会话，代次自增使其作废（见 beginRouteExit）。
        invalidatePendingRouteExit()
        isLocalFileImporterPresented = false
        isDirectLinkSheetPresented = false
        clearNavigationStacks()
        presentedPlayer = nil
        selectedSection = .home
    }

    func resetOnboarding() {
        loginAttemptGeneration &+= 1
        quickConnectTask?.cancel()
        quickConnectTask = nil
        isAuthenticating = false
        quickConnectCode = nil
        quickConnectError = nil
        loginSession = nil
        onboardingError = nil
    }

    func signOut() {
        stopPlaybackForSessionChange()
        // Stopped 已在上面补发。登出场景把 reporter 与终报 handoff 一并放手：
        // coordinator 强引用旧 server（含 token），不该在登出后仍被 App 层持有；
        // 终报任务是独立 Task，没有引用也会自己跑完落库。
        playbackReporting = nil
        pendingPlaybackReportingHandoff = nil
        if let server {
            store.signOut(id: server.profile.id)
        }
        resetBrowseState()
        isProbingServer = false
        resetOnboarding()
        phase = .onboarding
    }

    /// Onboarding 上的「先不登录」：进主框架（本地播放可用），服务器稍后在设置里连。
    func skipLogin() {
        phase = .ready
    }

    // MARK: - 多服务器切换

    /// 快速切到一台已保存的服务器。token 还有效就静默换会话 + 装载首屏；
    /// token 缺失 / 失效则探活后进登录流程（登录成功按同 id 覆盖旧档案）。
    func switchToServer(_ profile: ServerProfile) async {
        // 播放与浏览态属于旧会话，先停掉，别让用户看到旧服务器的数据闪一下。
        stopPlaybackForSessionChange()

        if let server = MediaServerFactory.resume(profile: profile, from: store) {
            if self.server?.profile.id != server.profile.id {
                resetBrowseState()
            }
            resetOnboarding()
            await activate(server: server)
            return
        }
        // token 无效：清掉死 token（保留档案），探活这台服务器后进密码登录第二步。
        // 地址用档案里的 baseURL——Emby 已含 /emby 前缀，startLogin 探活对带前缀
        // 地址同样响应；识别 kind 后 finish 会落回同样的 baseURL。
        store.signOut(id: profile.id)
        // connectServer 完成探测时要求 phase == .onboarding 才会挂上 loginSession；
        // 不先切过去（设置页里 phase 是 .ready），探活结果会被静默丢弃——
        // 表现为点了「切换」毫无反应，token 还已经被删掉了。换服务器时旧会话
        // 的浏览数据也一并清掉，和 resume 分支、completeLogin 的口径一致。
        if self.server?.profile.id != profile.id {
            resetBrowseState()
        }
        resetOnboarding()
        phase = .onboarding
        // 地址不止一条时先探活：`baseURL` 可能是在家落的局域网地址，人已经出门，
        // 直接拿它进登录流程必然失败 —— 而 Tailscale 那条是通的。并发探活取最快
        // 可达的一条；都不可达才退回 baseURL，让用户看到真实的连接错误。
        let candidates = profile.allAddresses.map(\.url)
        let reachable = candidates.count > 1
            ? await ServerProbe.firstReachable(
                of: candidates,
                authorizationHeader: nil,
                expectedServerID: profile.resolvedServerID)
            : nil
        let target = reachable?.url ?? profile.baseURL
        await connectServer(target.absoluteString, scheme: target.scheme == "https" ? .https : .http)
    }

    /// 未连接状态下首页的「去连接」：回登录流程。
    ///
    /// **必须走完整重置**（此前只清 path/navPaths/section + phase）：401 路径经
    /// `handleAuthenticationRequired` → 这里，而磁盘 token 已被 `store.signOut` 删掉、
    /// 内存里的 `server` 实例却还持着旧 token。只清导航的话，用户点「先不登录」进
    /// `.ready` 后，首页会因为 `app.server != nil` 直接渲染**旧服务器的数据**，随即
    /// 被下一个请求的 401 再拉回登录页——等于进不去「本地播放」。注释曾自称与
    /// `switchToServer` 的死 token 分支同口径，而那条路一直调的是 `resetBrowseState`，
    /// 两条路行为并不一致；现在统一。
    func reconnectFlow() {
        resetBrowseState()
        resetOnboarding()
        phase = .onboarding
    }

    /// 服务器 401 通知（token 失效且包内无重登兜底）：停播、清死 token、
    /// 拉回登录流程——与 switchToServer 死 token 分支同口径。
    /// profileID 不匹配（换服后迟到的旧 401）或已不在会话中则忽略，天然去重。
    func handleAuthenticationRequired(profileID: String) {
        guard phase == .ready, server?.profile.id == profileID else { return }
        stopPlaybackForSessionChange()
        store.signOut(id: profileID)
        reconnectFlow()
        onboardingError = "登录已过期，请重新登录"
    }
}


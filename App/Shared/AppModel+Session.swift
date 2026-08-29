import DiagnosticsKit
import Foundation
import JellyfinKit

extension AppModel {
    // MARK: - 初始化 / 登录流程

    /// 启动时调用：有档案 + token 就静默恢复，否则进 onboarding。
    func bootstrap() {
        guard phase == .boot else { return }
        if let restored = JellyfinServer(restoringFrom: store) {
            activate(server: restored)
        } else {
            phase = .onboarding
        }
    }

    // MARK: - 登录流程

    /// Onboarding 第一步：验证服务器地址。
    func connectServer(_ rawURL: String, scheme: JellyfinServerScheme? = nil) async {
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
            let session = try await JellyfinServer.startLogin(urlString: rawURL, preferredScheme: scheme)
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
                dropSessionData()
            }
            // phase 已切到 ready，首屏数据靠 initialDataTask 异步驱动 home.isLoading
            // 的 loading 态——不阻塞登录 Task，让 Quick Connect 的轮询流尽快结束。
            activate(server: server)
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

    /// 清空随旧会话走的浏览数据（媒体库 / 首页 / 导航栈）。
    /// 服务器数据按 profile 隔离，条目 id 只在原服务器里有意义，不能跨会话复用。
    /// 播放侧的清理由调用方按需配 `stopPlaybackForSessionChange()`。
    private func dropSessionData() {
        initialDataTask?.cancel()
        initialDataTask = nil
        sessionGeneration &+= 1
        server = nil
        libraries = []
        librariesError = nil
        libraryPages = [:]
        home = HomeData()
        path = []
        navPaths = NavigationPaths()
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
        initialDataTask?.cancel()
        initialDataTask = nil
        quickConnectTask?.cancel()
        quickConnectTask = nil
        loginAttemptGeneration &+= 1
        nextEpisodeTask?.cancel()
        nextEpisodeTask = nil
        externalSubtitleTask?.cancel()
        externalSubtitleTask = nil
        sessionGeneration &+= 1
        if let server {
            store.signOut(id: server.profile.id)
        }
        loginSession = nil
        quickConnectCode = nil
        quickConnectError = nil
        isProbingServer = false
        isAuthenticating = false
        onboardingError = nil
        server = nil
        libraries = []
        librariesError = nil
        libraryPages = [:]
        home = HomeData()
        path = []
        navPaths = NavigationPaths()
        presentedPlayer = nil
        selectedSection = .home
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

        if let server = JellyfinServer.resume(profile: profile, from: store) {
            if self.server?.profile.id != server.profile.id {
                dropSessionData()
            }
            resetOnboarding()
            activate(server: server)
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
            dropSessionData()
        }
        resetOnboarding()
        phase = .onboarding
        await connectServer(profile.baseURL.absoluteString, scheme: profile.baseURL.scheme == "https" ? .https : .http)
    }

    /// 未连接状态下首页的「去连接」：回登录流程。
    func reconnectFlow() {
        path = []
        navPaths = NavigationPaths()
        selectedSection = .home
        resetOnboarding()
        phase = .onboarding
    }
}


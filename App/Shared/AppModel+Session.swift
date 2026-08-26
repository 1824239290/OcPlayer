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
            await startQuickConnect()
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
            // phase 已切到 ready，首屏数据靠 initialDataTask 异步驱动 home.isLoading
            // 的 loading 态——不阻塞登录 Task，让 Quick Connect 的轮询流尽快结束。
            activate(server: server)
        } catch let error as JellyfinError {
            if loginSession === session { onboardingError = error.errorDescription }
        } catch {
            if loginSession === session { onboardingError = "\(error)" }
        }
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
        cancelPlaybackOpen()
        retryPlaybackItem = nil
        _ = finishReporting()
        playback?.stopPlayback()
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

    /// 未连接状态下首页的「去连接」：回登录流程。
    func reconnectFlow() {
        path = []
        navPaths = NavigationPaths()
        selectedSection = .home
        resetOnboarding()
        phase = .onboarding
    }
}


import DiagnosticsKit
import Foundation
import JellyfinKit

extension AppModel {
    // MARK: - 数据加载

    func activate(server: JellyfinServer) {
        initialDataTask?.cancel()
        sessionGeneration &+= 1
        self.server = server
        phase = .ready
        let generation = sessionGeneration
        initialDataTask = Task { [weak self] in
            await self?.loadInitialData(server: server, generation: generation)
        }
    }

    func sessionIsCurrent(_ generation: Int, server: JellyfinServer) -> Bool {
        sessionGeneration == generation && self.server?.profile.id == server.profile.id
    }

    func loadInitialData(server: JellyfinServer, generation: Int) async {
        await reloadBrowserData(server: server, generation: generation)
    }

    /// 重载首页和侧栏依赖的媒体库。断网后的重试必须同时恢复两部分数据。
    func reloadBrowserData() async {
        guard let server else { return }
        await reloadBrowserData(server: server, generation: sessionGeneration)
    }

    func reloadBrowserData(server: JellyfinServer, generation: Int) async {
        async let libs: Void = loadLibraries(server: server, generation: generation)
        async let home: Void = loadHome(server: server, generation: generation)
        _ = await (libs, home)
    }

    func loadLibraries(server: JellyfinServer, generation: Int) async {
        do {
            let loaded = try await server.userViews()
            guard sessionIsCurrent(generation, server: server) else { return }
            libraries = loaded
            librariesError = nil
        } catch let error as JellyfinError {
            guard sessionIsCurrent(generation, server: server) else { return }
            // 保留旧列表（若有），只暴露错误文案供侧栏/重试使用。
            librariesError = error.errorDescription
            AppDiagnostics.logWarning("媒体库列表加载失败", fields: [
                "error": .string(error.errorDescription ?? "\(error)"),
            ])
        } catch {
            guard sessionIsCurrent(generation, server: server) else { return }
            librariesError = "\(error)"
            AppDiagnostics.logWarning("媒体库列表加载异常", fields: ["error": .string("\(error)")])
        }
    }

    func loadHome() async {
        guard let server else { return }
        await loadHome(server: server, generation: sessionGeneration)
    }

    func loadHome(server: JellyfinServer, generation: Int) async {
        guard sessionIsCurrent(generation, server: server) else { return }
        homeLoadGeneration &+= 1
        let loadGeneration = homeLoadGeneration
        home.isLoading = true
        home.error = nil
        defer {
            if sessionIsCurrent(generation, server: server),
               homeLoadGeneration == loadGeneration {
                home.isLoading = false
            }
        }
        do {
            async let resume = server.resumeItems()
            async let nextUp = server.nextUp()
            async let latest = server.latestItems()
            let (resumeItems, nextUpItems, latestItems) = try await (resume, nextUp, latest)
            guard sessionIsCurrent(generation, server: server),
                  homeLoadGeneration == loadGeneration
            else { return }
            home.resume = resumeItems
            home.nextUp = nextUpItems
            home.latest = latestItems
        } catch let error as JellyfinError {
            guard sessionIsCurrent(generation, server: server),
                  homeLoadGeneration == loadGeneration
            else { return }
            home.error = error.errorDescription
            AppDiagnostics.logWarning("首页加载失败", fields: ["error": .string(error.errorDescription ?? "\(error)")])
        } catch {
            guard sessionIsCurrent(generation, server: server),
                  homeLoadGeneration == loadGeneration
            else { return }
            home.error = "\(error)"
            AppDiagnostics.logWarning("首页加载异常", fields: ["error": .string("\(error)")])
        }
    }
}


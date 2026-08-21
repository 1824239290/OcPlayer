import DiagnosticsKit
import Foundation
import JellyfinKit

/// 首页三条 Rail 上一次加载时的「有无内容」记录，跨启动保留。
///
/// 骨架屏要和真实内容同结构才不跳，而「有没有继续观看」只有请求回来才知道。
/// 这里把上一次的结论存下来，下次首屏的骨架就按同样的条数铺。
/// 首次启动没有历史 → 三条全铺（最常见的情形，也是原来的行为）。
struct HomeRailPresence: Equatable {
    var resume = true
    var nextUp = true
    var latest = true

    private static let storageKey = "dev.jumusu.ocplayer.home.railPresence"

    /// 有内容的 Rail 条数。三条都空时骨架要另找落点（全空的加载页看着像卡死）。
    var railCount: Int {
        [resume, nextUp, latest].filter { $0 }.count
    }

    static func restored(from defaults: UserDefaults = .standard) -> HomeRailPresence {
        guard let mask = defaults.object(forKey: storageKey) as? Int else {
            return HomeRailPresence()
        }
        return HomeRailPresence(
            resume: mask & 0b001 != 0,
            nextUp: mask & 0b010 != 0,
            latest: mask & 0b100 != 0
        )
    }

    func persist(to defaults: UserDefaults = .standard) {
        let mask = (resume ? 0b001 : 0) | (nextUp ? 0b010 : 0) | (latest ? 0b100 : 0)
        defaults.set(mask, forKey: Self.storageKey)
    }
}

extension AppModel {
    // MARK: - 数据加载

    func activate(server: JellyfinServer) {
        initialDataTask?.cancel()
        sessionGeneration &+= 1
        self.server = server
        // 换会话就丢掉上个会话的分页缓存：条目 id 只在那台服务器里有意义。
        libraryPages = [:]
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
            // 记下这次的 Rail 组成，供下次首屏骨架决定铺几条。
            let presence = HomeRailPresence(
                resume: !resumeItems.isEmpty,
                nextUp: !nextUpItems.isEmpty,
                latest: !latestItems.isEmpty
            )
            home.railPresence = presence
            presence.persist()
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


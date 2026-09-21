import CoreModel
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

    /// 「接下来看」剔除已经在「继续观看」里的条目。
    ///
    /// 半集（播了一部分但没看完）会被两个接口同时返回：Resume 按 IsResumable
    /// 收录它；NextUp 把「第一部未看完的剧」也算上它——服务端只认 PlayCount，
    /// 半集仍是未看。不剔的话同一条目会在两条 Rail 并排出现两次。
    /// 有播放进度的归「继续观看」，因此从「接下来看」侧剔除。
    nonisolated static func deduplicatedNextUp(_ nextUp: [MediaItem], resume: [MediaItem]) -> [MediaItem] {
        guard !nextUp.isEmpty, !resume.isEmpty else { return nextUp }
        let resumeIDs = Set(resume.map(\.id))
        return nextUp.filter { !resumeIDs.contains($0.id) }
    }

    func activate(server: any MediaServer) {
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

    func sessionIsCurrent(_ generation: Int, server: any MediaServer) -> Bool {
        sessionGeneration == generation && self.server?.profile.id == server.profile.id
    }

    func loadInitialData(server: any MediaServer, generation: Int) async {
        await reloadBrowserData(server: server, generation: generation)
    }

    /// 重载首页和侧栏依赖的媒体库。断网后的重试必须同时恢复两部分数据。
    func reloadBrowserData() async {
        guard let server else { return }
        await reloadBrowserData(server: server, generation: sessionGeneration)
    }

    func reloadBrowserData(server: any MediaServer, generation: Int) async {
        async let libs: Void = loadLibraries(server: server, generation: generation)
        async let home: Void = loadHome(server: server, generation: generation)
        _ = await (libs, home)
    }

    func loadLibraries(server: any MediaServer, generation: Int) async {
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

    func loadHome(server: any MediaServer, generation: Int) async {
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
        // 三条 rail 各自独立成败。以前这里是 `try await (a, b, c)` 一个元组收口，
        // **任何一条失败就把三条全丢**、整页白屏——而实测一台公网中转服务器
        // 中位 370ms、长尾到 22s、偶尔整条挂掉，另外两条其实已经拿到内容了。
        async let resume = RailResult.load { try await server.resumeItems() }
        async let nextUp = RailResult.load { try await server.nextUp() }
        async let latest = RailResult.load { try await server.latestItems(limit: 24) }
        let (resumeRail, nextUpRail, latestRail) = await (resume, nextUp, latest)

        guard sessionIsCurrent(generation, server: server),
              homeLoadGeneration == loadGeneration
        else { return }

        // 成功的 rail 覆盖；失败的保留上一次的内容，不清空。
        if let items = resumeRail.value { home.resume = items }
        if let items = nextUpRail.value {
            home.nextUp = Self.deduplicatedNextUp(items, resume: home.resume)
        }
        if let items = latestRail.value { home.latest = items }

        let rails = [resumeRail, nextUpRail, latestRail]
        // 三条**全**挂才算这一页失败。`HomeView` 本来也只在 latest 为空时展示
        // 整页错误态，所以部分失败时这里置 error 只会白白遮住已经拿到的内容。
        if rails.allSatisfy({ $0.value == nil && $0.failureDescription != nil }) {
            home.error = rails.compactMap(\.failureDescription).first
        }
        for (name, failure) in zip(["继续观看", "接下来看", "最近添加"], rails) {
            guard let failure = failure.failureDescription else { continue }
            AppDiagnostics.logWarning("首页 rail 加载失败 rail=\(name)", fields: ["error": .string(failure)])
        }

        // 记下这次的 Rail 组成，供下次首屏骨架决定铺几条。
        let presence = HomeRailPresence(
            resume: !home.resume.isEmpty,
            nextUp: !home.nextUp.isEmpty,
            latest: !home.latest.isEmpty
        )
        let changed = home.railPresence != presence
        home.railPresence = presence
        // 低频变化的三位布尔掩码，只在翻转时写盘（原先每次加载成功都同步写）。
        if changed {
            presence.persist()
        }
    }
}

/// 一条 rail 的加载结果：成功带内容，失败带文案。
///
/// **不抛**：首页三条 rail 是并列的三份数据，一条挂掉不该把另外两条一起丢掉。
/// 取消不算失败（值与被判定文案都为空），避免换会话时把过期请求的取消报成错误。
private struct RailResult {
    var value: [MediaItem]?
    var failureDescription: String?

    static func load(_ work: () async throws -> [MediaItem]) async -> RailResult {
        do {
            return RailResult(value: try await work(), failureDescription: nil)
        } catch is CancellationError {
            return RailResult(value: nil, failureDescription: nil)
        } catch let error as JellyfinError {
            return RailResult(value: nil, failureDescription: error.errorDescription)
        } catch {
            return RailResult(value: nil, failureDescription: "\(error)")
        }
    }
}


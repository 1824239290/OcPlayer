import AppDesignKit
import CoreModel
import DiagnosticsKit
import Foundation
import JellyfinKit
import MetadataKit

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

    /// 默认域走 `OcPlayerStorage.defaultPreferences`（生产 = `.standard`；自动化运行是隔离域）：
    /// 首屏骨架条数是 App 自有偏好，测试宿主不该写开发者本机那一份。
    static func restored(from defaults: UserDefaults = OcPlayerStorage.defaultPreferences) -> HomeRailPresence {
        guard let mask = defaults.object(forKey: storageKey) as? Int else {
            return HomeRailPresence()
        }
        return HomeRailPresence(
            resume: mask & 0b001 != 0,
            nextUp: mask & 0b010 != 0,
            latest: mask & 0b100 != 0
        )
    }

    func persist(to defaults: UserDefaults = OcPlayerStorage.defaultPreferences) {
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

    /// 会话落地（登录 / 启动恢复 / 切换服务器）。
    ///
    /// 只把服务器实例交给数据面，不再在这里包装缓存装饰器：仓储自己等库就绪，
    /// 建库失败退化为内存模式。首屏任务与头像任务并行启动。
    func activate(server: any MediaServer) async {
        initialDataTask?.cancel()
        sessionGeneration &+= 1
        // Install one canonical facade for the session. This keeps browsing,
        // playback reporting, and future migrated features on the same Rust
        // core instance while preserving the native fallback when the feature
        // flag or bundled library is unavailable.
        let effectiveServer = (server as? RustCoreMediaServer)
            ?? RustCoreMediaServer(wrapping: server, dataDirectory: OcPlayerStorage.defaultRoot)
            ?? server
        self.server = effectiveServer
        serverAvatarResolution = .pending
        viewingProfileAvatar.reset()
        // 记下本会话的图片缓存身份。**唯一**的会话落地点（登录 / 启动恢复 / 切换服务器）
        // 就是这里，所以只在这一处记；登录页在没有 token 时靠它复原海报的缓存键。
        // 刻意不在登出时清除——见 `ImageCacheIdentityStore`。
        ImageCacheIdentityStore.remember(
            identity: ImagePipeline.cacheIdentity(url: effectiveServer.profile.baseURL, authHeader: effectiveServer.authorizationHeader,
                                                  cacheScope: effectiveServer.profile.imageCacheScope),
            tenant: effectiveServer.profile.id
        )
        attachEndpoints(to: effectiveServer)
        // 换会话就丢掉上个会话的分页投影：条目 id 只在那台服务器里有意义。
        libraryPages = [:]
        phase = .ready
        let generation = sessionGeneration
        initialDataTask = Task { [weak self] in
            await self?.loadInitialData(server: effectiveServer, generation: generation)
        }
        // 头像单独一条任务，不搭首屏那趟车：它只喂首页 Tab 的图标，不该拖慢首屏；
        // 而首屏任务会被下拉刷新 / 重试重建，头像没必要跟着重来一遍。
        userAvatarTask?.cancel()
        userAvatarTask = Task { [weak self] in
            await self?.loadUserAvatar(server: effectiveServer, generation: generation)
        }
    }

    func sessionIsCurrent(_ generation: Int, server: any MediaServer) -> Bool {
        sessionGeneration == generation && self.server?.profile.id == server.profile.id
    }

    func loadInitialData(server: any MediaServer, generation: Int) async {
        // 先磁盘、后网络：冷启动 / 离线时首屏立刻有内容，随后网络结果原位覆盖。
        await hydrateBrowserDataFromCache(server: server, generation: generation)
        await reloadBrowserData(server: server, generation: generation)
    }

    /// 重载首页和侧栏依赖的媒体库。一次仓储刷新同时返回两部分，不再各发一轮。
    func reloadBrowserData() async {
        guard let server else { return }
        await reloadBrowserData(server: server, generation: sessionGeneration)
    }

    func reloadBrowserData(server: any MediaServer, generation: Int) async {
        await loadHome(server: server, generation: generation)
    }

    /// 冷启动时先把磁盘上的首页内容填进来（离线也有东西看）。
    ///
    /// **只在内存为空时填**：下拉刷新 / 重试也会走到这里，那时页面已有内容，
    /// 不该被磁盘旧版本盖回去。
    func hydrateBrowserDataFromCache(server: any MediaServer, generation: Int) async {
        guard sessionIsCurrent(generation, server: server) else { return }
        guard libraries.isEmpty, home.resume.isEmpty, home.nextUp.isEmpty, home.latest.isEmpty
        else { return }
        let cacheClock = ContinuousClock()
        let cacheStart = cacheClock.now
        guard let cached = await metadata.cachedHome() else { return }
        let cacheElapsed = cacheClock.now - cacheStart
        let cacheMs = Int64(cacheElapsed.components.seconds * 1000)
            + Int64(cacheElapsed.components.attoseconds / 1_000_000_000_000_000)
        guard sessionIsCurrent(generation, server: server) else { return }

        libraries = cached.value.libraries
        home.resume = cached.value.resume
        home.nextUp = cached.value.nextUp
        home.latest = cached.value.latest
        // 记下缓存时间：网络刷新失败时用它渲染「更新于 X 前」。
        home.cachedFetchedAt = cached.fetchedAt
        AppDiagnostics.logInfo("首页用磁盘缓存预热", fields: [
            "resume": .integer(Int64(cached.value.resume.count)),
            "nextUp": .integer(Int64(cached.value.nextUp.count)),
            "latest": .integer(Int64(cached.value.latest.count)),
            "readMs": .integer(cacheMs),
        ])
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

        // 仓储内部四路并行、同键单飞：同一时刻只存在一轮首页请求，
        // 失败分区自动沿用上一份内容。
        guard let refreshed = await metadata.refreshHome() else { return }
        guard sessionIsCurrent(generation, server: server),
              homeLoadGeneration == loadGeneration
        else { return }

        applyHomeContent(refreshed.snapshot.value)
        let failures = refreshed.failures

        if let libraryFailure = failures["libraries"] {
            librariesError = libraryFailure.message
        } else {
            librariesError = nil
        }

        let railNames = ["resume": "继续观看", "nextUp": "接下来看", "latest": "最近添加"]
        let failedRails = railNames.compactMap { key, label -> (String, MediaFailure)? in
            guard let failure = failures[key] else { return nil }
            return (label, failure)
        }
        // 三条 rail 全挂才算整页失败；部分失败时页面已经有内容。
        if failedRails.count == railNames.count {
            home.error = failedRails.first?.1.message
        }
        if failures.isEmpty {
            home.cachedFetchedAt = nil
            home.refreshFailureWasConnectivity = false
        } else {
            home.cachedFetchedAt = refreshed.snapshot.fetchedAt
            home.refreshFailureWasConnectivity = failedRails.contains { $0.1.isConnectivity }
        }
        for (label, failure) in failedRails {
            AppDiagnostics.logWarning("首页 rail 加载失败 rail=\(label)", fields: [
                "error": .string(failure.message),
            ])
        }

        if sessionIsCurrent(generation, server: server),
           homeLoadGeneration == loadGeneration {
            homeInitialLoadDone = true
        }

        // 记下这次的 Rail 组成，供下次首屏骨架决定铺几条。
        let presence = HomeRailPresence(
            resume: !home.resume.isEmpty,
            nextUp: !home.nextUp.isEmpty,
            latest: !home.latest.isEmpty
        )
        let changed = home.railPresence != presence
        home.railPresence = presence
        if changed {
            presence.persist(to: preferences)
        }
    }

    private func applyHomeContent(_ content: MediaHomeContent) {
        libraries = content.libraries
        home.resume = content.resume
        home.nextUp = content.nextUp
        home.latest = content.latest
    }
}

extension JellyfinError {
    /// 这次失败是否属于「连不上」（断网 / 服务器不可达）。
    ///
    /// 文案要靠它区分：断网说「离线」是准确的，而 5xx / 401 说「离线」会把人
    /// 引去查网络——同样的判断在详情页也有一份（`DetailViewModel`），
    /// 两处共用这一条口径。
    var isConnectivityFailure: Bool {
        switch kind {
        case .noNetwork, .serverUnreachable: return true
        default: return false
        }
    }
}


import DiagnosticsKit
import Foundation

/// 弹幕装载流水线的编排结果。`DanmakuCoordinator`（app 层）把它映射成
/// HUD 可直接显示的状态；测试用它断言整个 匹配 → 缓存 → 装载 链路的走向。
/// `introHint` 是弹幕推导的片头提示（`.empty` 也可能带出历史提示）。
public enum DanmakuLoadOutcome: Equatable, Sendable {
    case loaded(episodeID: Int64, commentCount: Int, title: String, introHint: DanmakuIntroHint?)
    case noMatch
    case empty(episodeID: Int64, title: String, introHint: DanmakuIntroHint?)
    case failed(message: String)
}

/// 播放器侧为弹幕装载提供的同步动作。`uuid` 是 `PlaybackRequest.id` 的等价物，
/// 用于区分「同一次播放的不同源代次」与「不同的播放请求」。
/// 标 `@MainActor` 以便 `PlaybackController`（主线程绑定）直接 conform；
/// 编排器在 async 上下文调用时会隐式 hop 到主线程。
@MainActor
public protocol DanmakuPlaybackHosting {
    var danmakuPayloadFormat: DanmakuPayloadFormat { get }

    /// 等待当前播放源就绪（可注入弹幕）。超时或源已切换返回 false。
    func waitUntilReady(uuid: UUID, timeout: Duration) async -> Bool
    /// 装载弹幕；返回 false 表示播放源已不在当前代次（调用方应放弃并终止）。
    /// 返回值为真时，错误由实现方抛出。
    ///
    /// `entries` 是 overlay 渲染路线的输入（结构直传，播放器侧零解析）；`json` 只给
    /// 内核弹幕轨路线用（当前停用）。两者由 `DanmakuService` 在同一执行器上产出。
    func replaceDanmaku(
        uuid: UUID,
        entries: [DanmakuJSONParser.Entry],
        json: String?,
        name: String,
        offset: Duration
    ) throws -> Bool
    /// 清空当前源上的弹幕；返回 false 语义同上。
    func clearDanmaku(uuid: UUID) throws -> Bool
}

public extension DanmakuPlaybackHosting {
    /// 默认取 `.overlay` —— 与当前生产路线一致（内核弹幕因滑窗重排跳轨被禁用，
    /// `PlaybackController.resolveOverlayDanmakuRoute()` 恒走 overlay）。
    ///
    /// 此前默认是 `.both`，于是**忘记实现这个属性的接入方**会白算一份全量
    /// `erikaJSON`（把所有弹幕重新编码成 MB 级字符串），而那份产物没人用。
    /// 默认值应当等于「生产实际在用什么」，而不是「两者都算保险」。
    var danmakuPayloadFormat: DanmakuPayloadFormat { .overlay }
}

/// 把 自动匹配 → 弹幕正文缓存 → 装载到播放器 串成可测的流水线。
///
/// 竞态防护全部在这里：`revision` 是单调递增的代次，任何跨 await 的写操作
/// （状态、缓存映射）都必须先经过 `isCurrent` 校验；播放器侧动作通过
/// `uuid + playbackToken` 校验当前播放源代次。
///
/// 标 `@MainActor`：播放器装载动作在主线程执行（与 `PlaybackController` 一致），
/// 网络 await 期间不占用主线程。app 层的 `DanmakuCoordinator` 同为 MainActor，
/// 直接调用无需 hop。
@MainActor
public struct DanmakuLoadOrchestrator {
    public let service: DanmakuService
    private let session: URLSession
    private let retryPolicy: RetryPolicy
    /// AniSkip 只读客户端（跳过片头第三数据源，见 `resolveIntroHint`）。
    private let aniSkipClient: AniSkipClient
    /// MAL ID 解析器（ProviderIds 直取 → 永久缓存 → AniList 搜索）。
    private let aniSkipIDResolver: AniSkipIDResolver
    /// 标题别名桥（AniSkip 候选标题增强用，可缺省）：dandanplay 的中文标题在
    /// AniList 常搜不中，别名里的日文原名往往是原生标题。可空——注入失败只降级。
    private let titleAliases: DanmakuTitleAliasProviding?
    /// anime-skip 客户端惰性获取：client ID 在设置里填了才有值（填了才启用）。
    /// 闭包形式保证设置改动即时生效。
    private let animeSkipClientProvider: (@Sendable () -> AnimeSkipClient?)?
    /// TheIntroDB 客户端（免鉴权;只在 context.seriesTmdbID 存在时才会发请求）。
    private let theIntroDBClient: TheIntroDBClient?
    /// 手动跳过学习存储（App 层喂事件;解析链路读晋升结果）。
    private let introLearningStore: IntroLearningStore?

    public init(
        service: DanmakuService,
        session: URLSession = DanmakuNetworking.makeSession(),
        retryPolicy: RetryPolicy = RetryPolicy(),
        aniSkipClient: AniSkipClient? = nil,
        aniSkipIDResolver: AniSkipIDResolver? = nil,
        titleAliases: DanmakuTitleAliasProviding? = nil,
        animeSkipClientProvider: (@Sendable () -> AnimeSkipClient?)? = nil,
        theIntroDBClient: TheIntroDBClient? = nil,
        introLearningStore: IntroLearningStore? = nil
    ) {
        self.service = service
        self.session = session
        self.retryPolicy = retryPolicy
        self.aniSkipClient = aniSkipClient ?? AniSkipClient(session: session)
        self.aniSkipIDResolver = aniSkipIDResolver ?? AniSkipIDResolver(
            store: AniSkipIDStore(directory: service.cacheDirectory),
            session: session
        )
        self.titleAliases = titleAliases
        self.animeSkipClientProvider = animeSkipClientProvider
        self.theIntroDBClient = theIntroDBClient ?? TheIntroDBClient(session: session)
        self.introLearningStore = introLearningStore
    }

    /// 整个自动匹配 + 装载链路。`forceRematch` 跳过缓存并清除已记住的映射。
    public func runAutomatic(
        matchContext: DanmakuMatchContext,
        configuration: DandanplayConfiguration,
        playback: DanmakuPlaybackHosting,
        revision: UInt64,
        forceRematch: Bool = false
    ) async -> DanmakuLoadOutcome {
        let client = DanmakuGatewayClient(
            configuration: configuration, session: session, retryPolicy: retryPolicy)
        let cacheKey = matchContext.cacheKey
        do {
            try Task.checkCancellation()
            if forceRematch {
                _ = try? await playback.clearDanmaku(uuid: matchContext.uuid)
            }
            // 先无条件 claim（幂等，取 max）：isCurrent 依赖 claim 已存在。
            await service.claimMatchRevision(cacheKey: cacheKey, revision: revision)
            if !forceRematch,
               matchContext.allowsCachedMatchReuse,
               let cached = await service.cachedMatch(for: cacheKey),
               await isCurrent(revision, cacheKey: cacheKey) {
                return await loadPayload(
                    match: cached,
                    uuid: matchContext.uuid,
                    cacheKey: cacheKey,
                    configuration: configuration,
                    playback: playback,
                    revision: revision,
                    client: client,
                    matchContext: matchContext,
                    forceRematch: forceRematch
                )
            }

            // 1. 构建目标识别基准（优先外部传入，否则由文件名解析补全）
            let parsed = DanmakuFilenameParser.parse(matchContext.fileName)
            let localTitle = matchContext.animeTitle?.nilIfEmpty ?? parsed.title.nilIfEmpty
            let target = DanmakuCandidateScorer.TargetContext(
                animeTitle: localTitle,
                episodeNumber: matchContext.episodeNumber ?? parsed.episodeNumber,
                seasonNumber: matchContext.seasonNumber ?? parsed.seasonNumber,
                isFinal: matchContext.isFinal || parsed.isFinal,
                special: matchContext.special,
                kind: matchContext.isMovie ? .movie : .episode
            )

            // 2. 多级智能匹配。每级显式 do/catch：取消照抛；其余错误记入 tierError
            // 后继续降级——最终无命中时按「失败可重试」上报，不再吞成「未匹配」。
            var matched: DanmakuEpisodeMatch? = nil
            var fingerprintFailed = false
            /// 最近一次降级检索抛出的非取消错误（网关/网络/协议）。
            var tierError: Error?
            /// 任一降级层命中网关级故障后短路剩余层：请求层已按重试策略把瞬态
            /// 错误重试耗尽，后续换参数的降级检索打的是同一个网关，再试必败，
            /// 只会放大请求突发（还可能自触网关限流）。
            var gatewayDown = false

            // Tier 1: 尝试 Hash + 文件名匹配
            var hashValue: String? = nil
            do {
                hashValue = try await matchContext.mediaHash(session: session)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                fingerprintFailed = true
            }
            if hashValue == nil {
                fingerprintFailed = true
            }

            // 指纹的真实结果只在这里才知道：调用方的「自动匹配开始」打在计算之前，
            // GatewayClient 的「匹配参数」又只在 Tier 1 真发起时才有。指纹是降级到
            // 标题/TMDB 匹配的首要原因，排查时得能直接看到它到底有没有。
            NetworkLog.report(
                category: "Danmaku",
                level: .info,
                "媒体指纹解析",
                fields: [
                    "hashPresent": .boolean(hashValue != nil),
                    "fingerprintFailed": .boolean(fingerprintFailed),
                ]
            )

            if let hash = hashValue {
                try Task.checkCancellation()
                guard await isCurrent(revision, cacheKey: cacheKey) else { return .failed(message: "播放已切换") }

                do {
                    matched = try await service.automaticMatch(
                        cacheKey: cacheKey,
                        request: MatchRequest(
                            fileName: matchContext.fileName,
                            fileHash: hash,
                            fileSize: matchContext.fileSize,
                            videoDuration: matchContext.durationSeconds,
                            matchMode: .hashAndFileName
                        ),
                        client: client,
                        targetContext: target,
                        ignoringCachedMatch: true,
                        persistingResult: false
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    tierError = error
                    if (error as? DandanplayError)?.isGatewayFailure == true {
                        gatewayDown = true
                    }
                }
            }

            // Tier 2: 若未命中且有 TMDB ID，按 TMDB ID 搜索分集
            if matched == nil, !gatewayDown, let tmdbID = matchContext.tmdbID {
                try Task.checkCancellation()
                guard await isCurrent(revision, cacheKey: cacheKey) else { return .failed(message: "播放已切换") }
                do {
                    matched = try await searchByTMDB(
                        tmdbID: tmdbID,
                        target: target,
                        client: client
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    tierError = error
                    if (error as? DandanplayError)?.isGatewayFailure == true {
                        gatewayDown = true
                    }
                }
            }

            // Tier 3: 若仍未命中，按动画标题 + 集数搜索分集
            if matched == nil, !gatewayDown, let animeTitle = target.animeTitle, !animeTitle.isEmpty {
                try Task.checkCancellation()
                guard await isCurrent(revision, cacheKey: cacheKey) else { return .failed(message: "播放已切换") }
                do {
                    matched = try await searchByTitleAndEpisode(
                        animeTitle: animeTitle,
                        target: target,
                        client: client
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    tierError = error
                    if (error as? DandanplayError)?.isGatewayFailure == true {
                        gatewayDown = true
                    }
                }
            }

            // Tier 4: 若仍未命中且解析出的纯化标题不同，用纯化标题再次尝试搜索。
            if matched == nil, !gatewayDown, let cleanTitle = parsed.title.nilIfEmpty, cleanTitle != target.animeTitle {
                try Task.checkCancellation()
                guard await isCurrent(revision, cacheKey: cacheKey) else { return .failed(message: "播放已切换") }
                do {
                    matched = try await searchByTitleAndEpisode(
                        animeTitle: cleanTitle,
                        target: target,
                        client: client
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    tierError = error
                    if (error as? DandanplayError)?.isGatewayFailure == true {
                        gatewayDown = true
                    }
                }
            }

            try Task.checkCancellation()
            guard await isCurrent(revision, cacheKey: cacheKey) else { return .failed(message: "播放已切换") }

            guard let match = matched else {
                if forceRematch {
                    await service.forgetMatch(cacheKey: cacheKey, revision: revision)
                }
                if fingerprintFailed {
                    // 指纹不可用是更具体的诊断（引导手动选集）；GatewayClient 已逐请求
                    // 记录了失败日志，这里维持既有文案优先级。
                    return .failed(message: userMessage(for: AutomaticMatchError.fingerprintUnavailable))
                }
                if let tierError {
                    // 网络/网关失败不能谎报「未匹配到剧集」：UI 走可重试的失败态，
                    // 文案复用 DandanplayError 的稳定用户文案（额度用完/网络失败等）。
                    NetworkLog.report(
                        category: "Danmaku",
                        level: .warning,
                        "弹幕自动匹配降级检索失败",
                        fields: [
                            "cacheKey": .string(cacheKey),
                            "error": .string(String(describing: tierError)),
                        ]
                    )
                    return .failed(
                        message: (tierError as? DandanplayError)?.userMessage
                            ?? "弹幕网络请求失败，请检查网络后重试")
                }
                return .noMatch
            }

            await service.remember(match: match, cacheKey: cacheKey, revision: revision)
            guard await isCurrent(revision, cacheKey: cacheKey) else { return .failed(message: "播放已切换") }
            return await loadPayload(
                match: match,
                uuid: matchContext.uuid,
                cacheKey: cacheKey,
                configuration: configuration,
                playback: playback,
                revision: revision,
                client: client,
                matchContext: matchContext,
                forceRematch: forceRematch
            )
        } catch is CancellationError {
            return .failed(message: "已取消")
        } catch {
            guard await isCurrent(revision, cacheKey: cacheKey) else { return .failed(message: "播放已切换") }
            return .failed(message: userMessage(for: error))
        }
    }

    /// 搜索参数序列：正片先精确集数再全集兜底。**特典只发全集搜索**——Jellyfin 的
    /// season-0 序号与弹弹play 的 S/C/O 命名空间不同源（实测拿序号 29 发 `episode=S29`
    /// 会唯一命中同 IP 剧场版的 S29），靠打分器在全量分集里选才不引入错误候选。
    static func episodeQueries(for target: DanmakuCandidateScorer.TargetContext) -> [String?] {
        if target.special != nil { return [nil] }
        if let episode = target.episodeNumber {
            return [String(episode), nil]
        }
        return [nil]
    }

    private func searchByTMDB(
        tmdbID: Int,
        target: DanmakuCandidateScorer.TargetContext,
        client: DanmakuGatewayClient
    ) async throws -> DanmakuEpisodeMatch? {
        // 错误直接上抛给 tier 的 do/catch（不再内部 try? 吞掉）：
        // 网关挂了要能让最终结果落「失败可重试」而不是「未匹配」。
        let episodeQuery = Self.episodeQueries(for: target).first ?? nil
        let episodeScoped = try await client.searchEpisodes(
            tmdbId: tmdbID,
            tmdbIdType: 0,
            episode: episodeQuery
        ).payload.animes
        if !episodeScoped.isEmpty,
           let best = DanmakuCandidateScorer.pickBestEpisode(from: episodeScoped, target: target) {
            return best.match
        }
        if target.episodeNumber != nil && target.special == nil {
            let all = try await client.searchEpisodes(
                tmdbId: tmdbID,
                tmdbIdType: 0,
                episode: nil
            ).payload.animes
            if !all.isEmpty,
               let best = DanmakuCandidateScorer.pickBestEpisode(from: all, target: target) {
                return best.match
            }
        }
        let movieScoped = try await client.searchEpisodes(
            tmdbId: tmdbID,
            tmdbIdType: 1,
            episode: nil
        ).payload.animes
        if !movieScoped.isEmpty,
           let best = DanmakuCandidateScorer.pickBestEpisode(from: movieScoped, target: target) {
            return best.match
        }
        return nil
    }

    private func searchByTitleAndEpisode(
        animeTitle: String,
        target: DanmakuCandidateScorer.TargetContext,
        client: DanmakuGatewayClient
    ) async throws -> DanmakuEpisodeMatch? {
        let trimmedTitle = animeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        // 1. 依次尝试：正片集数 / 特典命名空间（S→C→O）；错误上抛给 tier 的 do/catch。
        // 2. 全集搜索：不带 episode，在返回的所有分集里按 token 打分挑。
        for query in Self.episodeQueries(for: target) {
            let scoped = try await client.searchEpisodes(
                anime: trimmedTitle,
                episode: query
            ).payload.animes
            if !scoped.isEmpty,
               let best = DanmakuCandidateScorer.pickBestEpisode(from: scoped, target: target) {
                return best.match
            }
        }
        return nil
    }

    /// 用户手动选择某一集后的装载。`matchContext` 携带集数/时长/ProviderIds，
    /// 供 AniSkip 跳过片头解析；手动选集视为显式重解析（无视缓存提示）。
    public func runManual(
        match: DanmakuEpisodeMatch,
        uuid: UUID,
        cacheKey: String,
        configuration: DandanplayConfiguration,
        playback: DanmakuPlaybackHosting,
        revision: UInt64,
        matchContext: DanmakuMatchContext? = nil
    ) async -> DanmakuLoadOutcome {
        let client = DanmakuGatewayClient(
            configuration: configuration, session: session, retryPolicy: retryPolicy)
        await service.remember(match: match, cacheKey: cacheKey, revision: revision)
        return await loadPayload(
            match: match,
            uuid: uuid,
            cacheKey: cacheKey,
            configuration: configuration,
            playback: playback,
            revision: revision,
            client: client,
            matchContext: matchContext,
            forceRematch: true
        )
    }

    private func loadPayload(
        match: DanmakuEpisodeMatch,
        uuid: UUID,
        cacheKey: String,
        configuration: DandanplayConfiguration,
        playback: DanmakuPlaybackHosting,
        revision: UInt64,
        client: DanmakuGatewayClient,
        matchContext: DanmakuMatchContext?,
        forceRematch: Bool
    ) async -> DanmakuLoadOutcome {
        do {
            try Task.checkCancellation()
            let payload = try await service.payload(
                for: match,
                client: client,
                format: playback.danmakuPayloadFormat
            )
            try Task.checkCancellation()
            let name = Self.matchTitle(match)
            // 等待播放器引擎就绪（原实现 30s 等待；缓存命中时注入往往先于引擎 ready）。
            guard await playback.waitUntilReady(uuid: uuid, timeout: .seconds(30)) else {
                if await isCurrent(revision, cacheKey: cacheKey) {
                    return .failed(message: "视频未就绪，弹幕未装载")
                }
                return .failed(message: "播放已切换")
            }
            let accepted: Bool
            if payload.entries != nil || payload.json != nil {
                accepted = try await playback.replaceDanmaku(
                    uuid: uuid,
                    entries: payload.entries ?? [],
                    json: payload.json,
                    name: name,
                    offset: .seconds(Double(match.shiftSeconds))
                )
            } else {
                accepted = try await playback.clearDanmaku(uuid: uuid)
            }
            guard accepted else {
                if await isCurrent(revision, cacheKey: cacheKey) {
                    return .failed(message: "视频未就绪，弹幕未装载")
                }
                return .failed(message: "播放已切换")
            }
            // 跳过片头解析放在弹幕注入之后：AniSkip/AniList 的外网查询不得拖慢弹幕上屏。
            let introHint = await resolveIntroHint(
                match: match,
                matchContext: matchContext,
                detected: payload.detectedIntroHint,
                forceRematch: forceRematch
            )
            if payload.entries == nil, payload.json == nil {
                return .empty(episodeID: match.episodeID, title: name, introHint: introHint)
            }
            return .loaded(
                episodeID: match.episodeID,
                commentCount: payload.commentCount,
                title: name,
                introHint: introHint
            )
        } catch is CancellationError {
            return .failed(message: "已取消")
        } catch {
            guard await isCurrent(revision, cacheKey: cacheKey) else { return .failed(message: "播放已切换") }
            return .failed(message: userMessage(for: error))
        }
    }

    private func isCurrent(_ revision: UInt64, cacheKey: String) async -> Bool {
        guard !Task.isCancelled else { return false }
        let claimed = await service.claimedRevision(for: cacheKey)
        return revision == claimed
    }

    // MARK: 跳过片头（AniSkip > 弹幕检测）

    /// 片头提示解析（优先级从高到低）：
    /// 1. 永久缓存（`forceRematch` 时无视缓存重新解析，与跳过缓存匹配同语义）；
    /// 2. 多源社区区间（AniSkip ∥ anime-skip ∥ TheIntroDB 并行,±10s 聚簇选优）；
    /// 3. 用户学习值（手动跳过行为的 anime 级晋升）；
    /// 4. 兄弟集提示聚合（同番其他集的弹幕推导值,≥2 集一致才采纳）；
    /// 5. 弹幕报点推导（本次正文现算）。
    /// 选中的结果持久化；任何一步失败静默降级，只影响这一路数据源的有无。
    private func resolveIntroHint(
        match: DanmakuEpisodeMatch,
        matchContext: DanmakuMatchContext?,
        detected: DanmakuIntroHint?,
        forceRematch: Bool
    ) async -> DanmakuIntroHint? {
        if !forceRematch, let cached = await service.cachedIntroHint(for: match.episodeID) {
            return cached
        }
        if let hint = await multiSourceHint(match: match, context: matchContext, forceRematch: forceRematch) {
            await service.persistIntroHint(hint, for: match.episodeID)
            return hint
        }
        // 用户学习值（anime 级）：手动跳过行为跨集晋升/确认升级的产物。
        if !forceRematch,
           let introLearningStore,
           let animeID = match.animeID ?? match.derivedAnimeID,
           let promoted = await introLearningStore.promotedHint(forAnime: animeID) {
            await service.persistIntroHint(promoted, for: match.episodeID)
            return promoted
        }
        // 兄弟集提示聚合（零请求）：同番其他集的弹幕推导值,≥2 集一致才采纳。
        if let hint = await siblingAggregatedHint(match: match) {
            await service.persistIntroHint(hint, for: match.episodeID)
            return hint
        }
        if let detected {
            await service.persistIntroHint(detected, for: match.episodeID)
            return detected
        }
        return nil
    }

    /// 多源社区跳过时间：AniSkip（MAL）∥ anime-skip（AniList）∥ TheIntroDB
    /// （TMDB 剧集级）并行查询 → ±10s 聚簇选优。无集数、无身份线索或全部落空
    /// 返回 nil（「跳过片头」少一路数据源而已）。
    ///
    /// `forceRematch` 透传给 ID 解析器：显式重匹配时绕过正/负缓存全新解析。
    private func multiSourceHint(
        match: DanmakuEpisodeMatch,
        context: DanmakuMatchContext?,
        forceRematch: Bool
    ) async -> DanmakuIntroHint? {
        guard let context, let episodeNumber = context.episodeNumber, episodeNumber >= 1 else {
            NetworkLog.report(
                category: "AniSkip", level: .debug,
                "跳过片头缺集数上下文，社区源不查")
            return nil
        }
        // 候选标题：弹幕匹配标题 → 媒体库原生标题（Jellyfin OriginalTitle，多为
        // 日文原名）→ Bangumi 别名。dandanplay 的简体中文标题在 AniList 常常零召回，
        // 多候选是 ID 解析的生路；去重滤空由 identity.searchTitles 统一做。
        var candidates: [String] = []
        if let matched = (match.animeTitle ?? context.animeTitle)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !matched.isEmpty {
            candidates.append(matched)
        }
        if let original = context.originalTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines), !original.isEmpty {
            candidates.append(original)
        }
        // 别名按主标题查一次（自带永久缓存 + 负缓存，重复播放零成本）。
        if let primary = candidates.first {
            candidates += await titleAliases?.aliases(for: primary) ?? []
        }
        let identity = AniSkipAnimeIdentity(
            malID: context.malID,
            anilistID: context.anilistID,
            title: candidates.first,
            alternativeTitles: Array(candidates.dropFirst()),
            seasonNumber: context.seasonNumber,
            year: nil
        )
        let ids = await aniSkipIDResolver.resolve(for: identity, forceRefresh: forceRematch)

        // 并行查询所有可用源。客户端/上下文先落局部常量,@Sendable 闭包不捕获 self。
        let aniSkipClient = self.aniSkipClient
        let theIntroDBClient = self.theIntroDBClient
        let animeSkipClient = animeSkipClientProvider?()
        let durationSeconds = context.durationSeconds
        let seasonNumber = context.seasonNumber
        let seriesTmdbID = context.seriesTmdbID

        var found: [SkipSourceInterval] = []
        await withTaskGroup(of: SkipSourceInterval?.self) { group in
            if let malID = ids.malID {
                group.addTask {
                    do {
                        let intervals = try await aniSkipClient.skipTimes(
                            malID: malID,
                            episodeNumber: episodeNumber,
                            episodeLengthSeconds: durationSeconds)
                        // 复用 AniSkip 的区间钳制（10-1800s、≤400s）。
                        var hint: DanmakuIntroHint?
                        if let intervals {
                            hint = DanmakuIntroHint(aniskipIntervals: intervals)
                        }
                        guard let hint else { return nil }
                        return SkipSourceInterval(
                            source: .aniskip, start: hint.startSeconds, end: hint.endSeconds)
                    } catch {
                        NetworkLog.report(
                            category: "AniSkip", level: .info,
                            "AniSkip 跳过片头查询失败",
                            fields: ["error": .string("\(error)")])
                        return nil
                    }
                }
            }
            if let animeSkipClient, let anilistID = ids.anilistID {
                group.addTask {
                    do {
                        guard let interval = try await animeSkipClient.introInterval(
                            anilistID: anilistID,
                            seasonNumber: seasonNumber,
                            episodeNumber: episodeNumber)
                        else { return nil }
                        return SkipSourceInterval(
                            source: .animeSkip,
                            start: interval.startSeconds, end: interval.endSeconds)
                    } catch {
                        NetworkLog.report(
                            category: "AnimeSkip", level: .info,
                            "anime-skip 查询失败",
                            fields: ["error": .string("\(error)")])
                        return nil
                    }
                }
            }
            if let theIntroDBClient, let seriesTmdbID {
                group.addTask {
                    do {
                        guard let interval = try await theIntroDBClient.introInterval(
                            tmdbID: seriesTmdbID,
                            seasonNumber: seasonNumber,
                            episodeNumber: episodeNumber)
                        else { return nil }
                        return SkipSourceInterval(
                            source: .theIntroDB,
                            start: interval.startSeconds, end: interval.endSeconds)
                    } catch {
                        // 404（该集无收录）是常态,debug 即可。
                        NetworkLog.report(
                            category: "TheIntroDB", level: .debug,
                            "TheIntroDB 查询无结果或失败",
                            fields: ["error": .string("\(error)")])
                        return nil
                    }
                }
            }
            for await result in group {
                if let result { found.append(result) }
            }
        }
        NetworkLog.report(
            category: "AniSkip", level: found.isEmpty ? .debug : .info,
            "多源跳过时间查询完成",
            fields: [
                "sourceCount": .integer(Int64(found.count)),
                "sources": .string(found.map(\.source.rawValue).joined(separator: ",")),
            ])
        guard let best = Self.selectBestInterval(found) else { return nil }
        return DanmakuIntroHint(
            startSeconds: best.start,
            endSeconds: best.end,
            evidenceCount: best.votes,
            source: best.source
        )
    }

    /// 兄弟集提示聚合（零请求）：同一 animeID 其他集已持久化的 `.danmaku` 提示,
    /// end ±5s 聚簇,≥2 集一致才采纳中位数。只聚合同源证据——不同集可有冷开场/
    /// 前情,位置本就会漂移,「同番 OP 一致」的前提只在弹幕推导内部成立。
    func siblingAggregatedHint(match: DanmakuEpisodeMatch) async -> DanmakuIntroHint? {
        guard let animeID = match.animeID ?? match.derivedAnimeID else { return nil }
        let siblings = await service.siblingIntroHints(animeID: animeID, excluding: match.episodeID)
        guard siblings.count >= 2 else { return nil }
        let ends = siblings.map(\.endSeconds).sorted()
        var clusters: [[Double]] = [[ends[0]]]
        for end in ends.dropFirst() {
            if end - (clusters[clusters.count - 1].last ?? end) <= 5 {
                clusters[clusters.count - 1].append(end)
            } else {
                clusters.append([end])
            }
        }
        guard let best = clusters.max(by: { $0.count < $1.count }), best.count >= 2 else { return nil }
        let end = Self.median(best)
        // 起点:一致集的起点也一致(±5s)才带,否则 nil(消费侧回落到 0)。
        let starts = siblings
            .filter { abs($0.endSeconds - end) <= 5 }
            .compactMap(\.startSeconds)
            .sorted()
        let start: Double?
        if starts.count >= 2, (starts.last ?? 0) - (starts.first ?? 0) <= 5 {
            start = Self.median(starts)
        } else {
            start = nil
        }
        return DanmakuIntroHint(
            startSeconds: start, endSeconds: end, evidenceCount: best.count, source: .danmaku)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// 一路社区源返回的区间（多源聚合的中间形态）。internal 供测试用。
    struct SkipSourceInterval: Sendable {
        let source: DanmakuIntroHintSource
        let start: Double?
        let end: Double
    }

    /// 多源区间选优：end ±10s 聚簇,票多者胜（中位数,来源标簇内优先级最高者）;
    /// 无一致时取优先级最高的单源。
    static func selectBestInterval(
        _ intervals: [SkipSourceInterval]
    ) -> (start: Double?, end: Double, votes: Int, source: DanmakuIntroHintSource)? {
        guard !intervals.isEmpty else { return nil }
        let sorted = intervals.sorted { $0.end < $1.end }
        var clusters: [[SkipSourceInterval]] = [[sorted[0]]]
        for interval in sorted.dropFirst() {
            if interval.end - (clusters[clusters.count - 1].last?.end ?? interval.end) <= 10 {
                clusters[clusters.count - 1].append(interval)
            } else {
                clusters.append([interval])
            }
        }
        // 票数多者优先;并列取来源优先级高的簇（首个元素的来源代表该簇）。
        let best = clusters.max { a, b in
            a.count != b.count
                ? a.count < b.count
                : Self.sourcePriority(a[0].source) < Self.sourcePriority(b[0].source)
        } ?? [sorted[0]]
        if best.count >= 2 {
            let ends = best.map(\.end).sorted()
            let mid = ends.count / 2
            let end = ends.count.isMultiple(of: 2) ? (ends[mid - 1] + ends[mid]) / 2 : ends[mid]
            let starts = best.compactMap(\.start).sorted()
            let start: Double?
            if starts.isEmpty {
                start = nil
            } else if starts.count.isMultiple(of: 2) {
                start = (starts[starts.count / 2 - 1] + starts[starts.count / 2]) / 2
            } else {
                start = starts[starts.count / 2]
            }
            let source = best.map(\.source).max {
                Self.sourcePriority($0) < Self.sourcePriority($1)
            } ?? best[0].source
            return (start, end, best.count, source)
        }
        return (best[0].start, best[0].end, 1, best[0].source)
    }

    /// 聚合 tie-break 用的来源可信度（与 App 侧 SkipMarkSource.rank 同序）。
    private static func sourcePriority(_ source: DanmakuIntroHintSource) -> Int {
        switch source {
        case .aniskip: 5
        case .animeSkip: 4
        case .learned: 3
        case .theIntroDB: 2
        case .danmaku: 1
        }
    }

    private func userMessage(for error: Error) -> String {
        switch error {
        case AutomaticMatchError.fingerprintUnavailable:
            "无法读取媒体指纹，请手动选择弹幕"
        case let danmakuError as DandanplayError:
            danmakuError.userMessage
        default:
            "弹幕加载失败"
        }
    }

    private static func matchTitle(_ match: DanmakuEpisodeMatch) -> String {
        [match.animeTitle, match.episodeTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            .nilIfEmpty ?? "弹弹play"
    }
}

/// 自动匹配需要的媒体上下文。app 层把 `DanmakuPlaybackContext` 映射到这个结构。
public struct DanmakuMatchContext: Sendable {
    public let uuid: UUID
    /// 与 `DanmakuPlaybackContext.cacheKey` 同源的缓存键。
    public let cacheKey: String
    public let allowsCachedMatchReuse: Bool
    public let fileName: String
    public let fileSize: Int64?
    public let durationSeconds: Int?
    public let animeTitle: String?
    /// 媒体库的原生标题（Jellyfin OriginalTitle，番剧库多为日文原名）。
    /// AniList 搜索候选：dandanplay 的中文标题常常搜不中，这是主要生路之一。
    public let originalTitle: String?
    /// 剧集条目的 seriesID（Jellyfin）；standalone 为 nil。
    public let seriesID: String?
    /// **剧集级** TMDB ID（TheIntroDB 用）。注意 Jellyfin 集条目 ProviderIds 里的
    /// Tmdb 是**集级** ID，必须由 app 层按 seriesID 换出剧集级 ID 后填到这里。
    /// 可变：coordinator 在发起解析前回填。
    public var seriesTmdbID: Int?
    public let episodeNumber: Int?
    public let seasonNumber: Int?
    public let isFinal: Bool
    public let tmdbID: Int?
    /// ProviderIds 直取的 MyAnimeList / AniList ID（AniSkip 跳过片头数据源用，可缺省）。
    public let malID: Int?
    public let anilistID: Int?
    /// 目标是剧场版/电影（`MediaItem.kind == .movie`）。剧场版与剧集互斥。
    public let isMovie: Bool
    /// 目标是特典（Jellyfin season 0 / 文件名关键词命中）；`index` 是特典序号。
    public let special: DanmakuSpecialTarget?
    private let localFileURL: URL?
    private let remoteURL: URL?
    private let remoteHeaders: [String: String]

    public init(
        uuid: UUID,
        cacheKey: String,
        allowsCachedMatchReuse: Bool,
        fileName: String,
        fileSize: Int64? = nil,
        durationSeconds: Int? = nil,
        localFileURL: URL? = nil,
        remoteURL: URL? = nil,
        remoteHeaders: [String: String] = [:],
        animeTitle: String? = nil,
        originalTitle: String? = nil,
        seriesID: String? = nil,
        seriesTmdbID: Int? = nil,
        episodeNumber: Int? = nil,
        seasonNumber: Int? = nil,
        isFinal: Bool = false,
        tmdbID: Int? = nil,
        malID: Int? = nil,
        anilistID: Int? = nil,
        isMovie: Bool = false,
        special: DanmakuSpecialTarget? = nil
    ) {
        self.uuid = uuid
        self.cacheKey = cacheKey
        self.allowsCachedMatchReuse = allowsCachedMatchReuse
        self.fileName = fileName
        self.fileSize = fileSize
        self.durationSeconds = durationSeconds
        self.localFileURL = localFileURL
        self.remoteURL = remoteURL
        self.remoteHeaders = remoteHeaders
        self.animeTitle = animeTitle
        self.originalTitle = originalTitle
        self.seriesID = seriesID
        self.seriesTmdbID = seriesTmdbID
        self.episodeNumber = episodeNumber
        self.seasonNumber = seasonNumber
        self.isFinal = isFinal
        self.tmdbID = tmdbID
        self.malID = malID
        self.anilistID = anilistID
        self.isMovie = isMovie
        self.special = special
    }

    /// 计算媒体指纹：本地文件读前 16 MiB；远程走 Range 请求。都不支持返回 nil。
    public func mediaHash(session: URLSession) async throws -> String? {
        if let url = localFileURL {
            let hashTask = Task.detached(priority: .utility) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try FileHash.head16MiBMD5(at: url)
            }
            return try await withTaskCancellationHandler {
                try await hashTask.value
            } onCancel: {
                hashTask.cancel()
            }
        }
        if let url = remoteURL,
           url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
            return try await FileHash.head16MiBMD5(
                from: url,
                headers: remoteHeaders,
                expectedFileSize: fileSize,
                session: session
            )
        }
        return nil
    }
}

/// 自动匹配错误。`fingerprintUnavailable` 表示无法读取媒体指纹（应引导手动选择）。
public enum AutomaticMatchError: Error {
    case fingerprintUnavailable
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

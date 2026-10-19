import CryptoKit
import CoreModel
import DanmakuKit
import DiagnosticsKit
import Foundation
import Observation

struct DanmakuLoadedSummary: Equatable {
    let episodeID: Int64
    let title: String
    let commentCount: Int
}

struct DanmakuSearchSuggestion: Equatable {
    let anime: String
    let episode: String
}

enum DanmakuLoadStatus: Equatable {
    case idle
    case disabled
    case unconfigured
    case matching
    case loadingComments
    case loaded(DanmakuLoadedSummary)
    case noMatch
    case empty(title: String)
    case failed(message: String)

    /// 给 HUD 用的完整显示文案：基础 `label` + 「匹配中/获取中」时的已等待秒数。
    ///
    /// `LIVE-01`：真实会话里弹幕首次装载要 11.1 s（其中 10.4 s 是网关往返），
    /// 期间只显示静态的「正在匹配」会让用户以为卡死。这里把已等待时长带出去，
    /// 用户能看到它**在动**，配合本来就有的「重新匹配」入口就能自己脱困。
    func displayLabel(elapsedSeconds: Int) -> String {
        switch self {
        case .matching, .loadingComments:
            elapsedSeconds > 0 ? "\(label) · \(elapsedSeconds)s" : label
        default:
            label
        }
    }

    var label: String {
        switch self {
        case .idle: "等待加载"
        case .disabled: "自动加载已关闭"
        case .unconfigured: "弹幕网关未配置"
        case .matching: "正在匹配"
        case .loadingComments: "正在获取弹幕"
        case .loaded(let summary): "\(summary.title) · \(summary.commentCount) 条"
        case .noMatch: "未匹配到剧集"
        case .empty(let title): "\(title) · 暂无弹幕"
        case .failed(let message): message
        }
    }
}

struct DanmakuPlaybackContext {
    enum SourceKind: String {
        case jellyfin
        case localFile
        case remoteURL
    }

    /// 匹配上下文（DanmakuKit 的输入）。匹配字段只在这一份——此前这里平铺约 20 个
    /// 字段与 `DanmakuMatchContext` 互为孪生，靠 `matchContext(from:)` 手工逐字段
    /// 映射对齐，加一个字段要同步改三处。
    let match: DanmakuMatchContext
    let sourceKind: SourceKind
    /// 手动搜索的预填（作品名 / 集数）：UI 预填语，不参与匹配输入，
    /// 所以不在 `DanmakuMatchContext` 里。
    let suggestedAnime: String
    let suggestedEpisode: String

    /// 播放请求 id（`match.uuid` 的 App 层语义别名）。
    var requestID: PlaybackRequest.ID { match.uuid }

    static func jellyfin(
        item: MediaItem,
        request: PlaybackRequest,
        serverProfileID: String
    ) -> DanmakuPlaybackContext {
        let source = request.sessionContext
        let rawFileName = normalizedFileName(
            source?.mediaSourcePath,
            source?.mediaSourceName,
            request.title
        )
        let seriesName = (item.seriesName ?? item.name).trimmingCharacters(in: .whitespacesAndNewlines)
        // 原生标题在集条目上一般继承剧集值；空串按缺失处理。
        let originalTitle = item.originalTitle.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.flatMap { $0.isEmpty ? nil : $0 }
        let seasonNumber = item.seasonNumber
        let episodeNumber = item.episodeNumber
        let tmdbID = item.tmdbID.flatMap(Int.init)
        let special = jellyfinSpecialTarget(
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            keywordText: [rawFileName, request.title, item.name].joined(separator: " ")
        )

        // 文件名：含番剧名就原样用，否则合成规范名（剥扩展名、不拼回原始文件名——
        // 尾部裸数字会把弹弹play 的模糊匹配带偏，见 canonicalMatchName 注释）。
        let fileName = DanmakuFilenameParser.canonicalMatchName(
            seriesTitle: seriesName,
            season: seasonNumber,
            episode: matchEpisodeToken(number: episodeNumber, special: special),
            rawFileName: rawFileName
        )

        let sourceID = source?.mediaSourceID ?? "default"
        let fileSize = source?.mediaSourceSize.map(Int64.init)
        let durationSeconds = roundedSeconds(source?.durationSeconds ?? item.runtimeSeconds)
        let cacheIdentity = [
            serverProfileID, item.id, sourceID, rawFileName,
            fileSize.map(String.init) ?? "unknown-size",
            durationSeconds.map(String.init) ?? "unknown-duration",
        ].joined(separator: "\n")
        return DanmakuPlaybackContext(
            match: DanmakuMatchContext(
                uuid: request.id,
                cacheKey: "jellyfin:\(sha256(cacheIdentity))",
                allowsCachedMatchReuse: true,
                fileName: fileName,
                fileSize: fileSize,
                durationSeconds: durationSeconds,
                localFileURL: nil,
                remoteURL: URL(string: request.uri),
                remoteHeaders: request.authHeader.map { ["Authorization": $0] } ?? [:],
                animeTitle: seriesName.isEmpty ? nil : seriesName,
                originalTitle: originalTitle,
                seriesID: item.seriesID,
                episodeNumber: episodeNumber,
                seasonNumber: seasonNumber,
                isFinal: false,
                tmdbID: tmdbID,
                malID: item.malID.flatMap(Int.init),
                anilistID: item.anilistID.flatMap(Int.init),
                isMovie: item.kind == .movie,
                special: special
            ),
            sourceKind: .jellyfin,
            suggestedAnime: seriesName,
            suggestedEpisode: episodeNumber.map(String.init) ?? ""
        )
    }

    static func standalone(request: PlaybackRequest) -> DanmakuPlaybackContext {
        let localURL = request.securityScopedURL
            ?? (FileManager.default.fileExists(atPath: request.uri)
                ? URL(fileURLWithPath: request.uri) : nil)
        let remoteURL = localURL == nil ? URL(string: request.uri) : nil
        let metadata = localURL.map(localFileMetadata)
        let fileSize = metadata?.size
        let modificationDate = metadata?.modificationDate
        let identity: String
        let allowsCachedMatchReuse: Bool
        if let localURL, let fileSize, let modificationDate {
            identity = [
                localURL.standardizedFileURL.path,
                String(fileSize),
                String(modificationDate.timeIntervalSinceReferenceDate.bitPattern, radix: 16),
            ].joined(separator: ":")
            allowsCachedMatchReuse = true
        } else {
            identity = remoteURL?.absoluteString ?? request.uri
            allowsCachedMatchReuse = false
        }

        let rawFileName = normalizedFileName(localURL?.lastPathComponent, remoteURL?.lastPathComponent, request.title)
        let parsed = DanmakuFilenameParser.parse(rawFileName)

        // 若本地文件名为简单数字或短词（如 01.mp4, S01E01.mkv），尝试从父文件夹或祖父文件夹推断番剧名
        var effectiveAnimeTitle = parsed.title
        if let localURL {
            let parentDir = localURL.deletingLastPathComponent().lastPathComponent
            let parentParsed = DanmakuFilenameParser.parse(parentDir)
            if (parsed.title.count <= 3 || parsed.title.allSatisfy({ $0.isNumber || $0.isWhitespace })) && !parentDir.isEmpty {
                if parentParsed.seasonNumber != nil && parentParsed.title.isEmpty {
                    let grandParent = localURL.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                    if !grandParent.isEmpty {
                        effectiveAnimeTitle = grandParent
                    }
                } else {
                    effectiveAnimeTitle = parentDir
                }
            }
        }

        let suggestedAnime = effectiveAnimeTitle.isEmpty ? rawFileName : effectiveAnimeTitle
        let suggestedEpisode = parsed.episodeNumber.map(String.init) ?? ""
        let special = standaloneSpecialTarget(parsed: parsed, rawFileName: rawFileName)
        let fileName = DanmakuFilenameParser.canonicalMatchName(
            seriesTitle: effectiveAnimeTitle,
            season: parsed.seasonNumber,
            episode: matchEpisodeToken(number: parsed.episodeNumber, special: special),
            rawFileName: rawFileName
        )

        return DanmakuPlaybackContext(
            match: DanmakuMatchContext(
                uuid: request.id,
                cacheKey: "standalone:\(sha256(identity))",
                allowsCachedMatchReuse: allowsCachedMatchReuse,
                fileName: fileName,
                fileSize: fileSize,
                durationSeconds: nil,
                localFileURL: localURL,
                remoteURL: remoteURL,
                remoteHeaders: request.authHeader.map { ["Authorization": $0] } ?? [:],
                animeTitle: effectiveAnimeTitle.isEmpty ? nil : effectiveAnimeTitle,
                originalTitle: nil,
                seriesID: nil,
                episodeNumber: parsed.episodeNumber,
                seasonNumber: parsed.seasonNumber,
                isFinal: parsed.isFinal,
                tmdbID: nil,
                malID: nil,
                anilistID: nil,
                isMovie: false,
                special: special
            ),
            sourceKind: localURL == nil ? .remoteURL : .localFile,
            suggestedAnime: suggestedAnime,
            suggestedEpisode: suggestedEpisode
        )
    }

    /// 特典判定（Jellyfin 源）：season 0 是唯一可靠信号——season 1 里编号靠后的 OVA
    /// 在弹弹play 常被编成正片「第 N 话」，猜成特典反而扣分。命名空间按文件名关键词猜，
    /// 猜不出交给 `fallbackOrder`（S→C→O）依次试。
    private static func jellyfinSpecialTarget(
        seasonNumber: Int?,
        episodeNumber: Int?,
        keywordText: String
    ) -> DanmakuSpecialTarget? {
        guard seasonNumber == 0, let index = episodeNumber, index >= 1 else { return nil }
        let kinds = DanmakuSpecialKeyword.kind(in: keywordText).map { [$0] }
            ?? DanmakuSpecialKind.fallbackOrder
        return DanmakuSpecialTarget(index: index, kinds: kinds)
    }

    /// 特典判定（本地文件）：文件名是唯一线索，序号缺失时按第 1 集处理。
    private static func standaloneSpecialTarget(
        parsed: ParsedAnimeInfo,
        rawFileName: String
    ) -> DanmakuSpecialTarget? {
        guard let kind = DanmakuSpecialKeyword.kind(in: rawFileName) else { return nil }
        return DanmakuSpecialTarget(index: parsed.episodeNumber ?? 1, kinds: [kind])
    }

    /// 匹配用集号：特典走命名空间 token（`S2`/`C1`），正片走集数。
    private static func matchEpisodeToken(
        number: Int?,
        special: DanmakuSpecialTarget?
    ) -> DanmakuEpisodeToken? {
        if let special { return .special(kind: special.kinds[0], index: special.index) }
        return number.map { .number($0) }
    }

    private static func normalizedFileName(_ candidates: String?...) -> String {
        for raw in candidates {
            guard let raw else { continue }
            let component = raw.replacingOccurrences(of: "\\", with: "/")
                .split(separator: "/").last.map(String.init) ?? raw
            let name = (component as NSString).deletingPathExtension
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        return "video"
    }

    private static func roundedSeconds(_ value: Double?) -> Int? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Int(value.rounded())
    }

    private static func localFileMetadata(_ url: URL) -> (size: Int64?, modificationDate: Date?) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return (values?.fileSize.map(Int64.init), values?.contentModificationDate)
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
@Observable
final class DanmakuCoordinator {

    private(set) var status: DanmakuLoadStatus = .idle {
        didSet { updateStatusTicker() }
    }

    /// 当前这次装载**已经开始多少秒**（`LIVE-01`）。
    ///
    /// ## 为什么需要它
    ///
    /// 真实会话实测：弹幕首次装载 **11.1 s**，其中 **10.4 s 是网关往返**
    /// （+8.6 s 首次请求以 500 失败 → +11.1 s 重试成功）—— 不是 App 的计算。
    /// 而 HUD 在这 11 秒里只显示一句静态的「正在匹配」，用户完全看不出
    /// 「是在慢慢跑」还是「已经卡死」。
    ///
    /// 这里只在 `.matching` / `.loadingComments` 期间由一个每秒推进的任务维护；
    /// 其它状态一律 0。UI 拿它显示「正在匹配 · 6s」并配「重新匹配」入口
    /// （那个入口本来就有，见 `PlayerHUDActions`）。**不改超时**：
    /// 实测首次请求 8.6 s 就返回了 500 错误，压超时并不能解决网关慢的问题。
    private(set) var statusElapsedSeconds: Int = 0

    @ObservationIgnored private var statusTicker: Task<Void, Never>?
    private(set) var currentMatch: DanmakuEpisodeMatch?
    /// 弹幕推导的片头提示（已注入当前播放会话）。
    private(set) var currentIntroHint: DanmakuIntroHint?
    private(set) var isAutoLoadingEnabled: Bool

    @ObservationIgnored private let orchestrator: DanmakuLoadOrchestrator
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var context: DanmakuPlaybackContext?
    @ObservationIgnored private let titleAliasResolver: DanmakuTitleAliasResolver
    @ObservationIgnored private let animeSkipSettings = AnimeSkipSettingsStore()
    @ObservationIgnored private let introLearningStore: IntroLearningStore
    /// seriesID → 剧集级 TMDB ID（TheIntroDB 用）。AppModel 注入（有服务器客户端）；
    /// nil = 不查 TheIntroDB。
    @ObservationIgnored var seriesTmdbIDProvider: (@Sendable (String) async -> Int?)?
    /// 本次播放已换出的剧集级 TMDB ID（同一 requestID 只换一次）。
    @ObservationIgnored private var seriesTmdbIDCache: (requestID: PlaybackRequest.ID, value: Int?)?
    @ObservationIgnored private var configuration: DandanplayConfiguration?
    @ObservationIgnored private weak var playback: PlaybackController?

    init(session: URLSession = DanmakuNetworking.makeSession()) {
        let defaults = UserDefaults.standard
        isAutoLoadingEnabled = defaults.object(forKey: SettingsKeys.danmakuAutoLoad) == nil
            ? true : defaults.bool(forKey: SettingsKeys.danmakuAutoLoad)
        let directory = OcPlayerStorage.directory("Danmaku")
        let service = DanmakuService(cache: DanmakuCache(directory: directory))
        let introLearningStore = IntroLearningStore(directory: directory)
        // 别名桥（手动搜索合并用）：弹弹play 搜索认不得「另一个中文译名」，Bangumi 的
        // nameCN 能把本地译名换到弹弹play 库里的标题（永久缓存，负缓存 7 天）。
        titleAliasResolver = DanmakuTitleAliasResolver(
            store: DanmakuTitleAliasStore(directory: directory),
            provider: BangumiTitleAliasProvider()
        )
        orchestrator = DanmakuLoadOrchestrator(
            service: service,
            session: session,
            titleAliases: titleAliasResolver,
            // anime-skip 填了 client ID 才启用；闭包惰性取值,设置改动即时生效。
            animeSkipClientProvider: { [animeSkipSettings, session] in
                animeSkipSettings.clientID.map { AnimeSkipClient(clientID: $0, session: session) }
            },
            theIntroDBClient: TheIntroDBClient(session: session),
            introLearningStore: introLearningStore
        )
        self.introLearningStore = introLearningStore
        self.session = session
    }

    func setAutoLoadingEnabled(_ enabled: Bool) {
        guard enabled != isAutoLoadingEnabled else { return }
        isAutoLoadingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: SettingsKeys.danmakuAutoLoad)
        if !enabled {
            invalidateLoad()
            status = .disabled
        }
    }

    func start(
        context: DanmakuPlaybackContext,
        configuration: DandanplayConfiguration?,
        playback: PlaybackController?,
        forceRematch: Bool = false
    ) {
        cancel(resetStatus: false)
        self.context = context
        self.configuration = configuration
        self.playback = playback
        // 片头学习数据源:用户主动 seek 由播放器侧喂进来(范围过滤见 handleUserSeek)。
        playback?.onUserSeek = { [weak self] from, to in
            self?.handleUserSeek(fromSeconds: from, toSeconds: to)
        }
        currentMatch = nil
        currentIntroHint = nil

        guard isAutoLoadingEnabled || forceRematch else {
            status = .disabled
            return
        }
        guard let configuration else {
            status = .unconfigured
            return
        }
        guard let playback else {
            status = .failed(message: "播放器尚未就绪")
            return
        }

        let generation = loadGeneration
        loadTask = Task { [weak self] in
            await self?.loadAutomatically(
                context: context,
                configuration: configuration,
                playback: playback,
                forceRematch: forceRematch,
                generation: generation
            )
        }
    }

    func retryAutomaticMatch() {
        guard let context else { return }
        start(
            context: context,
            configuration: configuration,
            playback: playback,
            forceRematch: true
        )
    }

    func cancel(resetStatus: Bool = true) {
        invalidateLoad()
        context = nil
        configuration = nil
        playback = nil
        currentMatch = nil
        currentIntroHint = nil
        if resetStatus { status = .idle }
    }

    func searchSuggestion(for requestID: PlaybackRequest.ID?) -> DanmakuSearchSuggestion? {
        guard let requestID, context?.requestID == requestID, let context else { return nil }
        return DanmakuSearchSuggestion(
            anime: context.suggestedAnime,
            episode: context.suggestedEpisode
        )
    }

    /// 别名检索最多还能占用多久 —— **这是「主检索之后的追加等待」，必须短**。
    ///
    /// ## ⚠️ 取 1.5 s 是错的，实测推翻了原注释
    ///
    /// 第一版写 1.5 s，注释还声称「主检索回来即可用」。**不成立**：返回值只有一个，
    /// 主检索回来后仍要 `await` 别名链才能组装最终结果。独立审查用同构场景实测
    /// （main 10 ms / alias 900 ms / budget 1500 ms）：`mainReadyAt=11ms
    /// returnedAt=957ms` —— 调用方多等了 **946 ms**。那等于把「串行 10–20 s」
    /// 换成「串行 min(别名, 1.5 s)」，典型场景收益接近零。
    ///
    /// 清单对这条的建议本来就是「别名合并降级为非阻塞；**给该步单独设短超时**」。
    /// 所以取 **300 ms**：这是「主结果已经在手，还愿意为多找回几部再等多久」的上限，
    /// 不是请求超时。别名命中时多是本地缓存的标题解析（微秒级）+ 一次网关往返，
    /// 300 ms 够覆盖缓存命中与同城往返；覆盖不了的场景就放弃 —— 它是增强，不是前提。
    nonisolated static let aliasBudget: Duration = .milliseconds(300)

    /// 有界等待一个尚未完成的并发工作；超时返回 nil（放弃，不取消也不报错）。
    ///
    /// 为什么不用 `withTimeout` 之类：这里**不想**取消 `work` —— 它已经飞出去了，
    /// 取消反而要多写一层 Task 管理。让它在后台自然结束、我们不等就行。
    /// 用 `TaskGroup` 竞速：先返回的那个决定结果，另一个被 group 取消（对我们无害）。
    nonisolated static func boundedValue<T: Sendable>(
        of work: Task<T, Never>,
        within budget: Duration
    ) async -> T? {
        // ⚠️ **不能用 `withTaskGroup` 竞速**：group 在作用域结束时**等所有子任务**，
        // 于是超时分支返回后，另一个 `await work.value` 的子任务会把慢任务整个等完
        // —— 等于没超时。实测（第一版就是这样）：预算 50ms、慢任务 1s，
        // 用例耗时 **1.110 s**。
        //
        // 改成「一个计时的 Task + 一个结果槽」：超时分支直接把槽标成已放弃并返回，
        // 慢任务完成时发现槽已关闭就不再写。两边都不阻塞对方。
        let slot = BoundedValueSlot<T>()
        let deadline = Task {
            try? await Task.sleep(for: budget)
            slot.abandon()
        }
        let waiter = Task {
            let value = await work.value
            slot.fulfill(value)
        }
        defer {
            deadline.cancel()
            waiter.cancel()
        }
        return await slot.wait()
    }

    /// 依次试别名，返回第一个非空结果。
    ///
    /// 与改前的循环等价（同一个 `break` 语义：命中就停），只是现在跑在并发分支里。
    /// 依次试别名，返回第一个非空结果。
    ///
    /// `search` 是注入的闭包（而不是直接收 `DanmakuGatewayClient`）—— 那样用例才能
    /// 不碰网络地验证「命中即停」「跳过同名别名」「被取消时提前退出」这三条契约。
    /// 生产调用点传一个包住 client 的闭包。
    nonisolated static func firstNonEmptyAliasResult(
        aliases: @Sendable (String) async -> [String],
        search: @Sendable (String) async -> [AnimeWithEpisodes]?,
        anime: String
    ) async -> [AnimeWithEpisodes]? {
        for alias in await aliases(anime) where alias != anime {
            // 被取消就没有必要继续试下一个别名了（主检索已失败 / 用户已离开）。
            if Task.isCancelled { return nil }
            guard let aliasResult = await search(alias), !aliasResult.isEmpty else { continue }
            return aliasResult
        }
        return nil
    }

    func searchEpisodes(anime: String, episode: String) async throws -> [AnimeWithEpisodes] {
        guard let configuration else { throw DandanplayError.notConfigured }
        let anime = anime.trimmingCharacters(in: .whitespacesAndNewlines)
        let episode = episode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !anime.isEmpty else {
            throw DandanplayError.invalidRequest("请输入作品名")
        }
        AppDiagnostics.logInfo("弹幕手动搜索开始", fields: [
            "anime": .string(anime),
            "episode": episode.isEmpty ? .null : .string(episode),
        ])
        let client = DanmakuGatewayClient(configuration: configuration, session: session)
        let episodeOrNil = episode.isEmpty ? nil : episode
        do {
            // 别名检索**与主检索并发**，不再串在它后面。
            //
            // 改前是「主检索 await 完 → 再 await 别名链」：最坏是两段串行 RTT
            // （网关 `timeoutIntervalForRequest = 10` / `ForResource = 20`，所以是
            // ≤10–20 s 的串行等待），而这期间**网关已经成功返回的结果上不了屏**。
            //
            // 改后：别名链先并发起飞，主检索回来即可用；别名最多再等
            // `aliasBudget`，超时就放弃别名（它只是「多找回几部」的增强，
            // 不是结果正确性的前提）。
            let aliasSearch = Task { [titleAliasResolver] in
                await Self.firstNonEmptyAliasResult(
                    aliases: { [titleAliasResolver] title in
                        await titleAliasResolver.aliases(for: title)
                    },
                    search: { alias in
                        try? await client.searchEpisodes(anime: alias, episode: episodeOrNil)
                            .payload.animes
                    },
                    anime: anime)
            }
            // 主检索抛错时**必须取消**它：否则这个已起飞的任务会跑满网关的
            // 10 s / 20 s 超时，用户重试还会叠加多个孤儿别名链（纯浪费，
            // 还会额外触发 `DanmakuTitleAliasResolver` 的 store 写入）。
            // 改前别名链根本不会启动，所以这条是并发化带来的新责任。
            defer { aliasSearch.cancel() }

            var result = try await client.searchEpisodes(
                anime: anime,
                episode: episode.isEmpty ? nil : episode
            ).payload.animes

            // `boundedValue` 返回 `T?`，而 `T` 本身是 `[AnimeWithEpisodes]?` —— 拍平一层。
            // 外层 nil = 超时放弃别名；内层 nil/空 = 别名链没有命中。
            let aliasResult = await Self.boundedValue(of: aliasSearch, within: Self.aliasBudget) ?? nil
            // 语义说明：改前这个字段表示「别名链路返回了非空结果」；
            // 现在是「别名**带来了新增条目**」（去重后非空）。对结果无影响，
            // 但日志口径变了，所以改名为 `aliasAdded` 以免误读历史日志。
            var aliasAdded = false
            if let aliasResult, !aliasResult.isEmpty {
                let known = Set(result.map(\.animeId))
                let merged = aliasResult.filter { !known.contains($0.animeId) }
                result += merged
                aliasAdded = !merged.isEmpty
            }

            AppDiagnostics.logInfo("弹幕手动搜索完成", fields: [
                "anime": .string(anime),
                "episode": episode.isEmpty ? .null : .string(episode),
                "animeCount": .integer(Int64(result.count)),
                "episodeCount": .integer(Int64(result.reduce(0) { $0 + $1.episodes.count })),
                "aliasAdded": .boolean(aliasAdded),
            ])
            return result
        } catch {
            if Task.isCancelled { throw CancellationError() }
            AppDiagnostics.logWarning("弹幕手动搜索失败", fields: [
                "anime": .string(anime),
                "episode": episode.isEmpty ? .null : .string(episode),
                "error": .string("\(error)"),
            ])
            throw error
        }
    }

    func selectEpisode(
        _ episode: Episode,
        animeTitle: String?,
        for requestID: PlaybackRequest.ID
    ) {
        guard let context, context.requestID == requestID,
              let configuration, let playback
        else { return }
        invalidateLoad()
        let generation = loadGeneration
        status = .loadingComments
        AppDiagnostics.logInfo("弹幕手动选择剧集", fields: [
            "episodeID": .integer(episode.episodeId),
            "anime": animeTitle.map(DiagnosticValue.string) ?? .null,
            "episodeTitle": episode.episodeTitle.map(DiagnosticValue.string) ?? .null,
        ])
        loadTask = Task { [weak self] in
            guard let self else { return }
            guard isCurrent(generation, requestID: requestID) else { return }
            let match = DanmakuEpisodeMatch(
                episodeID: episode.episodeId,
                animeTitle: animeTitle,
                episodeTitle: episode.episodeTitle
            )
            let startedAt = Date()
            let outcome = await orchestrator.runManual(
                match: match,
                uuid: requestID,
                cacheKey: context.match.cacheKey,
                configuration: configuration,
                playback: playback,
                revision: generation,
                matchContext: await resolvedMatchContext(for: context)
            )
            guard isCurrent(generation, requestID: requestID) else { return }
            apply(
                outcome: outcome,
                context: context,
                durationMs: Self.elapsedMilliseconds(since: startedAt)
            )
        }
    }

    /// 只在「匹配中 / 获取中」期间每秒推进 `statusElapsedSeconds`；其它状态停表清零。
    ///
    /// 用 `@ObservationIgnored` 的 Task 持有，避免把任务本身放进观察图。
    private func updateStatusTicker() {
        switch status {
        case .matching, .loadingComments:
            guard statusTicker == nil else { return }
            statusElapsedSeconds = 0
            statusTicker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    self.statusElapsedSeconds += 1
                }
            }
        default:
            statusTicker?.cancel()
            statusTicker = nil
            statusElapsedSeconds = 0
        }
    }

    private func loadAutomatically(
        context: DanmakuPlaybackContext,
        configuration: DandanplayConfiguration,
        playback: PlaybackController,
        forceRematch: Bool,
        generation: UInt64
    ) async {
        guard isCurrent(generation, requestID: context.requestID) else { return }
        status = .matching
        let startedAt = Date()
        AppDiagnostics.logInfo("弹幕自动匹配开始", fields: Self.matchLogFields(for: context))
        let outcome = await orchestrator.runAutomatic(
            matchContext: await resolvedMatchContext(for: context),
            configuration: configuration,
            playback: playback,
            revision: generation,
            forceRematch: forceRematch
        )
        guard isCurrent(generation, requestID: context.requestID) else { return }
        apply(
            outcome: outcome,
            context: context,
            durationMs: Self.elapsedMilliseconds(since: startedAt)
        )
    }

    private func apply(
        outcome: DanmakuLoadOutcome,
        context: DanmakuPlaybackContext,
        durationMs: Int64
    ) {
        switch outcome {
        case .loaded(let episodeID, let commentCount, let title, let introHint):
            currentMatch = DanmakuEpisodeMatch(episodeID: episodeID)
            status = .loaded(DanmakuLoadedSummary(
                episodeID: episodeID,
                title: title,
                commentCount: commentCount
            ))
            deliverIntroHint(introHint, requestID: context.requestID, episodeID: episodeID)
            AppDiagnostics.logInfo("弹幕装载完成", fields: [
                "source": .string(context.sourceKind.rawValue),
                "episodeID": .integer(episodeID),
                "commentCount": .integer(Int64(commentCount)),
                "durationMs": .integer(durationMs),
            ])
        case .noMatch:
            AppDiagnostics.logInfo("弹幕未匹配", fields: [
                "source": .string(context.sourceKind.rawValue),
                "fileName": .string(context.match.fileName),
            ])
            status = .noMatch
        case .empty(let episodeID, let title, let introHint):
            currentMatch = DanmakuEpisodeMatch(episodeID: episodeID)
            status = .empty(title: title)
            deliverIntroHint(introHint, requestID: context.requestID, episodeID: episodeID)
            AppDiagnostics.logInfo("弹幕正文为空", fields: [
                "episodeID": .integer(episodeID),
                "durationMs": .integer(durationMs),
            ])
        case .failed(let message):
            status = .failed(message: message)
            AppDiagnostics.logWarning("弹幕装载失败", fields: [
                "source": .string(context.sourceKind.rawValue),
                "fileName": .string(context.match.fileName),
                "error": .string(message),
            ])
        }
    }

    /// 把片头提示交给当前播放会话（requestID 不匹配的迟到回调由播放器侧丢弃）。
    private func deliverIntroHint(
        _ hint: DanmakuIntroHint?,
        requestID: PlaybackRequest.ID,
        episodeID: Int64
    ) {
        guard let hint else { return }
        currentIntroHint = hint
        AppDiagnostics.logInfo("弹幕片头提示", fields: [
            "episodeID": .integer(episodeID),
            "source": .string(hint.source.rawValue),
            "endSeconds": .integer(Int64(hint.endSeconds)),
            "startSeconds": hint.startSeconds.map { .integer(Int64($0)) } ?? .null,
            "evidence": .integer(Int64(hint.evidenceCount)),
        ])
        playback?.applySkipTimesHint(hint, requestID: requestID)
    }

    // MARK: 片头学习

    /// 用户主动 seek → 片头落点学习。过滤与容差全部走 `IntroLearningPolicy`
    /// （与 DanmakuKit 的聚簇判定同一组参数）：落点在学习窗内、前跳够格才算
    /// 一次有效落点。两条晋升路径见 `IntroLearningStore`。
    private func handleUserSeek(fromSeconds from: Double, toSeconds to: Double) {
        guard let context, let match = currentMatch else { return }
        guard IntroLearningPolicy.landingWindow.contains(to),
              from < to - IntroLearningPolicy.minimumSeekSeconds else { return }
        guard let animeID = match.animeID ?? match.derivedAnimeID else { return }
        let episodeID = match.episodeID
        let requestID = context.requestID
        Task { [weak self] in
            guard let self else { return }
            // 路径一:确认升级——落点与该集既有提示(弹幕推导)end 贴合(容差与聚簇同源),
            // 用户用行为背书了猜测,提示升级为 .learned(防低来源覆盖)。
            if let current = await self.orchestrator.service.cachedIntroHint(for: episodeID),
               current.source == .danmaku,
               abs(to - current.endSeconds) <= IntroLearningPolicy.snapToleranceSeconds {
                let upgraded = DanmakuIntroHint(
                    startSeconds: current.startSeconds,
                    endSeconds: current.endSeconds,
                    evidenceCount: current.evidenceCount + 1,
                    source: .learned)
                await self.introLearningStore.promote(animeID: animeID, hint: upgraded)
                await self.orchestrator.service.persistIntroHint(upgraded, for: episodeID)
                AppDiagnostics.logInfo("片头学习:既有提示获确认升级", fields: [
                    "episodeID": .integer(episodeID),
                    "endSeconds": .integer(Int64(current.endSeconds)),
                ])
                return
            }
            // 路径二:跨集共识——记录落点,≥2 个不同集聚簇(±10s)即晋升推广。
            await self.introLearningStore.record(
                animeID: animeID,
                event: IntroSeekEvent(episodeID: episodeID, position: to, at: Date()))
            guard let consensus = await self.introLearningStore.consensusHint(forAnime: animeID),
                  await self.introLearningStore.promotedHint(forAnime: animeID) == nil
            else { return }
            await self.introLearningStore.promote(animeID: animeID, hint: consensus)
            AppDiagnostics.logInfo("片头学习:跨集共识晋升", fields: [
                "animeID": .integer(animeID),
                "endSeconds": .integer(Int64(consensus.endSeconds)),
                "episodes": .integer(Int64(consensus.evidenceCount)),
            ])
            // 推广到全番:只写「无提示或弹幕推导」的集,不覆盖更高来源
            // (.aniskip/.animeSkip/.theIntroDB/.learned)。
            let episodeIDs = await self.orchestrator.service.episodeIDs(animeID: animeID)
            for id in episodeIDs {
                let existing = await self.orchestrator.service.cachedIntroHint(for: id)
                if existing == nil || existing?.source == .danmaku {
                    await self.orchestrator.service.persistIntroHint(consensus, for: id)
                }
            }
            // 本集若适用,当场升级会话内提示(rank 门槛在 ChapterSession 里挡)。
            if episodeIDs.contains(episodeID) {
                self.playback?.applySkipTimesHint(consensus, requestID: requestID)
            }
        }
    }

    /// 带剧集级 TMDB ID 的匹配上下文（TheIntroDB 源用）。同一播放请求只换一次;
    /// 无 seriesID / 未注入 provider / 服务器查询失败时 seriesTmdbID 保持 nil,
    /// 多源解析器自动跳过 TheIntroDB。
    private func resolvedMatchContext(
        for context: DanmakuPlaybackContext
    ) async -> DanmakuMatchContext {
        var matchContext = context.match
        guard let seriesID = matchContext.seriesID else { return matchContext }
        if let cached = seriesTmdbIDCache, cached.requestID == context.requestID {
            matchContext.seriesTmdbID = cached.value
            return matchContext
        }
        let tmdbID = await seriesTmdbIDProvider?(seriesID) ?? nil
        seriesTmdbIDCache = (context.requestID, tmdbID)
        matchContext.seriesTmdbID = tmdbID
        return matchContext
    }

    private func invalidateLoad() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
    }

    private func isCurrent(_ generation: UInt64, requestID: PlaybackRequest.ID) -> Bool {
        generation == loadGeneration && context?.requestID == requestID
    }

    private static func matchLogFields(
        for context: DanmakuPlaybackContext
    ) -> [String: DiagnosticValue] {
        // 不带 hashPresent：这条日志打在指纹计算**之前**，此刻根本不知道有没有指纹
        // （原先硬编码 true，指纹失败时说谎，排查「为什么降级到文件名匹配」会被带偏）。
        // 真实值由 orchestrator 算完指纹后自己记一条（见 DanmakuLoadOrchestrator）。
        [
            "source": .string(context.sourceKind.rawValue),
            "fileName": .string(context.match.fileName),
            "fileSize": context.match.fileSize.map(DiagnosticValue.integer) ?? .null,
            "videoDuration": context.match.durationSeconds
                .map { DiagnosticValue.integer(Int64($0)) } ?? .null,
            "matchMode": .string(MatchRequest.MatchMode.hashAndFileName.rawValue),
        ]
    }

    private static func elapsedMilliseconds(since start: Date) -> Int64 {
        Int64(max(0, Date().timeIntervalSince(start) * 1_000).rounded())
    }
}

/// 「有界等待」的结果槽：要么拿到值，要么超时放弃。二者先到者生效。
///
/// 用锁 + 一次性 continuation 实现，**不依赖 `TaskGroup` 的作用域语义** ——
/// 后者在作用域结束时会等所有子任务，于是「超时分支返回」仍会被慢任务拖住，
/// 等于没超时（第一版就是这样：预算 50ms、慢任务 1s，用例实测 1.110 s）。
private final class BoundedValueSlot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private var settledValue: T??
    private var continuation: CheckedContinuation<T?, Never>?

    func abandon() { settle(nil) }

    func fulfill(_ value: T) { settle(value) }

    private func settle(_ value: T?) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        settledValue = .some(value)
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }

    func wait() async -> T? {
        await withCheckedContinuation { incoming in
            lock.lock()
            if settled {
                let value = settledValue ?? nil
                lock.unlock()
                incoming.resume(returning: value)
                return
            }
            continuation = incoming
            lock.unlock()
        }
    }
}

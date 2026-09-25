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

    let requestID: PlaybackRequest.ID
    let cacheKey: String
    let allowsCachedMatchReuse: Bool
    let sourceKind: SourceKind
    let fileName: String
    let fileSize: Int64?
    let durationSeconds: Int?
    let localFileURL: URL?
    let remoteURL: URL?
    let remoteHeaders: [String: String]
    let suggestedAnime: String
    let suggestedEpisode: String
    let animeTitle: String?
    let episodeNumber: Int?
    let seasonNumber: Int?
    let isFinal: Bool
    let tmdbID: Int?
    /// ProviderIds 直取的 MyAnimeList / AniList ID（AniSkip 跳过片头用，机会性存在）。
    let malID: Int?
    let anilistID: Int?
    /// 目标是剧场版/电影（`MediaItem.kind == .movie`）。
    let isMovie: Bool
    /// 目标是特典（Jellyfin season 0 / 文件名关键词命中），序号即特典编号。
    let special: DanmakuSpecialTarget?

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
            requestID: request.id,
            cacheKey: "jellyfin:\(sha256(cacheIdentity))",
            allowsCachedMatchReuse: true,
            sourceKind: .jellyfin,
            fileName: fileName,
            fileSize: fileSize,
            durationSeconds: durationSeconds,
            localFileURL: nil,
            remoteURL: URL(string: request.uri),
            remoteHeaders: request.authHeader.map { ["Authorization": $0] } ?? [:],
            suggestedAnime: seriesName,
            suggestedEpisode: episodeNumber.map(String.init) ?? "",
            animeTitle: seriesName.isEmpty ? nil : seriesName,
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            isFinal: false,
            tmdbID: tmdbID,
            malID: item.malID.flatMap(Int.init),
            anilistID: item.anilistID.flatMap(Int.init),
            isMovie: item.kind == .movie,
            special: special
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
            requestID: request.id,
            cacheKey: "standalone:\(sha256(identity))",
            allowsCachedMatchReuse: allowsCachedMatchReuse,
            sourceKind: localURL == nil ? .remoteURL : .localFile,
            fileName: fileName,
            fileSize: fileSize,
            durationSeconds: nil,
            localFileURL: localURL,
            remoteURL: remoteURL,
            remoteHeaders: request.authHeader.map { ["Authorization": $0] } ?? [:],
            suggestedAnime: suggestedAnime,
            suggestedEpisode: suggestedEpisode,
            animeTitle: effectiveAnimeTitle.isEmpty ? nil : effectiveAnimeTitle,
            episodeNumber: parsed.episodeNumber,
            seasonNumber: parsed.seasonNumber,
            isFinal: parsed.isFinal,
            tmdbID: nil,
            malID: nil,
            anilistID: nil,
            isMovie: false,
            special: special
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
    private static let autoLoadKey = "dev.jumusu.ocplayer.danmaku.autoLoad"

    private(set) var status: DanmakuLoadStatus = .idle
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
    @ObservationIgnored private var configuration: DandanplayConfiguration?
    @ObservationIgnored private weak var playback: PlaybackController?

    init(session: URLSession = DanmakuNetworking.makeSession()) {
        let defaults = UserDefaults.standard
        isAutoLoadingEnabled = defaults.object(forKey: Self.autoLoadKey) == nil
            ? true : defaults.bool(forKey: Self.autoLoadKey)
        let directory = URL.applicationSupportDirectory
            .appending(path: "OcPlayer/Danmaku", directoryHint: .isDirectory)
        let service = DanmakuService(cache: DanmakuCache(directory: directory))
        // 别名桥（手动搜索合并用）：弹弹play 搜索认不得「另一个中文译名」，Bangumi 的
        // nameCN 能把本地译名换到弹弹play 库里的标题（永久缓存，负缓存 7 天）。
        titleAliasResolver = DanmakuTitleAliasResolver(
            store: DanmakuTitleAliasStore(directory: directory),
            provider: BangumiTitleAliasProvider()
        )
        orchestrator = DanmakuLoadOrchestrator(service: service, session: session)
        self.session = session
    }

    func setAutoLoadingEnabled(_ enabled: Bool) {
        guard enabled != isAutoLoadingEnabled else { return }
        isAutoLoadingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.autoLoadKey)
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
        do {
            var result = try await client.searchEpisodes(
                anime: anime,
                episode: episode.isEmpty ? nil : episode
            ).payload.animes

            // 别名合并：弹弹play 搜索认不得「另一个中文译名」（实测搜「虽然我是不完美恶女
            // ～雏宫蝶鼠替换传～」返回的全是无关作品），Bangumi 的 nameCN 能换到库内标题。
            // 主检索与别名检索都跑，按 animeId 去重合并——主检索命中正确作品时这一步零成本。
            var aliasHit = false
            for alias in await titleAliasResolver.aliases(for: anime) where alias != anime {
                guard let aliasResult = try? await client.searchEpisodes(
                    anime: alias,
                    episode: episode.isEmpty ? nil : episode
                ).payload.animes, !aliasResult.isEmpty else { continue }
                let known = Set(result.map(\.animeId))
                result += aliasResult.filter { !known.contains($0.animeId) }
                aliasHit = true
                break
            }

            AppDiagnostics.logInfo("弹幕手动搜索完成", fields: [
                "anime": .string(anime),
                "episode": episode.isEmpty ? .null : .string(episode),
                "animeCount": .integer(Int64(result.count)),
                "episodeCount": .integer(Int64(result.reduce(0) { $0 + $1.episodes.count })),
                "aliasHit": .boolean(aliasHit),
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
                cacheKey: context.cacheKey,
                configuration: configuration,
                playback: playback,
                revision: generation,
                matchContext: matchContext(from: context)
            )
            guard isCurrent(generation, requestID: requestID) else { return }
            apply(
                outcome: outcome,
                context: context,
                durationMs: Self.elapsedMilliseconds(since: startedAt)
            )
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
            matchContext: matchContext(from: context),
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
                "fileName": .string(context.fileName),
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
                "fileName": .string(context.fileName),
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

    private func matchContext(from context: DanmakuPlaybackContext) -> DanmakuMatchContext {
        DanmakuMatchContext(
            uuid: context.requestID,
            cacheKey: context.cacheKey,
            allowsCachedMatchReuse: context.allowsCachedMatchReuse,
            fileName: context.fileName,
            fileSize: context.fileSize,
            durationSeconds: context.durationSeconds,
            localFileURL: context.localFileURL,
            remoteURL: context.remoteURL,
            remoteHeaders: context.remoteHeaders,
            animeTitle: context.animeTitle,
            episodeNumber: context.episodeNumber,
            seasonNumber: context.seasonNumber,
            isFinal: context.isFinal,
            tmdbID: context.tmdbID,
            malID: context.malID,
            anilistID: context.anilistID,
            isMovie: context.isMovie,
            special: context.special
        )
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
            "fileName": .string(context.fileName),
            "fileSize": context.fileSize.map(DiagnosticValue.integer) ?? .null,
            "videoDuration": context.durationSeconds
                .map { DiagnosticValue.integer(Int64($0)) } ?? .null,
            "matchMode": .string(MatchRequest.MatchMode.hashAndFileName.rawValue),
        ]
    }

    private static func elapsedMilliseconds(since start: Date) -> Int64 {
        Int64(max(0, Date().timeIntervalSince(start) * 1_000).rounded())
    }
}

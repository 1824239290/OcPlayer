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

    static func jellyfin(
        item: MediaItem,
        request: PlaybackRequest,
        serverProfileID: String
    ) -> DanmakuPlaybackContext {
        let source = request.sessionContext
        let fileName = normalizedFileName(
            source?.mediaSourcePath,
            source?.mediaSourceName,
            request.title
        )
        let sourceID = source?.mediaSourceID ?? "default"
        let fileSize = source?.mediaSourceSize.map(Int64.init)
        let durationSeconds = roundedSeconds(source?.durationSeconds ?? item.runtimeSeconds)
        let cacheIdentity = [
            serverProfileID, item.id, sourceID, fileName,
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
            suggestedAnime: item.seriesName ?? item.name,
            suggestedEpisode: item.episodeNumber.map(String.init) ?? ""
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
        return DanmakuPlaybackContext(
            requestID: request.id,
            cacheKey: "standalone:\(sha256(identity))",
            allowsCachedMatchReuse: allowsCachedMatchReuse,
            sourceKind: localURL == nil ? .remoteURL : .localFile,
            fileName: normalizedFileName(localURL?.lastPathComponent, remoteURL?.lastPathComponent, request.title),
            fileSize: fileSize,
            durationSeconds: nil,
            localFileURL: localURL,
            remoteURL: remoteURL,
            remoteHeaders: request.authHeader.map { ["Authorization": $0] } ?? [:],
            suggestedAnime: normalizedFileName(request.title),
            suggestedEpisode: ""
        )
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
    private(set) var isAutoLoadingEnabled: Bool

    @ObservationIgnored private let service: DanmakuService
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var context: DanmakuPlaybackContext?
    @ObservationIgnored private var configuration: DandanplayConfiguration?
    @ObservationIgnored private weak var playback: PlaybackController?

    init() {
        let defaults = UserDefaults.standard
        isAutoLoadingEnabled = defaults.object(forKey: Self.autoLoadKey) == nil
            ? true : defaults.bool(forKey: Self.autoLoadKey)
        let directory = URL.applicationSupportDirectory
            .appending(path: "OcPlayer/Danmaku", directoryHint: .isDirectory)
        service = DanmakuService(cache: DanmakuCache(directory: directory))
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
        let client = DanmakuGatewayClient(configuration: configuration)
        do {
            let result = try await client.searchEpisodes(
                anime: anime,
                episode: episode.isEmpty ? nil : episode
            ).payload.animes
            AppDiagnostics.logInfo("弹幕手动搜索完成", fields: [
                "anime": .string(anime),
                "episode": episode.isEmpty ? .null : .string(episode),
                "animeCount": .integer(Int64(result.count)),
                "episodeCount": .integer(Int64(result.reduce(0) { $0 + $1.episodes.count })),
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
            await clearExistingDanmaku(
                context: context,
                playback: playback,
                generation: generation
            )
            guard isCurrent(generation, requestID: requestID) else { return }
            let match = await service.remember(
                episode: episode,
                animeTitle: animeTitle,
                cacheKey: context.cacheKey,
                revision: generation
            )
            guard isCurrent(generation, requestID: requestID) else { return }
            await loadPayload(
                match: match,
                context: context,
                configuration: configuration,
                playback: playback,
                generation: generation
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
        let client = DanmakuGatewayClient(configuration: configuration)
        do {
            guard isCurrent(generation, requestID: context.requestID) else { return }
            status = .matching
            await service.claimMatchRevision(cacheKey: context.cacheKey, revision: generation)
            guard isCurrent(generation, requestID: context.requestID) else { return }
            if forceRematch {
                await clearExistingDanmaku(
                    context: context,
                    playback: playback,
                    generation: generation
                )
                guard isCurrent(generation, requestID: context.requestID) else { return }
            }

            if !forceRematch, context.allowsCachedMatchReuse,
               let cachedMatch = await service.cachedMatch(for: context.cacheKey) {
                guard isCurrent(generation, requestID: context.requestID) else { return }
                AppDiagnostics.logInfo("弹幕匹配缓存命中", fields: [
                    "source": .string(context.sourceKind.rawValue),
                    "fileName": .string(context.fileName),
                    "episodeID": .integer(cachedMatch.episodeID),
                ])
                await loadPayload(
                    match: cachedMatch,
                    context: context,
                    configuration: configuration,
                    playback: playback,
                    generation: generation
                )
                return
            }

            let hashStartedAt = Date()
            AppDiagnostics.logInfo("弹幕媒体指纹计算开始", fields: [
                "source": .string(context.sourceKind.rawValue),
                "fileName": .string(context.fileName),
                "fileSize": context.fileSize.map(DiagnosticValue.integer) ?? .null,
                "stage": .string("fingerprint"),
            ])
            let hash: String
            do {
                guard let value = try await mediaHash(for: context) else {
                    throw AutomaticMatchError.fingerprintUnavailable
                }
                hash = value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppDiagnostics.logWarning("弹幕媒体指纹计算失败", fields: [
                    "source": .string(context.sourceKind.rawValue),
                    "fileName": .string(context.fileName),
                    "durationMs": .integer(Self.elapsedMilliseconds(since: hashStartedAt)),
                    "error": .string("\(error)"),
                ])
                throw AutomaticMatchError.fingerprintUnavailable
            }
            try Task.checkCancellation()
            guard isCurrent(generation, requestID: context.requestID) else { return }
            AppDiagnostics.logInfo("弹幕媒体指纹计算完成", fields: [
                "source": .string(context.sourceKind.rawValue),
                "fileName": .string(context.fileName),
                "durationMs": .integer(Self.elapsedMilliseconds(since: hashStartedAt)),
                "hashPresent": .boolean(true),
            ])
            AppDiagnostics.logInfo("弹幕自动匹配请求", fields: Self.matchLogFields(
                for: context,
                hashPresent: true
            ))

            let match = try await service.automaticMatch(
                cacheKey: context.cacheKey,
                request: MatchRequest(
                    fileName: context.fileName,
                    fileHash: hash,
                    fileSize: context.fileSize,
                    videoDuration: context.durationSeconds,
                    matchMode: .hashAndFileName
                ),
                client: client,
                ignoringCachedMatch: true,
                persistingResult: false
            )
            try Task.checkCancellation()
            guard isCurrent(generation, requestID: context.requestID) else { return }
            guard let match else {
                AppDiagnostics.logInfo("弹幕自动匹配完成", fields: [
                    "source": .string(context.sourceKind.rawValue),
                    "fileName": .string(context.fileName),
                    "isMatched": .boolean(false),
                ])
                if forceRematch {
                    await service.forgetMatch(
                        cacheKey: context.cacheKey,
                        revision: generation
                    )
                    guard isCurrent(generation, requestID: context.requestID) else { return }
                }
                status = .noMatch
                return
            }
            AppDiagnostics.logInfo("弹幕自动匹配完成", fields: [
                "source": .string(context.sourceKind.rawValue),
                "fileName": .string(context.fileName),
                "isMatched": .boolean(true),
                "episodeID": .integer(match.episodeID),
            ])
            await service.remember(
                match: match,
                cacheKey: context.cacheKey,
                revision: generation
            )
            guard isCurrent(generation, requestID: context.requestID) else { return }
            await loadPayload(
                match: match,
                context: context,
                configuration: configuration,
                playback: playback,
                generation: generation
            )
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  isCurrent(generation, requestID: context.requestID)
            else { return }
            status = .failed(message: Self.userMessage(for: error))
            AppDiagnostics.logWarning("弹幕自动加载失败", fields: [
                "source": .string(context.sourceKind.rawValue),
                "fileName": .string(context.fileName),
                "error": .string("\(error)"),
            ])
        }
    }

    private func loadPayload(
        match: DanmakuEpisodeMatch,
        context: DanmakuPlaybackContext,
        configuration: DandanplayConfiguration,
        playback: PlaybackController,
        generation: UInt64
    ) async {
        do {
            try Task.checkCancellation()
            guard isCurrent(generation, requestID: context.requestID) else { return }
            currentMatch = match
            status = .loadingComments
            AppDiagnostics.logInfo("弹幕正文请求", fields: [
                "episodeID": .integer(match.episodeID),
            ])
            let payload = try await service.payload(
                for: match,
                client: DanmakuGatewayClient(configuration: configuration)
            )
            try Task.checkCancellation()
            guard isCurrent(generation, requestID: context.requestID) else { return }
            let title = Self.matchTitle(match)
            guard let source = await playback.waitUntilSourceReady(
                for: context.requestID,
                timeout: .seconds(30)
            ) else {
                if !Task.isCancelled,
                   isCurrent(generation, requestID: context.requestID) {
                    status = .failed(message: "视频未就绪，弹幕未装载")
                }
                return
            }
            try Task.checkCancellation()
            guard isCurrent(generation, requestID: context.requestID) else { return }
            let accepted: Bool
            if let json = payload.json {
                accepted = try playback.replaceDanmaku(
                    json: json,
                    name: title,
                    offset: .seconds(Double(match.shiftSeconds)),
                    for: source
                )
            } else {
                accepted = try playback.clearDanmaku(for: source)
            }
            guard accepted else { return }
            if payload.json == nil {
                status = .empty(title: title)
            } else {
                status = .loaded(DanmakuLoadedSummary(
                    episodeID: match.episodeID,
                    title: title,
                    commentCount: payload.commentCount
                ))
            }
            AppDiagnostics.logInfo("弹幕正文装载完成", fields: [
                "episodeID": .integer(match.episodeID),
                "commentCount": .integer(Int64(payload.commentCount)),
                "hasPayload": .boolean(payload.json != nil),
            ])
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  isCurrent(generation, requestID: context.requestID)
            else { return }
            status = .failed(message: Self.userMessage(for: error))
            AppDiagnostics.logWarning("弹幕装载失败", fields: [
                "episodeID": .integer(match.episodeID),
                "error": .string("\(error)"),
            ])
        }
    }

    private func clearExistingDanmaku(
        context: DanmakuPlaybackContext,
        playback: PlaybackController,
        generation: UInt64
    ) async {
        guard let source = await playback.waitUntilSourceReady(
            for: context.requestID,
            timeout: .seconds(1)
        ), isCurrent(generation, requestID: context.requestID)
        else { return }
        do {
            _ = try playback.clearDanmaku(for: source)
        } catch {
            AppDiagnostics.logWarning("清理旧弹幕失败", fields: [
                "error": .string("\(error)"),
            ])
        }
    }

    private func invalidateLoad() {
        loadGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
    }

    private func isCurrent(_ generation: UInt64, requestID: PlaybackRequest.ID) -> Bool {
        generation == loadGeneration && context?.requestID == requestID
    }

    private func mediaHash(for context: DanmakuPlaybackContext) async throws -> String? {
        if let url = context.localFileURL {
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
        if let url = context.remoteURL,
           url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https" {
            return try await FileHash.head16MiBMD5(
                from: url,
                headers: context.remoteHeaders,
                expectedFileSize: context.fileSize
            )
        }
        return nil
    }

    private static func matchTitle(_ match: DanmakuEpisodeMatch) -> String {
        [match.animeTitle, match.episodeTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
            .nilIfEmpty ?? "弹弹play"
    }

    private static func matchLogFields(
        for context: DanmakuPlaybackContext,
        hashPresent: Bool
    ) -> [String: DiagnosticValue] {
        [
            "source": .string(context.sourceKind.rawValue),
            "fileName": .string(context.fileName),
            "fileSize": context.fileSize.map(DiagnosticValue.integer) ?? .null,
            "videoDuration": context.durationSeconds
                .map { DiagnosticValue.integer(Int64($0)) } ?? .null,
            "matchMode": .string(MatchRequest.MatchMode.hashAndFileName.rawValue),
            "hashPresent": .boolean(hashPresent),
        ]
    }

    private static func elapsedMilliseconds(since start: Date) -> Int64 {
        Int64(max(0, Date().timeIntervalSince(start) * 1_000).rounded())
    }

    private static func userMessage(for error: Error) -> String {
        switch error {
        case AutomaticMatchError.fingerprintUnavailable:
            "无法读取媒体指纹，请手动选择弹幕"
        case DandanplayError.unauthorized: "网关 API Key 无效"
        case DandanplayError.rateLimited: "弹幕请求额度已用完"
        case DandanplayError.notConfigured: "弹幕网关未配置"
        case DandanplayError.network: "弹幕网络请求失败"
        case DandanplayError.businessError(_, let message): message ?? "弹幕服务返回错误"
        default: "弹幕加载失败"
        }
    }
}

private enum AutomaticMatchError: Error {
    case fingerprintUnavailable
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

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

    @ObservationIgnored private let orchestrator: DanmakuLoadOrchestrator
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadGeneration: UInt64 = 0
    @ObservationIgnored private var context: DanmakuPlaybackContext?
    @ObservationIgnored private var configuration: DandanplayConfiguration?
    @ObservationIgnored private weak var playback: PlaybackController?

    init(session: URLSession = DanmakuNetworking.makeSession()) {
        let defaults = UserDefaults.standard
        isAutoLoadingEnabled = defaults.object(forKey: Self.autoLoadKey) == nil
            ? true : defaults.bool(forKey: Self.autoLoadKey)
        let directory = URL.applicationSupportDirectory
            .appending(path: "OcPlayer/Danmaku", directoryHint: .isDirectory)
        let service = DanmakuService(cache: DanmakuCache(directory: directory))
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
        let client = DanmakuGatewayClient(configuration: configuration, session: session)
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
            let match = DanmakuEpisodeMatch(
                episodeID: episode.episodeId,
                animeTitle: animeTitle,
                episodeTitle: episode.episodeTitle
            )
            let startedAt = Date()
            let outcome = await orchestrator.runManual(
                match: match,
                cacheKey: context.cacheKey,
                configuration: configuration,
                playback: playback,
                revision: generation
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
        case .loaded(let episodeID, let commentCount, let title):
            currentMatch = DanmakuEpisodeMatch(episodeID: episodeID)
            status = .loaded(DanmakuLoadedSummary(
                episodeID: episodeID,
                title: title,
                commentCount: commentCount
            ))
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
        case .empty(let episodeID, let title):
            currentMatch = DanmakuEpisodeMatch(episodeID: episodeID)
            status = .empty(title: title)
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
            remoteHeaders: context.remoteHeaders
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
        [
            "source": .string(context.sourceKind.rawValue),
            "fileName": .string(context.fileName),
            "fileSize": context.fileSize.map(DiagnosticValue.integer) ?? .null,
            "videoDuration": context.durationSeconds
                .map { DiagnosticValue.integer(Int64($0)) } ?? .null,
            "matchMode": .string(MatchRequest.MatchMode.hashAndFileName.rawValue),
            "hashPresent": .boolean(true),
        ]
    }

    private static func elapsedMilliseconds(since start: Date) -> Int64 {
        Int64(max(0, Date().timeIntervalSince(start) * 1_000).rounded())
    }
}

import Foundation

/// 弹幕装载流水线的编排结果。`DanmakuCoordinator`（app 层）把它映射成
/// HUD 可直接显示的状态；测试用它断言整个 匹配 → 缓存 → 装载 链路的走向。
public enum DanmakuLoadOutcome: Equatable, Sendable {
    case loaded(episodeID: Int64, commentCount: Int, title: String)
    case noMatch
    case empty(episodeID: Int64, title: String)
    case failed(message: String)
}

/// 播放器侧为弹幕装载提供的同步动作。`uuid` 是 `PlaybackRequest.id` 的等价物，
/// 用于区分「同一次播放的不同源代次」与「不同的播放请求」。
/// 标 `@MainActor` 以便 `PlaybackController`（主线程绑定）直接 conform；
/// 编排器在 async 上下文调用时会隐式 hop 到主线程。
@MainActor
public protocol DanmakuPlaybackHosting {
    /// 等待当前播放源就绪（可注入弹幕）。超时或源已切换返回 false。
    func waitUntilReady(uuid: UUID, timeout: Duration) async -> Bool
    /// 装载弹幕 JSON；返回 false 表示播放源已不在当前代次（调用方应放弃并终止）。
    /// 返回值为真时，错误由实现方抛出。
    func replaceDanmaku(
        uuid: UUID,
        json: String,
        name: String,
        offset: Duration
    ) throws -> Bool
    /// 清空当前源上的弹幕；返回 false 语义同上。
    func clearDanmaku(uuid: UUID) throws -> Bool
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

    public init(service: DanmakuService, session: URLSession = DanmakuNetworking.makeSession()) {
        self.service = service
        self.session = session
    }

    /// 整个自动匹配 + 装载链路。`forceRematch` 跳过缓存并清除已记住的映射。
    public func runAutomatic(
        matchContext: DanmakuMatchContext,
        configuration: DandanplayConfiguration,
        playback: DanmakuPlaybackHosting,
        revision: UInt64,
        forceRematch: Bool = false
    ) async -> DanmakuLoadOutcome {
        let client = DanmakuGatewayClient(configuration: configuration, session: session)
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
                    client: client
                )
            }

            let hash: String
            do {
                guard let value = try await matchContext.mediaHash(session: session) else {
                    throw AutomaticMatchError.fingerprintUnavailable
                }
                hash = value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw AutomaticMatchError.fingerprintUnavailable
            }
            try Task.checkCancellation()
            guard await isCurrent(revision, cacheKey: cacheKey) else { return .failed(message: "播放已切换") }

            let match = try await service.automaticMatch(
                cacheKey: cacheKey,
                request: MatchRequest(
                    fileName: matchContext.fileName,
                    fileHash: hash,
                    fileSize: matchContext.fileSize,
                    videoDuration: matchContext.durationSeconds,
                    matchMode: .hashAndFileName
                ),
                client: client,
                ignoringCachedMatch: true,
                persistingResult: false
            )
            try Task.checkCancellation()
            guard await isCurrent(revision, cacheKey: cacheKey) else { return .failed(message: "播放已切换") }
            guard let match else {
                if forceRematch {
                    await service.forgetMatch(cacheKey: cacheKey, revision: revision)
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
                client: client
            )
        } catch is CancellationError {
            return .failed(message: "已取消")
        } catch {
            guard await isCurrent(revision, cacheKey: cacheKey) else { return .failed(message: "播放已切换") }
            return .failed(message: userMessage(for: error))
        }
    }

    /// 用户手动选择某一集后的装载。
    public func runManual(
        match: DanmakuEpisodeMatch,
        uuid: UUID,
        cacheKey: String,
        configuration: DandanplayConfiguration,
        playback: DanmakuPlaybackHosting,
        revision: UInt64
    ) async -> DanmakuLoadOutcome {
        let client = DanmakuGatewayClient(configuration: configuration, session: session)
        await service.remember(match: match, cacheKey: cacheKey, revision: revision)
        return await loadPayload(
            match: match,
            uuid: uuid,
            cacheKey: cacheKey,
            configuration: configuration,
            playback: playback,
            revision: revision,
            client: client
        )
    }

    private func loadPayload(
        match: DanmakuEpisodeMatch,
        uuid: UUID,
        cacheKey: String,
        configuration: DandanplayConfiguration,
        playback: DanmakuPlaybackHosting,
        revision: UInt64,
        client: DanmakuGatewayClient
    ) async -> DanmakuLoadOutcome {
        do {
            try Task.checkCancellation()
            let payload = try await service.payload(
                for: match,
                client: client
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
            if let json = payload.json {
                accepted = try await playback.replaceDanmaku(
                    uuid: uuid,
                    json: json,
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
            if payload.json == nil {
                return .empty(episodeID: match.episodeID, title: name)
            }
            return .loaded(episodeID: match.episodeID, commentCount: payload.commentCount, title: name)
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
    private let localFileURL: URL?
    private let remoteURL: URL?
    private let remoteHeaders: [String: String]

    public init(
        uuid: UUID,
        cacheKey: String,
        allowsCachedMatchReuse: Bool,
        fileName: String,
        fileSize: Int64?,
        durationSeconds: Int?,
        localFileURL: URL?,
        remoteURL: URL?,
        remoteHeaders: [String: String]
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

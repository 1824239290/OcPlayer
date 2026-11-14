import CoreModel
import Foundation
import OcPlayerCore

public struct PreparedPlayback: Sendable {
    public struct Alternate: Sendable {
        public let id: String
        public let label: String
        public let uri: String
        public let authHeader: String?
        public let context: PlaybackSessionContext
    }
    public let item: MediaItem
    public let title: String
    public let uri: String
    public let authHeader: String?
    public let resumeSeconds: Double?
    public let context: PlaybackSessionContext
    public let alternates: [Alternate]
}

/// Complete preparation policy with metadata/URL/UI host effects. Native values
/// stay in an opaque registry, preserving every field without a lossy DTO roundtrip.
@MainActor
public enum PlaybackPreparationWorkflow {
    public enum Outcome: Sendable {
        case presented
        case noContent(title: String, error: String)
        case failed(title: String, error: String, phase: String, original: (any Error)?)
    }
    public typealias HomeProvider = @MainActor () -> (nextUp: [MediaItem], resume: [MediaItem])
    public static func noContentMessage(_ item: MediaItem) -> String {
        switch item.kind {
        case .boxSet: "这个合集里还没有可播放的内容"
        case .series: "该剧没有可播放的剧集"
        default: "这个条目没有可播放的内容"
        }
    }
    public static func resolve(item: MediaItem, server: any MediaServer, home: HomeProvider,
                               coreClient: OcpCoreClient? = nil) async throws -> MediaItem? {
        guard let core = OcpPlaybackPreparation(client: coreClient) else {
            return try await nativeResolve(item: item, server: server, home: home)
        }
        var selected: MediaItem?
        let outcome = try await run(core: core, mode: "resolve", item: item, resumeSeconds: nil,
            server: server, home: home, onResolved: { _ in }, onFallback: { _, _ in },
            ready: { item, _, _, _, _ in selected = item })
        if case let .failed(_, _, _, original) = outcome {
            throw original ?? PreparationError.invalidEffect("Leaf resolution failed")
        }
        return selected
    }
    public static func prepare(item: MediaItem, resumeSeconds: Double?, server: any MediaServer,
                               home: HomeProvider, coreClient: OcpCoreClient? = nil,
                               onResolved: (String) -> Void,
                               onFallback: (MediaItem, String) -> Void,
                               onReady: (PreparedPlayback) -> Void) async throws -> Outcome {
        if let core = OcpPlaybackPreparation(client: coreClient) {
            return try await run(core: core, mode: "open", item: item, resumeSeconds: resumeSeconds,
                server: server, home: home, onResolved: onResolved, onFallback: onFallback,
                ready: { selected, payload, info, sources, headers in
                    guard let uri = payload.uri, let title = payload.title else { throw PreparationError.invalidEffect("Missing prepared URL/title") }
                    let fallback = payload.fallback == true
                    let context: PlaybackSessionContext
                    if fallback { context = PlaybackSessionContext(itemID: selected.id, durationSeconds: selected.runtimeSeconds) }
                    else {
                        guard let info else { throw PreparationError.invalidEffect("Missing PlaybackInfo") }
                        let source = payload.sourceKey.flatMap { sources[$0] }
                        if payload.sourceKey != nil && source == nil { throw PreparationError.invalidEffect("Missing primary source") }
                        context = info.sessionContext(itemID: selected.id, selectedSource: source)
                    }
                    let alternates = try (payload.alternates ?? []).map { alternate -> PreparedPlayback.Alternate in
                        guard let source = sources[alternate.key], let info else { throw PreparationError.invalidEffect("Missing alternate source") }
                        return PreparedPlayback.Alternate(id: source.id, label: source.name ?? source.id,
                            uri: alternate.uri, authHeader: headers[alternate.key] ?? nil,
                            context: info.sessionContext(itemID: selected.id, selectedSource: source))
                    }
                    onReady(PreparedPlayback(item: selected, title: title, uri: uri, authHeader: server.authorizationHeader,
                        resumeSeconds: payload.resumeSeconds, context: context, alternates: alternates))
                })
        }
        return try await nativePrepare(item: item, resumeSeconds: resumeSeconds, server: server,
            home: home, onResolved: onResolved, onFallback: onFallback, onReady: onReady)
    }
    private static func run(core: OcpPlaybackPreparation, mode: String, item: MediaItem,
                            resumeSeconds: Double?, server: any MediaServer, home: HomeProvider,
                            onResolved: (String) -> Void, onFallback: (MediaItem, String) -> Void,
                            ready: (MediaItem, OcpPlaybackPreparation.Payload, PlaybackInfo?, [String: PlaybackMediaSource], [String: String?]) throws -> Void) async throws -> Outcome {
        var items: [String: MediaItem] = [:]
        func wire(_ item: MediaItem) -> [String: Any] {
            let key = UUID().uuidString; items[key] = item
            return ["key": key, "id": item.id, "name": item.name, "kind": item.kind.rawValue,
                "seriesId": item.seriesID as Any, "seriesName": item.seriesName as Any,
                "seasonNumber": item.seasonNumber as Any, "episodeNumber": item.episodeNumber as Any,
                "played": item.playState?.played ?? false, "positionSeconds": item.playState?.positionSeconds as Any]
        }
        var step = try core.start(item: wire(item), mode: mode, resumeSeconds: resumeSeconds)
        let token = step.token
        defer { try? core.cancel(token: token) }
        var info: PlaybackInfo?, sources: [String: PlaybackMediaSource] = [:], headers: [String: String?] = [:]
        var originalError: (any Error)?
        while !step.done {
            try Task.checkCancellation(); try core.validate(step)
            guard let effect = step.effect, let args = step.arguments else { throw PreparationError.invalidEffect("Missing preparation effect") }
            let response: Any
            do {
                switch effect {
                case "home":
                    let current = home(); response = ["nextUp": current.nextUp.map(wire), "resume": current.resume.map(wire)]
                case "collectionMembers":
                    guard let id = args.itemId, args.recursive == false else { throw PreparationError.invalidEffect("Invalid collection effect") }
                    response = try await server.collectionMembers(of: id).items.map(wire)
                case "episodes":
                    guard let id = args.seriesId else { throw PreparationError.invalidEffect("Missing series") }
                    response = try await server.episodes(seriesID: id, seasonID: nil).map(wire)
                case "resolved":
                    guard let title = args.title else { throw PreparationError.invalidEffect("Missing resolved title") }
                    onResolved(title); response = true
                case "playbackInfo":
                    guard let id = args.itemId else { throw PreparationError.invalidEffect("Missing item") }
                    let fetched = try await server.playbackInfo(itemID: id); info = fetched
                    let projected = fetched.mediaSources.map { source -> [String: Any] in
                        let key = UUID().uuidString; sources[key] = source
                        return ["key": key, "id": source.id, "supportsDirectPlay": source.supportsDirectPlay as Any, "supportsDirectStream": source.supportsDirectStream as Any]
                    }
                    response = ["sources": projected, "playSessionId": fetched.playSessionID as Any]
                case "streamURL":
                    guard let id = args.itemId else { throw PreparationError.invalidEffect("Missing URL item") }
                    response = try server.streamURL(itemID: id, mediaSourceID: args.mediaSourceId, playSessionID: args.playSessionId)
                    if let key = args.sourceKey { headers[key] = server.authorizationHeader }
                case "fallback":
                    guard let key = args.itemKey, let selected = items[key], let error = args.error else { throw PreparationError.invalidEffect("Missing fallback state") }
                    onFallback(selected, error); response = true
                case "ready":
                    guard let key = args.itemKey, let selected = items[key] else { throw PreparationError.invalidEffect("Missing selected item") }
                    try ready(selected, args, info, sources, headers); response = true
                default: throw PreparationError.invalidEffect("Unknown effect: \(effect)")
                }
            } catch {
                if effect != "streamURL" || args.role != "alternate" {
                    if args.role != "fallback" || originalError == nil { originalError = error }
                }
                let resolverEffect = effect == "home" || effect == "collectionMembers" || effect == "episodes"
                let cancelled = Task.isCancelled || (resolverEffect && error is CancellationError)
                step = try core.fail(step, message: "\(error)", cancelled: cancelled)
                if cancelled { throw CancellationError() }
                continue
            }
            try Task.checkCancellation(); try core.validate(step)
            step = try core.resume(step, response: response)
        }
        switch step.result?.status {
        case "completed": return .presented
        case "noContent": return .noContent(title: step.result?.title ?? item.name, error: step.result?.error ?? noContentMessage(item))
        case "failed": return .failed(title: step.result?.title ?? item.name, error: step.result?.error ?? "播放准备失败", phase: step.result?.phase ?? "presentation", original: originalError)
        case "cancelled": throw CancellationError()
        default: throw PreparationError.invalidEffect("Unknown terminal outcome")
        }
    }
    static func nativeResolve(item: MediaItem, server: any MediaServer, home: HomeProvider) async throws -> MediaItem? {
        if item.kind == .boxSet {
            let members = try await server.collectionMembers(of: item.id).items
            let leaves = members.filter { $0.kind == .movie || $0.kind == .episode }
            if let selected = leaves.first(where: { !($0.playState?.played ?? false) }) ?? leaves.first { return selected }
            if let series = members.first(where: { $0.kind == .series }) { return try await nativeResolve(item: series, server: server, home: home) }
            return nil
        }
        guard item.kind == .series else { return item }
        let current = home()
        if let next = current.nextUp.first(where: { $0.seriesID == item.id }) ?? current.resume.first(where: { $0.seriesID == item.id }) { return next }
        let episodes = try await server.episodes(seriesID: item.id, seasonID: nil).filter { $0.seasonNumber != 0 }
        return episodes.first(where: { !($0.playState?.played ?? false) }) ?? episodes.first
    }
    static func nativePrepare(item: MediaItem, resumeSeconds: Double?, server: any MediaServer, home: HomeProvider,
                              onResolved: (String) -> Void, onFallback: (MediaItem, String) -> Void,
                              onReady: (PreparedPlayback) -> Void) async throws -> Outcome {
        let selected: MediaItem
        do {
            guard let resolved = try await nativeResolve(item: item, server: server, home: home) else { return .noContent(title: item.name, error: noContentMessage(item)) }
            try Task.checkCancellation(); selected = resolved
        } catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); return .failed(title: item.name, error: "剧集加载失败：\(error)", phase: "resolve", original: error) }
        let resume = selected.id == item.id ? resumeSeconds : selected.playState?.positionSeconds
        let title = selected.episodeLabel.map { "\(selected.seriesName ?? selected.name) \($0)" } ?? selected.name
        onResolved(title)
        do {
            let info = try await server.playbackInfo(itemID: selected.id)
            let index = MediaSourceSelection.nativePreferredIndex(count: info.mediaSources.count,
                supportsDirectPlay: { info.mediaSources[$0].supportsDirectPlay == true }, supportsDirectStream: { info.mediaSources[$0].supportsDirectStream == true })
            let source = index.map { info.mediaSources[$0] }
            let uri = try server.streamURL(itemID: selected.id, mediaSourceID: source?.id, playSessionID: info.playSessionID)
            try Task.checkCancellation()
            let alternates = info.mediaSources.filter { $0.id != source?.id }.compactMap { candidate -> PreparedPlayback.Alternate? in
                guard let uri = try? server.streamURL(itemID: selected.id, mediaSourceID: candidate.id, playSessionID: info.playSessionID) else { return nil }
                return .init(id: candidate.id, label: candidate.name ?? candidate.id, uri: uri, authHeader: server.authorizationHeader, context: info.sessionContext(itemID: selected.id, selectedSource: candidate))
            }
            try Task.checkCancellation()
            onReady(.init(item: selected, title: title, uri: uri, authHeader: server.authorizationHeader, resumeSeconds: resume,
                context: info.sessionContext(itemID: selected.id, selectedSource: source), alternates: alternates))
            return .presented
        } catch {
            try Task.checkCancellation(); onFallback(selected, "\(error)")
            if let uri = try? server.streamURL(itemID: selected.id, mediaSourceID: nil, playSessionID: nil) {
                onReady(.init(item: selected, title: title, uri: uri, authHeader: server.authorizationHeader, resumeSeconds: resume,
                    context: .init(itemID: selected.id, durationSeconds: selected.runtimeSeconds), alternates: []))
                return .presented
            }
            return .failed(title: title, error: "播放信息获取失败：\(error)", phase: "playback", original: error)
        }
    }
    private enum PreparationError: Error { case invalidEffect(String) }
}

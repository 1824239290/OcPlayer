import CoreModel
import Foundation
import OcPlayerCore

/// MediaServer facade backed by the shared Rust core for the migrated data paths.
/// Unsupported operations remain delegated to the existing native implementation,
/// so the migration can advance without splitting the app's capability surface.
public final class RustCoreMediaServer: MediaServer, @unchecked Sendable {
    private let fallback: any MediaServer
    private let core: OcpCoreClient
    private var rustProfile: [String: Any] {
        let current = fallback.profile
        var profile: [String: Any] = [
            "id": current.id, "kind": current.kind.rawValue,
            "baseURL": current.baseURL.absoluteString, "userID": current.userID,
            "authorizationHeader": fallback.authorizationHeader,
        ]
        if let token = Self.extractToken(from: fallback.authorizationHeader) { profile["token"] = token }
        if let userAgent = ClientIdentity.customUserAgent { profile["userAgent"] = userAgent }
        return profile
    }

    public var profile: ServerProfile { fallback.profile }
    public var authorizationHeader: String { fallback.authorizationHeader }

    public init?(wrapping fallback: any MediaServer, dataDirectory: URL? = nil, libraryPath: String? = nil) {
        guard libraryPath != nil || OcpCoreFeature.isEnabled else { return nil }
        // A MediaServer may be an injected in-memory/test implementation. Only
        // concrete network adapters opt into replacement; never turn an abstract
        // server into an unsolicited HTTP request just because Core is enabled.
        guard libraryPath != nil || (fallback as? JellyfinServer)?.allowsCoreTransport == true
            || (fallback as? EmbyServer)?.allowsCoreTransport == true else { return nil }
        do {
            self.core = try OcpCoreClient(
                config: dataDirectory.map { ["dataDirectory": $0.path] } ?? [:], libraryPath: libraryPath)
            self.fallback = fallback
        } catch {
            return nil
        }
    }

    private func call(_ method: String, _ arguments: [String: Any] = [:]) throws -> OcpResponse {
        var merged = arguments
        merged["profile"] = rustProfile
        let response = try core.call(method, arguments: merged)
        guard response.ok else { throw RustCoreMediaServerError(response: response) }
        return response
    }

    private func data<T: Decodable>(_ method: String, _ arguments: [String: Any] = [:], as type: T.Type = T.self) throws -> T {
        try call(method, arguments).data.decode(type)
    }

    private func dataAsync<T: Decodable>(_ method: String, _ arguments: [String: Any] = [:], as type: T.Type = T.self) async throws -> T {
        try await responseAsync(method, arguments).data.decode(type)
    }

    private func resolveEndpoint() async {
        if let server = fallback as? JellyfinServer { await server.resolveCoreEndpoint() }
        else if let server = fallback as? EmbyServer { await server.resolveCoreEndpoint() }
    }

    private func failover(from failed: URL) async -> Bool {
        if !ServerAddress.isSame(failed, profile.baseURL) { return true }
        if let server = fallback as? JellyfinServer { return await server.failoverCoreEndpoint(from: failed) }
        if let server = fallback as? EmbyServer { return await server.failoverCoreEndpoint(from: failed) }
        return false
    }

    private func responseAsync(_ method: String, _ arguments: [String: Any] = [:]) async throws -> OcpResponse {
        await resolveEndpoint()
        try Task.checkCancellation()
        let attemptProfile = rustProfile
        let failedURL = URL(string: attemptProfile["baseURL"] as? String ?? "") ?? profile.baseURL
        var merged = arguments
        merged["profile"] = attemptProfile
        func dispatch(_ values: [String: Any]) async throws -> OcpResponse {
            let payload = try JSONSerialization.data(withJSONObject: values)
            return try await core.callAsync(method, argumentsJSON: String(decoding: payload, as: UTF8.self))
        }
        var response = try await dispatch(merged)
        let read = method.hasPrefix("browse.") || method == "server.libraries" || method.hasPrefix("media.") || method == "server.avatarTag"
        if !response.ok, read, [1521, 1522, 1523].contains(response.code), await failover(from: failedURL) {
            try Task.checkCancellation()
            merged["profile"] = rustProfile
            response = try await dispatch(merged)
        }
        if !response.ok {
            if response.code == 2001 {
                await MainActor.run {
                    NotificationCenter.default.post(name: MediaServerAuthentication.authenticationRequired, object: self.profile.id)
                }
            }
            throw RustCoreMediaServerError(response: response)
        }
        return response
    }

    public func userViews() async throws -> [MediaLibrary] {
        try await dataAsync("server.libraries")
    }

    public func latestItems(limit: Int) async throws -> [MediaItem] {
        try await dataAsync("browse.latest", ["limit": limit])
    }

    public func resumeItems() async throws -> [MediaItem] {
        try await dataAsync("browse.resume", ["limit": 24])
    }

    public func nextUp() async throws -> [MediaItem] {
        try await dataAsync("browse.nextUp", ["limit": 24])
    }

    public func randomBackdropItems(limit: Int) async throws -> [MediaItem] {
        try await dataAsync("browse.random", ["limit": limit])
    }

    public func playedItemsPage(startIndex: Int, limit: Int) async throws -> ServerPlayedItemsPage {
        let page: RustPlayedPage = try await dataAsync("browse.played", ["startIndex": startIndex, "limit": limit])
        return ServerPlayedItemsPage(
            items: page.items.map { ServerPlayedItem(item: $0.item, lastPlayedAt: Self.date($0.lastPlayedAt)) },
            totalRecordCount: page.totalRecordCount)
    }

    public func markPlayed(itemID: String) async throws -> MediaItem.PlayState {
        try await dataAsync("server.markPlayed", ["itemId": itemID], as: RustPlayStateEnvelope.self).playState
    }

    public func markUnplayed(itemID: String) async throws -> MediaItem.PlayState {
        try await dataAsync("server.markUnplayed", ["itemId": itemID], as: RustPlayStateEnvelope.self).playState
    }

    public func item(_ id: String) async throws -> MediaItem {
        try await dataAsync("browse.detail", ["itemId": id])
    }

    public func itemsPage(parentID: String?, kinds: [MediaItem.Kind]?, recursive: Bool, startIndex: Int, limit: Int, sort: MediaItemsSort?, watchState: MediaItemsWatchState?, searchTerm: String?) async throws -> MediaItemsPage {
        var args: [String: Any] = ["startIndex": max(0, startIndex), "limit": max(1, limit), "recursive": recursive]
        if let parentID { args["parentId"] = parentID }
        if let kinds { args["kinds"] = kinds.map(\.rawValue) }
        if let sort { args["sort"] = ["field": sort.field.rawValue, "ascending": sort.ascending] }
        if let watchState { args["watchState"] = watchState.rawValue }
        if let searchTerm { args["searchTerm"] = searchTerm }
        let page: RustItemsPage = try await dataAsync("browse.library", args)
        return MediaItemsPage(items: page.items, startIndex: page.startIndex, totalRecordCount: page.totalRecordCount)
    }

    public func reportPlaybackStart(context: PlaybackSessionContext, positionSeconds: Double) async {
        await report("report.start", context: context, positionSeconds: positionSeconds, isPaused: false)
    }

    public func reportPlaybackProgress(context: PlaybackSessionContext, positionSeconds: Double, isPaused: Bool) async {
        await report("report.progress", context: context, positionSeconds: positionSeconds, isPaused: isPaused)
    }

    public func reportPlaybackStopped(context: PlaybackSessionContext, positionSeconds: Double) async {
        await report("report.stopped", context: context, positionSeconds: positionSeconds, isPaused: false)
    }

    private func report(_ method: String, context: PlaybackSessionContext, positionSeconds: Double, isPaused: Bool) async {
        var args: [String: Any] = ["itemId": context.itemID, "positionSeconds": positionSeconds, "paused": isPaused]
        if let mediaSourceID = context.mediaSourceID { args["mediaSourceId"] = mediaSourceID }
        if let playSessionID = context.playSessionID { args["playSessionId"] = playSessionID }
        do {
            _ = try await responseAsync(method, args)
        } catch {
            // Reporting has a nonthrowing host API; do not replay a possibly accepted POST.
            NSLog("Rust Core playback report failed (%@)", method)
        }
    }

    // The remaining methods preserve the complete existing JellyfinKit behavior.
    public func chapters(itemID: String) async throws -> [JellyfinChapter] {
        struct WireChapter: Decodable {
            let name: String?
            let startPositionTicks: Int64?

            private enum CodingKeys: String, CodingKey {
                case nameLower = "name"
                case name = "Name"
                case startLower = "startPositionTicks"
                case startPositionTicks = "StartPositionTicks"
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                name = (try? values.decodeIfPresent(String.self, forKey: .name)) ??
                    (try? values.decodeIfPresent(String.self, forKey: .nameLower)) ?? nil
                startPositionTicks = (try? values.decodeIfPresent(Int64.self, forKey: .startPositionTicks)) ??
                    (try? values.decodeIfPresent(Int64.self, forKey: .startLower)) ?? nil
            }
        }
        struct Payload: Decodable { let chapters: [WireChapter] }
        let payload: Payload = try await dataAsync("browse.chapters", ["itemId": itemID])
        return payload.chapters.enumerated().map { index, chapter in
            JellyfinChapter(
                name: chapter.name ?? "章节 \(index + 1)",
                startSeconds: Double(chapter.startPositionTicks ?? 0) / 10_000_000)
        }
    }
    public func items(parentID: String?, kinds: [MediaItem.Kind]?, recursive: Bool, limit: Int) async throws -> [MediaItem] {
        var all: [MediaItem] = []
        var start = 0
        let pageSize = max(1, min(limit, 500))
        repeat {
            var args: [String: Any] = [
                "startIndex": start,
                "limit": pageSize,
                "recursive": recursive,
            ]
            if let parentID { args["parentId"] = parentID }
            if let kinds { args["kinds"] = kinds.map(\.rawValue) }
            let page: RustItemsPage = try await dataAsync("browse.library", args)
            all.append(contentsOf: page.items)
            start += page.items.count
            if page.items.isEmpty || all.count >= limit { break }
        } while true
        return Array(all.prefix(max(0, limit)))
    }
    public func seasons(seriesID: String) async throws -> [MediaItem] {
        try await dataAsync("browse.seasons", ["seriesId": seriesID])
    }
    public func episodes(seriesID: String, seasonID: String?) async throws -> [MediaItem] {
        var args: [String: Any] = ["seriesId": seriesID]
        if let seasonID { args["seasonId"] = seasonID }
        return try await dataAsync("browse.episodes", args)
    }
    public func episodes(seriesID: String, startingAt startItemID: String, limit: Int) async throws -> [MediaItem] {
        let all: [MediaItem] = try await dataAsync("browse.episodes", ["seriesId": seriesID, "limit": max(1, limit)])
        guard let index = all.firstIndex(where: { $0.id == startItemID }) else { return [] }
        return Array(all[index..<min(all.count, index + max(1, limit))])
    }
    public func similar(itemID: String, limit: Int) async throws -> [MediaItem] {
        struct Payload: Decodable { let items: [MediaItem] }
        return try await dataAsync("browse.similar", ["itemId": itemID, "limit": limit], as: Payload.self).items
    }
    public func currentUserAvatarTag() async throws -> String? {
        struct Payload: Decodable { let tag: String? }
        return try await dataAsync("server.avatarTag", as: Payload.self).tag
    }
    public func userImageURL(tag: String?) -> URL? {
        var args: [String: Any] = [:]
        if let tag { args["tag"] = tag }
        return (try? data("server.userImageURL", args, as: RustOptionalURLPayload.self).url).flatMap { $0 }
    }
    public func imageURL(itemID: String, type: ItemImageType, maxWidth: Int?, tag: String?) throws -> URL {
        var args: [String: Any] = ["itemId": itemID, "imageType": type.rawValue]
        if let maxWidth { args["maxWidth"] = maxWidth }
        if let tag { args["tag"] = tag }
        let value = try data("server.imageURL", args, as: RustURLPayload.self).url
        guard let url = URL(string: value) else {
            throw RustCoreMediaServerError(message: "Rust Core returned an invalid image URL")
        }
        return url
    }
    public func streamURL(itemID: String, mediaSourceID: String?, playSessionID: String?) throws -> String {
        var args: [String: Any] = ["itemId": itemID]
        if let mediaSourceID { args["mediaSourceId"] = mediaSourceID }
        if let playSessionID { args["playSessionId"] = playSessionID }
        return try data("server.streamURL", args, as: RustURLPayload.self).url
    }
    public func mediaSegments(itemID: String) async throws -> [JellyfinMediaSegment] {
        struct WireSegment: Decodable {
            let id: String?
            let itemID: String?
            let type: String?
            let startTicks: Int64?
            let endTicks: Int64?

            private enum CodingKeys: String, CodingKey {
                case idLower = "id"
                case id = "Id"
                case itemLower = "itemId"
                case itemID = "ItemId"
                case typeLower = "type"
                case type = "Type"
                case startLower = "startTicks"
                case startTicks = "StartTicks"
                case endLower = "endTicks"
                case endTicks = "EndTicks"
            }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = (try? values.decodeIfPresent(String.self, forKey: .id)) ??
                    (try? values.decodeIfPresent(String.self, forKey: .idLower)) ?? nil
                itemID = (try? values.decodeIfPresent(String.self, forKey: .itemID)) ??
                    (try? values.decodeIfPresent(String.self, forKey: .itemLower)) ?? nil
                type = (try? values.decodeIfPresent(String.self, forKey: .type)) ??
                    (try? values.decodeIfPresent(String.self, forKey: .typeLower)) ?? nil
                startTicks = (try? values.decodeIfPresent(Int64.self, forKey: .startTicks)) ??
                    (try? values.decodeIfPresent(Int64.self, forKey: .startLower)) ?? nil
                endTicks = (try? values.decodeIfPresent(Int64.self, forKey: .endTicks)) ??
                    (try? values.decodeIfPresent(Int64.self, forKey: .endLower)) ?? nil
            }
        }
        struct Payload: Decodable { let items: [WireSegment] }
        let payload: Payload = try await dataAsync("media.segments", ["itemId": itemID])
        return payload.items.compactMap { segment in
            guard let type = segment.type?.lowercased(),
                  let kind: JellyfinMediaSegment.Kind = type == "intro" ? .intro : type == "outro" ? .outro : nil
            else { return nil }
            return JellyfinMediaSegment(
                id: segment.id ?? UUID().uuidString,
                itemID: segment.itemID ?? itemID,
                kind: kind,
                startSeconds: Double(segment.startTicks ?? 0) / 10_000_000,
                endSeconds: Double(segment.endTicks ?? 0) / 10_000_000)
        }.sorted { $0.startSeconds < $1.startSeconds }
    }
    public func externalSubtitles(itemID: String) async throws -> [ExternalSubtitle] {
        try await externalSubtitles(itemID: itemID, mediaSourceID: nil)
    }
    public func externalSubtitles(itemID: String, mediaSourceID: String?) async throws -> [ExternalSubtitle] {
        var args: [String: Any] = ["itemId": itemID]
        if let mediaSourceID { args["mediaSourceId"] = mediaSourceID }
        let payload: RustMediaItemsEnvelope = try await dataAsync("media.subtitles", args)
        let sources = payload.items.first?.mediaSources ?? []
        let source = mediaSourceID.flatMap { id in sources.first { $0.id == id } }
            ?? sources.first(where: { $0.supportsDirectPlay == true || $0.supportsDirectStream == true })
            ?? sources.first
        return (source?.mediaStreams ?? []).compactMap { stream in
            guard stream.type?.lowercased() == "subtitle",
                  stream.isExternal == true,
                  let index = stream.index,
                  let codec = stream.codec?.lowercased(),
                  ExternalSubtitle.fileExtension(forCodec: codec) != nil
            else { return nil }
            return ExternalSubtitle(
                itemID: itemID,
                mediaSourceID: source?.id,
                namespace: ExternalSubtitle.namespace(profile: profile),
                index: index,
                title: stream.title ?? stream.displayTitle,
                language: stream.language,
                codec: codec)
        }
    }
    public func downloadSubtitle(_ subtitle: ExternalSubtitle) async throws -> URL { try await fallback.downloadSubtitle(subtitle) }
    public func mediaFileInfo(itemID: String) async throws -> MediaFileInfo? {
        let payload: RustMediaItemsEnvelope = try await dataAsync("media.fileInfo", ["itemId": itemID])
        let sources = payload.items.first?.mediaSources ?? []
        guard let source = sources.first(where: { $0.supportsDirectPlay == true || $0.supportsDirectStream == true }) ?? sources.first
        else { return nil }
        let streams = source.mediaStreams ?? []
        let video = streams.first { $0.type?.lowercased() == "video" }.map { stream in
            MediaFileInfo.VideoTrack(
                codec: stream.codec,
                width: stream.width,
                height: stream.height,
                bitrate: stream.bitRate,
                frameRate: stream.averageFrameRate ?? stream.realFrameRate,
                bitDepth: stream.bitDepth,
                colorPrimaries: stream.colorPrimaries,
                colorTransfer: stream.colorTransfer,
                colorSpace: stream.colorSpace,
                colorRange: stream.colorRange,
                videoRangeType: stream.videoRangeType,
                profile: stream.profile,
                isInterlaced: stream.isInterlaced == true)
        }
        let audio = streams.filter { $0.type?.lowercased() == "audio" }.map { stream in
            MediaFileInfo.AudioTrack(
                codec: stream.codec,
                channels: stream.channels,
                channelLayout: stream.channelLayout,
                sampleRate: stream.sampleRate,
                bitrate: stream.bitRate,
                language: stream.language,
                title: stream.title ?? stream.displayTitle,
                isDefault: stream.isDefault == true)
        }
        let subtitles = streams.filter { $0.type?.lowercased() == "subtitle" }.map { stream in
            MediaFileInfo.SubtitleTrack(
                codec: stream.codec,
                language: stream.language,
                title: stream.title ?? stream.displayTitle,
                isDefault: stream.isDefault == true,
                isForced: stream.isForced == true,
                isExternal: stream.isExternal == true)
        }
        return MediaFileInfo(
            video: video,
            audioTracks: audio,
            subtitleTracks: subtitles,
            container: source.container,
            sizeBytes: source.size,
            durationSeconds: source.runTimeTicks.map { Double($0) / 10_000_000 },
            fileName: MediaFileInfo.fileName(fromPath: source.path),
            sourceCount: sources.count)
    }
    public func playbackInfo(itemID: String) async throws -> PlaybackInfo {
        let payload: RustPlaybackInfo = try await dataAsync("playback.info", ["itemId": itemID])
        return PlaybackInfo(
            playSessionID: payload.playSessionID,
            mediaSources: payload.mediaSources.map {
                PlaybackMediaSource(
                    id: $0.id ?? UUID().uuidString,
                    name: $0.name,
                    path: $0.path,
                    size: $0.size,
                    container: $0.container,
                    supportsDirectPlay: $0.supportsDirectPlay,
                    supportsDirectStream: $0.supportsDirectStream,
                    supportsTranscoding: $0.supportsTranscoding,
                    bitrate: $0.bitrate,
                    runTimeSeconds: $0.runTimeSeconds,
                    videoRangeType: $0.videoRangeType)
            })

    }

    private static func extractToken(from header: String) -> String? {
        guard let range = header.range(of: "Token=\"") else { return nil }
        let rest = header[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func date(_ value: String?) -> Date? { value.flatMap { ISO8601DateFormatter().date(from: $0) } }
}

public struct RustCoreMediaServerError: Error, LocalizedError, Sendable {
    public let message: String
    public let code: Int32
    public let retryable: Bool
    public var errorDescription: String? { message }
    public init(message: String, code: Int32 = 0, retryable: Bool = false) {
        self.message = message; self.code = code; self.retryable = retryable
    }
    init(response: OcpResponse) { self.init(message: response.message, code: response.code, retryable: response.retryable) }
}

private struct RustItemsPage: Decodable { let items: [MediaItem]; let startIndex: Int; let totalRecordCount: Int? }
private struct RustPlayedPage: Decodable { let items: [RustPlayedItem]; let startIndex: Int; let totalRecordCount: Int? }
private struct RustPlayedItem: Decodable { let item: MediaItem; let lastPlayedAt: String? }
private struct RustPlayStateEnvelope: Decodable { let playState: MediaItem.PlayState }
private struct RustURLPayload: Decodable { let url: String }
private struct RustPlaybackInfo: Decodable {
    let mediaSources: [RustPlaybackSource]
    let playSessionID: String?

    private enum CodingKeys: String, CodingKey {
        case mediaSources
        case playSessionID = "playSessionId"
    }
}
private struct RustPlaybackSource: Decodable {
    let id: String?
    let name: String?
    let path: String?
    let size: Int?
    let container: String?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    let bitrate: Int?
    let runTimeSeconds: Double?
    let videoRangeType: String?
}

private struct RustMediaItemsEnvelope: Decodable {
    let items: [RustMediaItem]

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: RustCodingKey.self)
        items = values.decodeFirst([RustMediaItem].self, keys: ["items", "Items"]) ?? []
    }
}

private struct RustMediaItem: Decodable {
    let mediaSources: [RustMediaSource]?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: RustCodingKey.self)
        mediaSources = values.decodeFirst([RustMediaSource].self, keys: ["mediaSources", "MediaSources"])
    }
}

private struct RustMediaSource: Decodable {
    let id: String?
    let path: String?
    let container: String?
    let size: Int?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let runTimeTicks: Int64?
    let mediaStreams: [RustMediaStream]?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: RustCodingKey.self)
        id = values.decodeFirst(String.self, keys: ["id", "Id"])
        path = values.decodeFirst(String.self, keys: ["path", "Path"])
        container = values.decodeFirst(String.self, keys: ["container", "Container"])
        size = values.decodeFirst(Int.self, keys: ["size", "Size"])
        supportsDirectPlay = values.decodeFirst(Bool.self, keys: ["supportsDirectPlay", "SupportsDirectPlay"])
        supportsDirectStream = values.decodeFirst(Bool.self, keys: ["supportsDirectStream", "SupportsDirectStream"])
        runTimeTicks = values.decodeFirst(Int64.self, keys: ["runTimeTicks", "RunTimeTicks"])
        mediaStreams = values.decodeFirst([RustMediaStream].self, keys: ["mediaStreams", "MediaStreams"])
    }
}

private struct RustMediaStream: Decodable {
    let index: Int?
    let type: String?
    let codec: String?
    let language: String?
    let title: String?
    let displayTitle: String?
    let isExternal: Bool?
    let isDefault: Bool?
    let isForced: Bool?
    let width: Int?
    let height: Int?
    let bitRate: Int?
    let averageFrameRate: Double?
    let realFrameRate: Double?
    let bitDepth: Int?
    let colorPrimaries: String?
    let colorTransfer: String?
    let colorSpace: String?
    let colorRange: String?
    let videoRangeType: String?
    let profile: String?
    let isInterlaced: Bool?
    let channels: Int?
    let channelLayout: String?
    let sampleRate: Int?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: RustCodingKey.self)
        index = values.decodeFirst(Int.self, keys: ["index", "Index"])
        type = values.decodeFirst(String.self, keys: ["type", "Type"])
        codec = values.decodeFirst(String.self, keys: ["codec", "Codec"])
        language = values.decodeFirst(String.self, keys: ["language", "Language"])
        title = values.decodeFirst(String.self, keys: ["title", "Title"])
        displayTitle = values.decodeFirst(String.self, keys: ["displayTitle", "DisplayTitle"])
        isExternal = values.decodeFirst(Bool.self, keys: ["isExternal", "IsExternal"])
        isDefault = values.decodeFirst(Bool.self, keys: ["isDefault", "IsDefault"])
        isForced = values.decodeFirst(Bool.self, keys: ["isForced", "IsForced"])
        width = values.decodeFirst(Int.self, keys: ["width", "Width"])
        height = values.decodeFirst(Int.self, keys: ["height", "Height"])
        bitRate = values.decodeFirst(Int.self, keys: ["bitRate", "BitRate"])
        averageFrameRate = values.decodeLossyDouble(keys: ["averageFrameRate", "AverageFrameRate"])
        realFrameRate = values.decodeLossyDouble(keys: ["realFrameRate", "RealFrameRate"])
        bitDepth = values.decodeFirst(Int.self, keys: ["bitDepth", "BitDepth"])
        colorPrimaries = values.decodeFirst(String.self, keys: ["colorPrimaries", "ColorPrimaries"])
        colorTransfer = values.decodeFirst(String.self, keys: ["colorTransfer", "ColorTransfer"])
        colorSpace = values.decodeFirst(String.self, keys: ["colorSpace", "ColorSpace"])
        colorRange = values.decodeFirst(String.self, keys: ["colorRange", "ColorRange"])
        videoRangeType = values.decodeFirst(String.self, keys: ["videoRangeType", "VideoRangeType"])
        profile = values.decodeFirst(String.self, keys: ["profile", "Profile"])
        isInterlaced = values.decodeFirst(Bool.self, keys: ["isInterlaced", "IsInterlaced"])
        channels = values.decodeFirst(Int.self, keys: ["channels", "Channels"])
        channelLayout = values.decodeFirst(String.self, keys: ["channelLayout", "ChannelLayout"])
        sampleRate = values.decodeFirst(Int.self, keys: ["sampleRate", "SampleRate"])
    }
}

private struct RustOptionalURLPayload: Decodable {
    let url: URL?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: RustCodingKey.self)
        guard let value = values.decodeFirst(String.self, keys: ["url", "URL"]) else {
            url = nil
            return
        }
        url = URL(string: value)
    }
}

private struct RustCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private extension KeyedDecodingContainer where Key == RustCodingKey {
    func decodeFirst<T: Decodable>(_ type: T.Type, keys: [String]) -> T? {
        for key in keys {
            let codingKey = RustCodingKey(stringValue: key)
            guard contains(codingKey) else { continue }
            if let value = try? decodeIfPresent(type, forKey: codingKey) { return value }
        }
        return nil
    }

    func decodeLossyDouble(keys: [String]) -> Double? {
        if let value = decodeFirst(Double.self, keys: keys) { return value }
        guard let text = decodeFirst(String.self, keys: keys) else { return nil }
        return Double(text)
    }
}

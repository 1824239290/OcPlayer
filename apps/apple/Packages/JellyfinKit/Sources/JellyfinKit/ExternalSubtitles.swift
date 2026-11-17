import Foundation
import CryptoKit
import DiagnosticsKit
import Get
import JellyfinAPI

/// 一条 Jellyfin 外挂字幕（服务器上的侧车文件，不在视频容器里）。
/// 直连播放时客户端负责下载后喂给内核（`addExternalSubtitle`）。
public struct ExternalSubtitle: Identifiable, Hashable, Sendable {
    /// 租户、条目、媒体源、轨道和格式的稳定身份。
    public let id: String
    public let index: Int
    public let title: String?
    public let language: String?
    public let codec: String
    /// 内核认的文件扩展名（subrip → srt）。
    public let fileExtension: String
    /// 下载路径（不带 host、不带 token —— 认证走请求头）。
    public let remotePath: String

    init(itemID: String, mediaSourceID: String? = nil, namespace: String = "", index: Int, title: String?, language: String?, codec: String) {
        self.id = Self.stableKey([namespace, itemID, mediaSourceID ?? itemID, String(index), Self.fileExtension(forCodec: codec) ?? codec])
        self.index = index
        self.title = title
        self.language = language
        self.codec = codec
        self.fileExtension = Self.fileExtension(forCodec: codec) ?? codec
        // Jellyfin/Emby 的外挂字幕路由是 /Videos/{itemId}/{mediaSourceId}/Subtitles/
        // {index}/Stream.{format}。单源条目 mediaSourceId 通常 == itemId，但多源
        // （同一 item 挂多个版本）时必须用真正的 mediaSourceId，否则 404。
        let resolvedMediaSourceID = mediaSourceID ?? itemID
        self.remotePath = "/Videos/\(itemID)/\(resolvedMediaSourceID)/Subtitles/\(index)/Stream.\(fileExtension)"
    }

    static func stableKey(_ components: [String]) -> String {
        let joined = components.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 下载入口再绑定服务器，兼容手工构造的旧字幕对象。
    func cacheFileName(profile: ServerProfile) -> String {
        Self.stableKey([Self.namespace(profile: profile), id]) + "." + fileExtension
    }

    static func namespace(profile: ServerProfile) -> String {
        stableKey([profile.kind.rawValue, profile.baseURL.absoluteString, profile.userID])
    }

    /// 文本字幕的扩展名映射；图像字幕（PGS sup 等）内核外挂不吃，返回 nil 跳过。
    static func fileExtension(forCodec codec: String) -> String? {
        switch codec.lowercased() {
        case "srt", "subrip": "srt"
        case "ass": "ass"
        case "ssa": "ssa"
        case "vtt", "webvtt": "vtt"
        default: nil
        }
    }

    /// 是否文本字幕（能喂给内核的）。
    var isTextBased: Bool { Self.fileExtension(forCodec: codec) != nil }
}

extension JellyfinServer {

    /// 条目的外挂字幕列表。Jellyfin 把 `.zh.srt` 这类侧车文件暴露成
    /// `MediaStream(type: subtitle, isExternal: true)`；内封字幕内核自己认，不用管。
    public func externalSubtitles(itemID: String) async throws -> [ExternalSubtitle] {
        try await externalSubtitles(itemID: itemID, mediaSourceID: nil)
    }

    public func externalSubtitles(itemID: String, mediaSourceID selectedSourceID: String?) async throws -> [ExternalSubtitle] {
        let result = try await send(
            Paths.getItems(parameters: .init(
                userID: profile.userID,
                fields: [.mediaSources],
                ids: [itemID]
            ))
        )
        let sources = result.items?.first?.mediaSources ?? []
        let mediaSource: MediaSourceInfo?
        if let selectedSourceID {
            mediaSource = sources.first { $0.id == selectedSourceID }
        } else if let index = MediaSourceSelection.preferredIndex(count: sources.count, supportsDirectPlay: { sources[$0].isSupportsDirectPlay == true }, supportsDirectStream: { sources[$0].isSupportsDirectStream == true }) {
            mediaSource = sources[index]
        } else { mediaSource = nil }
        let mediaSourceID = mediaSource?.id
        let streams = mediaSource?.mediaStreams ?? []
        return streams.compactMap { stream in
            guard stream.type == .subtitle,
                  stream.isExternal == true,
                  let index = stream.index,
                  let codec = stream.codec?.lowercased(),
                  // PGS / DVD 图像字幕：内核外挂不认，静默跳过
                  ExternalSubtitle.fileExtension(forCodec: codec) != nil
            else { return nil }
            return ExternalSubtitle(
                itemID: itemID,
                mediaSourceID: mediaSourceID,
                namespace: ExternalSubtitle.namespace(profile: profile),
                index: index,
                title: stream.title ?? stream.displayTitle,
                language: stream.language,
                codec: codec
            )
        }
    }

    /// 下载外挂字幕到本地缓存（Application Support/OcPlayer/Subtitles），返回文件路径。
    /// 认证走 `Authorization` 头，token 不进 URL。
    public func downloadSubtitle(_ subtitle: ExternalSubtitle) async throws -> URL {
        let request = Request<Data>(path: subtitle.remotePath, method: "GET", id: "DownloadSubtitle")
        let data: Data
        do {
            data = try await client.send(request).value
        } catch {
            NetworkLog.reportFailed("DownloadSubtitle \(subtitle.remotePath)", error: error)
            throw JellyfinError.wrapPreservingCancellation(error)
        }
        let directory = OcPlayerStorage.directory("Subtitles")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: subtitle.cacheFileName(profile: profile))
        try data.write(to: url, options: .atomic)
        return url
    }
}

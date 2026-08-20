import Foundation
import JellyfinKit

/// 一次播放请求：从浏览层（AppModel）带到播放页的纯值。
/// `authHeader` 是 Jellyfin 的 `MediaBrowser …` 头 —— 只走请求头，绝不进 URL。
struct PlaybackRequest: Hashable, Identifiable {
    let id: UUID
    let title: String
    let uri: String
    let authHeader: String?
    /// Security-scoped URL for a user-selected local file.
    let securityScopedURL: URL?
    /// 服务端记录的续播位置（秒）；小于 30 秒视作从头播。
    let resumeSeconds: Double?
    /// Jellyfin playback/source identity. Local files and manual URLs leave it nil.
    let sessionContext: PlaybackSessionContext?

    init(
        id: UUID = UUID(),
        title: String,
        uri: String,
        authHeader: String? = nil,
        resumeSeconds: Double? = nil,
        securityScopedURL: URL? = nil,
        sessionContext: PlaybackSessionContext? = nil
    ) {
        self.id = id
        self.title = title
        self.uri = uri
        self.authHeader = authHeader
        self.resumeSeconds = resumeSeconds
        self.securityScopedURL = securityScopedURL
        self.sessionContext = sessionContext
    }
}

/// A capability token for injecting an asynchronously loaded resource into the
/// exact engine generation it was requested for.
struct PlaybackSourceGeneration: Hashable, Sendable {
    let requestID: PlaybackRequest.ID
    let value: UInt64
}

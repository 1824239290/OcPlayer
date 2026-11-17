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
    /// 本条请求**失败后可以自动换上去**的其它媒体源，按服务端顺序。
    ///
    /// 空数组是常态：本地文件、直连链接、只有一个版本的条目、以及老服务端
    /// 不返回多源的情形，都走「失败即报错」的老路，行为与改动前完全一致。
    ///
    /// ## 为什么是「另起一条请求」而不是原地改 uri
    ///
    /// 换源必然改变 `mediaSourceID`，而进度上报（Start / Progress / Stopped）
    /// 绑在 `sessionContext` 上。原地改 uri 会让上报继续用旧源的 id，
    /// 服务端那边就成了「A 源开始、B 源的数据」。
    /// 因此换源 = 重开一条新请求（新 `id`、新会话上下文），旧会话按正常
    /// 收尾流程发 Stopped —— 与用户手动点「重试」走的是同一条已验证路径。
    let alternates: [PlaybackAlternate]

    init(
        id: UUID = UUID(),
        title: String,
        uri: String,
        authHeader: String? = nil,
        resumeSeconds: Double? = nil,
        securityScopedURL: URL? = nil,
        sessionContext: PlaybackSessionContext? = nil,
        alternates: [PlaybackAlternate] = []
    ) {
        self.id = id
        self.title = title
        self.uri = uri
        self.authHeader = authHeader
        self.resumeSeconds = resumeSeconds
        self.securityScopedURL = securityScopedURL
        self.sessionContext = sessionContext
        self.alternates = alternates
    }
}

/// 一条**备用媒体源**：已经解析好、可以直接拿起来开播的那几个字段。
///
/// 只带开播必需的三件（uri / 鉴权头 / 会话上下文）+ 一个给人看的标签。
/// 不在里面存 `PlaybackMediaSource` 实体：一是避免 JellyfinKit 类型漏进播放层，
/// 二是备用源在请求生成时就已经定型，之后的 failure 处理不该再回头查服务端。
struct PlaybackAlternate: Hashable, Identifiable, Sendable {
    /// 稳定标识：Jellyfin 的 mediaSourceID，本地源用 uri 兜底。
    let id: String
    /// 菜单 / 日志里的可读名，例如「原盘 1080p」。
    let label: String
    let uri: String
    let authHeader: String?
    let sessionContext: PlaybackSessionContext?
}

/// A capability token for injecting an asynchronously loaded resource into the
/// exact engine generation it was requested for.
struct PlaybackSourceGeneration: Hashable, Sendable {
    let requestID: PlaybackRequest.ID
    let value: UInt64
}

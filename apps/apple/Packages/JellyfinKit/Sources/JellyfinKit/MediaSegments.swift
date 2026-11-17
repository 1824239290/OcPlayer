import CoreModel
import Foundation
import Get
import JellyfinAPI

/// Jellyfin 可跳过片段的域模型(由 `/MediaSegments` 返回的 `MediaSegmentDto` 映射而来)。
/// 类型为 `public`,因为 App 层通过 `JellyfinServer.mediaSegments(itemID:)` 使用它。
public struct JellyfinMediaSegment: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case intro
        case outro
    }

    public let id: String
    public let itemID: String
    public let kind: Kind
    /// 媒体时间起点(秒)。
    public let startSeconds: Double
    /// 媒体时间终点(秒)。
    public let endSeconds: Double

    /// 直接构造（Emby 侧由章节 marker 翻译出同形的 segment）。
    public init(id: String, itemID: String, kind: Kind, startSeconds: Double, endSeconds: Double) {
        self.id = id
        self.itemID = itemID
        self.kind = kind
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    public init(_ dto: MediaSegmentDto, fallbackItemID: String) {
        self.id = dto.id ?? UUID().uuidString
        self.itemID = dto.itemID ?? fallbackItemID
        self.kind = dto.type == .intro ? .intro : .outro
        self.startSeconds = (dto.startTicks.map { Double($0) / 10_000_000 }) ?? 0
        self.endSeconds = (dto.endTicks.map { Double($0) / 10_000_000 }) ?? 0
    }
}

extension JellyfinServer {

    /// 拉取 Jellyfin `/MediaSegments/{id}` 的 Intro / Outro 片段。
    ///
    /// 这是 Jellyfin 的**智能识别**(片头 / 片尾),比章节名启发式准,有就优先用。
    /// 该接口是 Jellyfin 插件生态（intro skipper 等）提供的；Emby 没有这个端点，
    /// 由 `EmbyServer` 从章节 marker 翻译出同形的 segment。
    /// Jellyfin 较老版本可能 404 / 被禁用,调用方应捕获失败并回退到章节启发式。
    public func mediaSegments(itemID: String) async throws -> [JellyfinMediaSegment] {
        let result = try await send(
            Paths.getItemSegments(
                itemID: itemID,
                includeSegmentTypes: [.intro, .outro]
            )
        )
        return (result.items ?? [])
            .compactMap { segment in
                guard let type = segment.type,
                      type == .intro || type == .outro
                else { return nil }
                return JellyfinMediaSegment(segment, fallbackItemID: itemID)
            }
            .sorted { $0.startSeconds < $1.startSeconds }
    }
}

// MARK: - 章节

/// Jellyfin 服务器给媒体的章节(由 `BaseItemDto.chapters` 映射而来)。
/// 只承载 `name` + `startPositionTicks` + 序号;真正的展示 / 跳转 `PlaybackChapter`
/// 由 App 层在拿到片长后转换(需要补 end 边界)。
public struct JellyfinChapter: Hashable, Sendable {
    public let name: String
    /// 起点(秒)(纯媒体时间映射)。
    public let startSeconds: Double

    public init(name: String, startSeconds: Double) {
        self.name = name
        self.startSeconds = startSeconds
    }

    init(_ info: JellyfinAPI.ChapterInfo, index: Int) {
        self.name = info.name ?? "章节 \(index + 1)"
        self.startSeconds = (info.startPositionTicks.map { Double($0) / 10_000_000 }) ?? 0
    }
}
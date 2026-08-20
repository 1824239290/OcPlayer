import Foundation

/// 弹弹play 网关透传的 v2 结构镜像。网关不重写字段，只校验后原样回传，
/// 所以这里解码键就是官方 camelCase。`success`/`errorCode` 基座来自
/// `ResponseBase`（match/search 继承）；`CommentResponseV2` 不继承基座，
/// 但网关仍会在 `success` 存在且非 true 时拒绝缓存。

// MARK: - 匹配

/// `POST /v1/match` 请求体。生产上游要求所有匹配模式都提供 `fileHash`；
/// `hashAndFileName` 与 `fileNameOnly` 还必须同时提供 `fileName`。
public struct MatchRequest: Codable, Sendable, Equatable {
    public enum MatchMode: String, Codable, Sendable {
        /// 同时使用文件名与哈希；请求必须包含两者。
        case hashAndFileName
        /// 上游模式名保留为 `fileNameOnly`，但生产契约仍要求同时携带哈希。
        case fileNameOnly
        /// 仅按哈希匹配；文件名可省略。
        case hashOnly
    }

    /// 不含目录与扩展名的文件名。`hashOnly` 模式可省略。
    public var fileName: String?
    /// 必填：文件前 16 MiB 的 MD5（32 位 ASCII hex）。DanmakuKit 的 `FileHash` 产出该值。
    public var fileHash: String?
    public var fileSize: Int64?
    /// 秒。
    public var videoDuration: Int?
    public var matchMode: MatchMode?

    public init(
        fileName: String? = nil,
        fileHash: String? = nil,
        fileSize: Int64? = nil,
        videoDuration: Int? = nil,
        matchMode: MatchMode? = nil
    ) {
        self.fileName = fileName
        self.fileHash = fileHash
        self.fileSize = fileSize
        self.videoDuration = videoDuration
        self.matchMode = matchMode
    }
}

/// `POST /v1/match` 响应。`matches` 为空表示未命中。
public struct MatchResponse: Decodable, Sendable, Equatable {
    public let success: Bool
    public let errorCode: Int?
    public let errorMessage: String?
    public let resultCount: Int?
    public let isMatched: Bool?
    public let matches: [Match]

    public struct Match: Decodable, Sendable, Equatable {
        public let episodeId: Int64
        public let animeId: Int?
        public let animeTitle: String?
        public let episodeTitle: String?
        public let type: String?
        public let typeDescription: String?
        /// 弹幕时间偏移（秒），部分来源用它校正第三方弹幕时间轴。
        public let shift: Int?
        public let fileName: String?
        public let fileSize: Int64?
        public let hash: String?
    }
}

// MARK: - 搜索

/// `GET /v1/search/anime` 响应。
public struct SearchAnimeResponse: Decodable, Sendable, Equatable {
    public let success: Bool
    public let errorCode: Int?
    public let errorMessage: String?
    public let animes: [AnimeSummary]
}

/// `GET /v1/search/episodes` 响应，结构与 `SearchAnimeResponse` 一致，只是 anime 下带分集。
public struct SearchEpisodesResponse: Decodable, Sendable, Equatable {
    public let success: Bool
    public let errorCode: Int?
    public let errorMessage: String?
    public let animes: [AnimeWithEpisodes]
}

public struct AnimeSummary: Decodable, Sendable, Equatable {
    public let animeId: Int
    public let animeTitle: String?
    public let type: String?
    public let typeDescription: String?
}

public struct AnimeWithEpisodes: Decodable, Sendable, Equatable {
    public let animeId: Int
    public let animeTitle: String?
    public let type: String?
    public let typeDescription: String?
    public let episodes: [Episode]
}

public struct Episode: Decodable, Sendable, Equatable, Identifiable {
    public let episodeId: Int64
    public let episodeTitle: String?
    public var id: Int64 { episodeId }
}

// MARK: - 弹幕

/// `GET /v1/comments/{episodeId}` 响应。不继承 `ResponseBase`；`count` 可能为 0，
/// `comments` 可能为 null（官方文档允许）。
public struct CommentResponse: Decodable, Sendable, Equatable {
    public let count: Int
    public let comments: [DanmakuComment]?

    public init(count: Int, comments: [DanmakuComment]?) {
        self.count = count
        self.comments = comments
    }

    private enum CodingKeys: String, CodingKey {
        case count
        case comments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let comments = try container.decodeIfPresent([DanmakuComment].self, forKey: .comments)
        self.comments = comments
        self.count = try container.decodeIfPresent(Int.self, forKey: .count) ?? comments?.count ?? 0
    }
}

/// 单条弹幕。`p` = `time,mode,color,userId,...`（逗号分隔，官方固定为前四段）；
/// `m` 是正文。
public struct DanmakuComment: Codable, Sendable, Equatable {
    public let cid: Int64?
    public let p: String
    public let m: String

    public init(cid: Int64? = nil, p: String, m: String) {
        self.cid = cid
        self.p = p
        self.m = m
    }
}

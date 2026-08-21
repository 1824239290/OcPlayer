import Foundation

/// 当前用户收藏相关的远程 API。
public enum BangumiCollectionService {
    /// 分页拉取当前用户的条目收藏（since 用于增量）。
    public static func getSubjectCollections(
        type: BangumiCollectionType = .none,
        subjectType: BangumiSubjectType = .none,
        since: Int = 0,
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> BangumiPagedDTO<BangumiSubjectDTO> {
        let url = BangumiURL.next(path: "p1/collections/subjects")
        var queryItems = [
            URLQueryItem(name: "since", value: String(since)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if type != .none {
            queryItems.append(URLQueryItem(name: "type", value: String(type.rawValue)))
        }
        if subjectType != .none {
            queryItems.append(URLQueryItem(name: "subjectType", value: String(subjectType.rawValue)))
        }
        let data = try await BangumiAPIClient.shared.request(
            url: url.appending(queryItems: queryItems), method: "GET", auth: .required)
        return try await BangumiAPIClient.shared.decodeResponse(data)
    }
}

/// 章节相关的远程 API。
public enum BangumiEpisodeService {
    /// 拉取条目的全部章节（分页）。
    public static func getSubjectEpisodes(
        _ subjectId: Int, limit: Int = 100, offset: Int = 0
    ) async throws -> BangumiPagedDTO<BangumiEpisodeDTO> {
        let url = BangumiURL.next(path: "p1/subjects/\(subjectId)/episodes")
        let pageURL = url.appending(queryItems: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ])
        let data = try await BangumiAPIClient.shared.request(url: pageURL, method: "GET")
        return try await BangumiAPIClient.shared.decodeResponse(data)
    }

    /// 更新单集收藏状态。batch=true 表示「看到此集」批量标记。
    public static func updateEpisodeCollection(
        episodeId: Int, type: BangumiEpisodeCollectionType, batch: Bool = false
    ) async throws {
        let url = BangumiURL.next(path: "p1/collections/episodes/\(episodeId)")
        var body: [String: Any] = [:]
        if batch {
            body["batch"] = true
        } else {
            body["type"] = type.rawValue
        }
        _ = try await BangumiAPIClient.shared.request(
            url: url, method: "PATCH", body: body, auth: .required)
    }
}

/// 条目查询（搜索/详情），用于播放器联动时的条目匹配。
public enum BangumiSubjectService {
    /// 搜索条目。
    public static func search(
        keyword: String, filter: BangumiSubjectType? = nil, limit: Int = 30, offset: Int = 0
    ) async throws -> BangumiPagedDTO<BangumiSlimSubjectDTO> {
        let url = BangumiURL.next(path: "p1/search/subjects")
        var queryItems = [
            URLQueryItem(name: "keyword", value: keyword),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let filter, filter != .none {
            queryItems.append(URLQueryItem(name: "filter", value: String(filter.rawValue)))
        }
        let data = try await BangumiAPIClient.shared.request(
            url: url.appending(queryItems: queryItems), method: "GET")
        return try await BangumiAPIClient.shared.decodeResponse(data)
    }

    /// 拉取条目详情。
    public static func getSubject(_ subjectId: Int) async throws -> BangumiSubjectDTO {
        let url = BangumiURL.next(path: "p1/subjects/\(subjectId)")
        let data = try await BangumiAPIClient.shared.request(url: url, method: "GET")
        return try await BangumiAPIClient.shared.decodeResponse(data)
    }
}

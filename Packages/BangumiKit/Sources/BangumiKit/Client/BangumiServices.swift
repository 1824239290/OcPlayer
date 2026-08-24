import Foundation

/// 当前用户收藏相关的远程 API。
public enum BangumiCollectionService {
    /// 收藏分页/增量查询的 URL（since/limit/offset/type 都拼进 query）。
    /// 单独抽出便于测试：查询参数此前漏挂在 URL 上,导致增量同步失效、翻页重复拉取。
    static func collectionsURL(
        type: BangumiCollectionType = .none,
        subjectType: BangumiSubjectType = .none,
        since: Int = 0,
        limit: Int = 100,
        offset: Int = 0
    ) -> URL {
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
        return url.appending(queryItems: queryItems)
    }

    /// 分页拉取当前用户的条目收藏（since 用于增量）。
    public static func getSubjectCollections(
        type: BangumiCollectionType = .none,
        subjectType: BangumiSubjectType = .none,
        since: Int = 0,
        limit: Int = 100,
        offset: Int = 0
    ) async throws -> BangumiPagedDTO<BangumiSubjectDTO> {
        let data = try await BangumiAPIClient.shared.request(
            url: collectionsURL(type: type, subjectType: subjectType, since: since, limit: limit, offset: offset),
            method: "GET",
            auth: .required)
        return try await BangumiAPIClient.shared.decodeResponse(data)
    }

    /// 回读单个条目的用户收藏状态（含在看/看过 type 与进度），未收藏返回 nil。
    public static func getSubjectCollection(_ subjectId: Int) async throws -> BangumiSubjectInterest? {
        let url = BangumiURL.api(path: "v0/users/-/collections/\(subjectId)")
        do {
            let data = try await BangumiAPIClient.shared.request(url: url, method: "GET", auth: .required)
            let response: BangumiUserCollectionResponse = try await BangumiAPIClient.shared.decodeResponse(data)
            return response.toSubjectInterest()
        } catch let e as BangumiError {
            if case .notFound = e { return nil }
            throw e
        }
    }

    /// 更新条目收藏状态（想看/在看/看过…）及/或评分（1-10，0 撤销评分）。
    public static func updateSubjectCollection(
        subjectId: Int,
        type: BangumiCollectionType? = nil,
        rate: Int? = nil
    ) async throws {
        let url = BangumiURL.api(path: "v0/users/-/collections/\(subjectId)")
        var body: [String: Any] = [:]
        if let type, type != .none {
            body["type"] = type.rawValue
        }
        if let rate {
            body["rate"] = rate
        }
        _ = try await BangumiAPIClient.shared.request(
            url: url, method: "POST", body: body, auth: .required)
    }
}

/// Bangumi v0 单条目收藏回包结构
public struct BangumiUserCollectionResponse: Codable, Sendable {
    public let type: BangumiCollectionType
    public let rate: Int?
    public let epStatus: Int?
    public let volStatus: Int?
    public let `private`: Bool?
    public let tags: [String]?
    public let comment: String?

    public func toSubjectInterest() -> BangumiSubjectInterest {
        BangumiSubjectInterest(
            comment: comment ?? "",
            epStatus: epStatus ?? 0,
            volStatus: volStatus ?? 0,
            private: `private` ?? false,
            rate: rate ?? 0,
            tags: tags ?? [],
            type: type,
            updatedAt: Int(Date().timeIntervalSince1970)
        )
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
    ///
    /// `type` 始终带上：batch 只是「连带之前各集」的开关，目标状态本身仍由 type 决定，
    /// 少传会让服务端行为取决于默认值。
    public static func updateEpisodeCollection(
        episodeId: Int, type: BangumiEpisodeCollectionType, batch: Bool = false
    ) async throws {
        let url = BangumiURL.next(path: "p1/collections/episodes/\(episodeId)")
        var body: [String: Any] = ["type": type.rawValue]
        if batch {
            body["batch"] = true
        }
        _ = try await BangumiAPIClient.shared.request(
            url: url, method: "PATCH", body: body, auth: .required)
    }
}

/// 条目查询（搜索/详情），用于播放器联动时的条目匹配。
public enum BangumiSubjectService {
    /// 搜索条目（POST，按匹配度排序）。
    public static func search(
        keyword: String, filter: BangumiSubjectType? = nil, limit: Int = 30, offset: Int = 0
    ) async throws -> BangumiPagedDTO<BangumiSlimSubjectDTO> {
        let url = BangumiURL.next(path: "p1/search/subjects")
        let pageURL = url.appending(queryItems: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ])
        var body: [String: Any] = [
            "keyword": keyword,
            "sort": "match",
        ]
        if let filter, filter != .none {
            body["filter"] = ["type": [filter.rawValue]]
        }
        let data = try await BangumiAPIClient.shared.request(
            url: pageURL, method: "POST", body: body)
        return try await BangumiAPIClient.shared.decodeResponse(data)
    }

    /// 拉取条目详情。
    public static func getSubject(_ subjectId: Int) async throws -> BangumiSubjectDTO {
        let url = BangumiURL.next(path: "p1/subjects/\(subjectId)")
        let data = try await BangumiAPIClient.shared.request(url: url, method: "GET")
        return try await BangumiAPIClient.shared.decodeResponse(data)
    }
}

/// 每日放送（番剧时间表）远程 API。
public enum BangumiCalendarService {
    /// 拉取每日放送列表（按周一至周日 7 天分组）。
    public static func getCalendar() async throws -> [BangumiCalendarDayDTO] {
        let url = BangumiURL.api(path: "calendar")
        let data = try await BangumiAPIClient.shared.request(url: url, method: "GET", auth: .disabled)
        return try await BangumiAPIClient.shared.decodeResponse(data)
    }
}


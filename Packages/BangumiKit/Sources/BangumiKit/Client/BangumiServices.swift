import Foundation

/// 单条目收藏态读取结果。
///
/// **不能用 `BangumiSubjectInterest?` 表达**：`nil` 过去同时承担「服务端确认没收藏」
/// 与「这次没读到」两种语义，而读取走的 `GET /v0/users/-/collections/{id}` 在
/// api.bgm.tv 上根本不存在（`-` 只注册在 PATCH/POST 上）→ 恒定 404 → `nil` →
/// 被当成「没收藏」→ 标「看过」前把条目强制 POST 成「在看」。**凡是要写服务端的
/// 决策都不允许消费 `.unknown`。**
public enum BangumiCollectionLookup: Sendable, Equatable {
    /// 服务端确认已收藏（带 type / 评分 / 进度）。
    case collected(BangumiSubjectInterest)
    /// 服务端明确回答「这个条目不在你的收藏里」。
    case notCollected
    /// 没读到：未登录、网络失败、路由或文案变更、解码失败……原因只进诊断日志。
    case unknown(String)

    /// 仅 `.collected` 有值——调用方按需读取，别用 `== nil` 判断「没收藏」。
    public var interest: BangumiSubjectInterest? {
        if case .collected(let interest) = self { return interest }
        return nil
    }

    /// `.unknown` 的原因（诊断日志/断言用）。
    public var reason: String? {
        if case .unknown(let reason) = self { return reason }
        return nil
    }
}

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

    /// 单条目收藏态查询 URL。
    ///
    /// 必须是公共路由 `GET /v0/users/{username}/collections/{subject_id}`。
    /// Bangumi 只把 `-`（当前用户）注册在 `PATCH/POST /v0/users/-/collections/{subject_id}`
    /// 上，**没有** `GET /v0/users/-/collections/{subject_id}`：那个请求会落进
    /// `/users/:username/collections/:subject_id`（username = `-`）→ 404
    /// `user doesn't exist or has been removed`。而 404 过去被当成「用户没收藏」，
    /// 于是标「看过」前必定把条目强制 POST 成「在看」——v0.1.5 起跨设备「已看数据
    /// 倒退」的根因。详见 `BangumiCollectionLookup`。
    static func subjectCollectionURL(subjectId: Int, username: String) -> URL {
        // username 可能含非 ASCII；`/` 必须转义，否则会拼出多一段路径。
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let escaped = username.addingPercentEncoding(withAllowedCharacters: allowed) ?? username
        return BangumiURL.api(path: "v0/users/\(escaped)/collections/\(subjectId)")
    }

    /// 服务端「这个条目不在你的收藏里」的判据文案（`res.NotFound("subject is not collected by user")`）。
    static let notCollectedMarker = "not collected"

    /// HTTP 结果 → 三态。纯函数，不发请求，单测直接钉住两种 404 的不同含义。
    static func classifyCollectionResponse(status: Int, body: Data) -> BangumiCollectionLookup {
        let text = String(decoding: body, as: UTF8.self)
        guard (200..<300).contains(status) else {
            // 404 有两种：`subject is not collected by user`（没收藏）与
            // `user doesn't exist or has been removed`（路由/用户名不对，读不到）。
            // 只有前者算未收藏——后者曾经被当成未收藏，是本次事故的直接推手。
            if status == 404, text.contains(notCollectedMarker) { return .notCollected }
            return .unknown("HTTP \(status)：\(Self.trimmed(text))")
        }
        do {
            let response = try BangumiAPIClient.jsonDecoder.decode(
                BangumiUserCollectionResponse.self, from: body)
            guard let interest = response.toSubjectInterest() else {
                return .unknown("收藏响应缺少可解析的 updated_at")
            }
            return .collected(interest)
        } catch {
            return .unknown("收藏响应解码失败：\(error)")
        }
    }

    /// 回读单个条目的用户收藏状态（含在看/看过 type 与进度）。
    ///
    /// 不抛错：三态结果里 `.unknown` 就是「这次没读到」，调用方**必须**把它与
    /// `.notCollected` 分开处理。`username` 取当前账号（`BangumiProfile.username`）。
    public static func lookupSubjectCollection(
        subjectId: Int, username: String
    ) async -> BangumiCollectionLookup {
        let url = subjectCollectionURL(subjectId: subjectId, username: username)
        do {
            let data = try await BangumiAPIClient.shared.request(url: url, method: "GET", auth: .required)
            return classifyCollectionResponse(status: 200, body: data)
        } catch let error as BangumiError {
            switch error {
            case .notFound(let response):
                // 错误体带着服务端判据（是否 `not collected`），别丢。
                return classifyCollectionResponse(status: 404, body: Data(response.utf8))
            default:
                return .unknown("\(error)")
            }
        } catch {
            return .unknown("\(error)")
        }
    }

    /// 错误体只截前若干字符进日志：路由 404 的 body 可能很长，但诊断只需要判据。
    private static func trimmed(_ text: String, limit: Int = 200) -> String {
        let collapsed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }

    /// 更新条目收藏状态（想看/在看/看过…）及/或评分（1-10，0 撤销评分）。
    public static func updateSubjectCollection(
        subjectId: Int,
        type: BangumiCollectionType? = nil,
        rate: Int? = nil
    ) async throws {
        let url = BangumiURL.api(path: "v0/users/-/collections/\(subjectId)")
        var body: [String: BangumiJSONValue] = [:]
        if let type, type != .none {
            body["type"] = .int(type.rawValue)
        }
        if let rate {
            body["rate"] = .int(rate)
        }
        _ = try await BangumiAPIClient.shared.request(
            url: url, method: "POST", body: .object(body), auth: .required)
    }
}

/// Bangumi v0 单条目收藏回包结构（`GET /v0/users/{username}/collections/{id}`）。
///
/// `updated_at` 在 wire 上是 **ISO8601 字符串**（`2026-10-01T21:00:40+08:00`），
/// 不是 unix 秒。它要落成 `interest.updatedAt` → `collectedAt`，而 `collectedAt`
/// 是进度页与收藏列表的排序键：拿本地 `Date()` 冒充服务端时间，会让每次回读都把
/// 条目顶到「最近收藏」最前面。解析不出来就返回 nil，由调用方按「没读到」处理。
public struct BangumiUserCollectionResponse: Codable, Sendable {
    public let type: BangumiCollectionType
    public let rate: Int?
    public let epStatus: Int?
    public let volStatus: Int?
    public let `private`: Bool?
    public let tags: [String]?
    public let comment: String?
    public let updatedAt: String?

    public func toSubjectInterest() -> BangumiSubjectInterest? {
        guard let epoch = BangumiCollectionTimestamp.epochSeconds(from: updatedAt) else { return nil }
        return BangumiSubjectInterest(
            comment: comment ?? "",
            epStatus: epStatus ?? 0,
            volStatus: volStatus ?? 0,
            private: `private` ?? false,
            rate: rate ?? 0,
            tags: tags ?? [],
            type: type,
            updatedAt: epoch
        )
    }
}

/// ISO8601 解析器持有者：`ISO8601DateFormatter` 不是 `Sendable`（静态存储被 Swift 6
/// 拒绝），但解析本身线程安全——与 `DiagnosticsKit.TimestampFormatters` 同一处理方式。
private final class BangumiCollectionTimestamp: @unchecked Sendable {
    static let shared = BangumiCollectionTimestamp()

    /// 带小数秒的形态（上游改精度时兜底）。
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let plain = ISO8601DateFormatter()

    /// ISO8601 → unix 秒；空值/解析失败返回 nil。
    static func epochSeconds(from rawValue: String?) -> Int? {
        guard let rawValue, !rawValue.isEmpty else { return nil }
        for parser in [shared.plain, shared.fractional] {
            if let date = parser.date(from: rawValue) { return Int(date.timeIntervalSince1970) }
        }
        return nil
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
        var body: [String: BangumiJSONValue] = ["type": .int(type.rawValue)]
        if batch {
            body["batch"] = .bool(true)
        }
        _ = try await BangumiAPIClient.shared.request(
            url: url, method: "PATCH", body: .object(body), auth: .required)
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
        let data = try await BangumiAPIClient.shared.request(
            url: pageURL, method: "POST", body: searchRequestBody(keyword: keyword, filter: filter))
        return try await BangumiAPIClient.shared.decodeResponse(data)
    }

    /// 搜索请求体（独立出来便于单测钉住参数形状）。
    ///
    /// `filter.type` 必须是整数数组（`{"type":[2]}`）：此前编码成 `{"type":{"0":2}}`
    /// 对象，Bangumi 服务端直接 400（body/filter/type must be array）。
    static func searchRequestBody(
        keyword: String, filter: BangumiSubjectType? = nil
    ) -> BangumiJSONValue {
        var body: [String: BangumiJSONValue] = [
            "keyword": .string(keyword),
            "sort": .string("match"),
        ]
        if let filter, filter != .none {
            body["filter"] = .object(["type": .array([.int(filter.rawValue)])])
        }
        return .object(body)
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
    /// 内存 TTL 缓存：日历是低频变化的数据，每次进分区都全量重拉纯属浪费。
    /// TTL 过后（或拉取失败）下次调用回源；TTL 内直接复用。
    /// 两个 static 变量可能被并发调用方（分栏视图 / 后台预取）同时读改写，
    /// 用锁保护——NSLock 不能持锁跨 async 点，临界区收进同步方法。
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cachedDays: [BangumiCalendarDayDTO]?
    private nonisolated(unsafe) static var cachedAt: Date?
    private static let ttl: TimeInterval = 30 * 60

    /// 缓存快照同步读：TTL 内返回缓存，否则 nil（回源）。
    private static func cachedSnapshot() -> [BangumiCalendarDayDTO]? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cachedDays, let cachedAt,
              Date().timeIntervalSince(cachedAt) < ttl
        else { return nil }
        return cachedDays
    }

    private static func storeCache(_ days: [BangumiCalendarDayDTO]) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedDays = days
        cachedAt = Date()
    }

    /// 拉取每日放送列表（按周一至周日 7 天分组）。
    public static func getCalendar(force: Bool = false) async throws -> [BangumiCalendarDayDTO] {
        if !force, let days = cachedSnapshot() {
            return days
        }
        let url = BangumiURL.api(path: "calendar")
        let data = try await BangumiAPIClient.shared.request(url: url, method: "GET", auth: .disabled)
        let days: [BangumiCalendarDayDTO] = try await BangumiAPIClient.shared.decodeResponse(data)
        storeCache(days)
        return days
    }
}


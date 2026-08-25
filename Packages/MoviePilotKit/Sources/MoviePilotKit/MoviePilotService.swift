import Foundation

/// 搜索 / 下载 API（全部带鉴权，401 自动静默重登）。
///
/// 注意：这些端点的解码都走**不做 key 转换**的 `JSONDecoder`——原始 JSON 里的
/// snake_case key 必须原样保留（下载时整个对象回传服务端），`convertFromSnakeCase`
/// 会连字典 key 一起转驼峰，把回传对象弄坏。
extension MoviePilotAPIClient {

    /// 元数据搜索：`GET /media/search`，返回可直接发起资源搜索的媒体条目。
    /// 多源聚合（tmdb/douban/bangumi…，顺序跟服务端 SEARCH_SOURCE 配置走）。
    public func searchMedia(title: String) async throws -> [MPMediaInfo] {
        let request = MPRequest(
            path: "/api/v1/media/search",
            query: [
                URLQueryItem(name: "title", value: title),
                URLQueryItem(name: "type", value: "media"),
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "count", value: "24"),
            ],
            timeout: 30
        )
        let data = try await requestData(request)
        // v3 的 ResponseAPIRouter 自动信封 + 裸返回两种都要兼容。
        let items = try Self.plainDecoder.decode(
            [[String: JSONValue]].self, from: MPEnvelope.unwrap(data))
        return items.map(MPMediaInfo.init(raw:))
    }

    /// 站点列表（资源搜索的站点筛选用；ResponseAPIRouter 自动信封）。
    public func sites() async throws -> [MPSite] {
        let request = MPRequest(path: "/api/v1/site/")
        let data = try await requestData(request)
        let items = try Self.plainDecoder.decode(
            [[String: JSONValue]].self, from: MPEnvelope.unwrap(data))
        return items.map(MPSite.init(raw:))
    }

    /// 按标题搜站点资源（SSE 流式，见 `searchTorrentsByTitleStream`）。
    /// 同步版 `/search/title` 在 v3 服务端返回全空壳字段，不可用。

    /// 添加下载：media / torrent 必须是搜索结果的原始对象回传。
    public func addDownload(media: MPMediaInfo, torrent: MPTorrent) async throws {
        let request = MPRequest(
            path: "/api/v1/download/",
            method: "POST",
            jsonBody: MPDownloadBody(
                mediaIn: .object(media.raw),
                torrentIn: .object(torrent.raw)
            ),
            timeout: 30
        )
        let data = try await requestData(request)
        let wrapped = try Self.plainDecoder.decode(MPStatusResponse.self, from: data)
        guard wrapped.success ?? true else {
            throw MoviePilotError.generic(wrapped.message ?? "添加下载失败")
        }
    }

    /// 下载中的任务列表（含进度）。
    public func downloadingTasks() async throws -> [MPDownloadTask] {
        let request = MPRequest(path: "/api/v1/download/")
        let data = try await requestData(request)
        let items = try Self.plainDecoder.decode(
            [[String: JSONValue]].self, from: MPEnvelope.unwrap(data))
        return items.map(MPDownloadTask.init(raw:))
    }

    public func startDownload(hash: String) async throws {
        try await downloadControl("start", hash: hash)
    }

    public func stopDownload(hash: String) async throws {
        try await downloadControl("stop", hash: hash)
    }

    public func removeDownload(hash: String) async throws {
        let request = MPRequest(
            path: "/api/v1/download/\(Self.encodePathSegment(hash))",
            method: "DELETE"
        )
        let data = try await requestData(request)
        try Self.checkStatus(data)
    }

    // MARK: - 订阅 API

    /// 查询全部订阅（`GET /api/v1/subscribe/`）。
    public func subscribes() async throws -> [MPSubscribe] {
        let request = MPRequest(path: "/api/v1/subscribe/")
        let data = try await requestData(request)
        let items = try Self.plainDecoder.decode(
            [[String: JSONValue]].self, from: MPEnvelope.unwrap(data))
        return items.map(MPSubscribe.init(raw:))
    }

    /// 从媒体搜索结果添加订阅（`POST /api/v1/subscribe/`）。
    public func addSubscribe(media: MPMediaInfo, season: Int? = nil) async throws {
        var body = media.raw
        if let title = media.title {
            body["name"] = .string(title)
        }
        if let type = media.type {
            body["type"] = .string(type)
        }
        if let year = media.year {
            body["year"] = .string(year)
        }
        if let tmdbId = media.tmdbId {
            body["tmdbid"] = .number(Double(tmdbId))
        }
        if let doubanId = media.doubanId {
            body["doubanid"] = .string(doubanId)
        }
        if let bangumiId = media.bangumiId {
            body["bangumiid"] = .number(Double(bangumiId))
        }
        if let s = season ?? media.season {
            body["season"] = .number(Double(s))
        }
        if let poster = media.posterURL?.absoluteString ?? media.raw["poster_path"]?.stringValue {
            body["poster"] = .string(poster)
        }
        if let overview = media.overview {
            body["overview"] = .string(overview)
            body["description"] = .string(overview)
        }

        let request = MPRequest(
            path: "/api/v1/subscribe/",
            method: "POST",
            jsonBody: JSONValue.object(body),
            timeout: 30
        )
        let data = try await requestData(request)
        try Self.checkStatus(data)
    }

    /// 直接以 MPSubscribe 对象添加订阅（`POST /api/v1/subscribe/`）。
    public func addSubscribe(subscribe: MPSubscribe) async throws {
        let request = MPRequest(
            path: "/api/v1/subscribe/",
            method: "POST",
            jsonBody: JSONValue.object(subscribe.raw),
            timeout: 30
        )
        let data = try await requestData(request)
        try Self.checkStatus(data)
    }

    /// 更新订阅配置（`PUT /api/v1/subscribe/`）。
    public func updateSubscribe(subscribe: MPSubscribe) async throws {
        let request = MPRequest(
            path: "/api/v1/subscribe/",
            method: "PUT",
            jsonBody: JSONValue.object(subscribe.raw),
            timeout: 30
        )
        let data = try await requestData(request)
        try Self.checkStatus(data)
    }

    /// 直接以字典更新订阅配置（`PUT /api/v1/subscribe/`）。
    public func updateSubscribe(raw: [String: JSONValue]) async throws {
        let request = MPRequest(
            path: "/api/v1/subscribe/",
            method: "PUT",
            jsonBody: JSONValue.object(raw),
            timeout: 30
        )
        let data = try await requestData(request)
        try Self.checkStatus(data)
    }

    /// 按订阅 ID 删除订阅（`DELETE /api/v1/subscribe/{id}`）。
    public func deleteSubscribe(id: Int) async throws {
        let request = MPRequest(
            path: "/api/v1/subscribe/\(id)",
            method: "DELETE"
        )
        let data = try await requestData(request)
        try Self.checkStatus(data)
    }

    /// 按媒体键删除订阅（`DELETE /api/v1/subscribe/media/{mediaid}`）。
    public func deleteSubscribeByMedia(mediaId: String) async throws {
        let request = MPRequest(
            path: "/api/v1/subscribe/media/\(Self.encodePathSegment(mediaId))",
            method: "DELETE"
        )
        let data = try await requestData(request)
        try Self.checkStatus(data)
    }

    /// 刷新全部订阅（`GET /api/v1/subscribe/refresh`）。
    public func refreshSubscribes() async throws {
        let request = MPRequest(path: "/api/v1/subscribe/refresh")
        let data = try await requestData(request)
        try Self.checkStatus(data)
    }

    /// 触发全站追更检索（`GET /api/v1/subscribe/search`）。
    public func searchSubscribes() async throws {
        let request = MPRequest(path: "/api/v1/subscribe/search")
        let data = try await requestData(request)
        try Self.checkStatus(data)
    }

    // MARK: - 内部

    private static let plainDecoder = JSONDecoder()

    private func downloadControl(_ action: String, hash: String) async throws {
        let request = MPRequest(
            path: "/api/v1/download/\(action)/\(Self.encodePathSegment(hash))"
        )
        let data = try await requestData(request)
        try Self.checkStatus(data)
    }

    private static func checkStatus(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let wrapped = try plainDecoder.decode(MPStatusResponse.self, from: data)
        guard wrapped.success ?? true else {
            throw MoviePilotError.generic(wrapped.message ?? "操作失败")
        }
    }

    /// 路径段百分号编码（媒体键带 `tmdb:` 冒号，hash 是十六进制但统一处理）。
    private static func encodePathSegment(_ value: String) -> String {
        value.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.alphanumerics
                .union(CharacterSet(charactersIn: "-._~"))
        ) ?? value
    }
}

/// `{success, message, data: [...]}` 的列表包裹。
private struct MPTorrentListResponse: Decodable {
    let success: Bool?
    let message: String?
    let data: [[String: JSONValue]]?
}

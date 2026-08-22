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

    /// 按标题搜站点资源（资源搜索主路径，与 MP 网页端一致）：
    /// `GET /search/title?keyword=&sites=`。sites 为空 = 全部站点。
    /// 同步聚合各站，可能要等几十秒。
    public func searchTorrentsByTitle(keyword: String, sites: [Int] = []) async throws -> [MPTorrent] {
        var query = [
            URLQueryItem(name: "keyword", value: keyword),
        ]
        // 服务端格式：逗号分隔的站点 id（_parse_site_list）。
        if !sites.isEmpty {
            query.append(URLQueryItem(
                name: "sites", value: sites.map(String.init).joined(separator: ",")))
        }
        let request = MPRequest(
            path: "/api/v1/search/title",
            query: query,
            timeout: 120
        )
        let data = try await requestData(request)
        let wrapped = try Self.plainDecoder.decode(MPTorrentListResponse.self, from: data)
        guard wrapped.success ?? true else {
            throw MoviePilotError.generic(wrapped.message ?? "站点搜索失败")
        }
        return (wrapped.data ?? []).map(MPTorrent.init(raw:))
    }

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

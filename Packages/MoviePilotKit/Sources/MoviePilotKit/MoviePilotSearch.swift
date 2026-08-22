import Foundation

/// 搜索 / 下载相关的领域模型。
///
/// 三个包装类型都**持有原始 JSON**（`raw`）：展示字段做类型化读取（宽容，
/// 缺字段就是 nil），下载时把 `raw` 原样回传——服务端要的是搜索结果完整对象。

/// 媒体条目（`/api/v1/media/search` 的元素）。
public struct MPMediaInfo: Sendable, Equatable, Identifiable {
    public let raw: [String: JSONValue]

    public init(raw: [String: JSONValue]) {
        self.raw = raw
    }

    public var id: String {
        mediaId ?? "\(mediaSource ?? "?"):\(title ?? "?"):\(year ?? "?")"
    }

    /// 数据源：tmdb / douban / bangumi…
    public var mediaSource: String? { raw["media_source"]?.stringValue }
    /// "电影" / "电视剧"
    public var type: String? { raw["type"]?.stringValue }
    public var title: String? { raw["title"]?.stringValue }
    public var year: String? { raw["year"]?.stringValue }
    public var titleYear: String? { raw["title_year"]?.stringValue }
    public var overview: String? { raw["overview"]?.stringValue }
    public var season: Int? { raw["season"]?.intValue }
    public var tmdbId: Int? { raw["tmdb_id"]?.intValue }
    public var bangumiId: Int? { raw["bangumi_id"]?.intValue }
    public var doubanId: String? { raw["douban_id"]?.stringValue }
    /// 带源前缀的媒体键，如 `tmdb:123`（资源搜索与下载都用它）。
    public var mediaId: String? { raw["media_id"]?.stringValue }

    /// `media_id` 缺失时按 可用 id 兜底拼一个 `source:id` 键。
    public var syntheticMediaKey: String? {
        if let tmdbId { return "tmdb:\(tmdbId)" }
        if let bangumiId { return "bangumi:\(bangumiId)" }
        if let doubanId, !doubanId.isEmpty { return "douban:\(doubanId)" }
        return nil
    }
    public var voteAverage: Double? { raw["vote_average"]?.doubleValue }
    public var numberOfSeasons: Int? { raw["number_of_seasons"]?.intValue }
    public var numberOfEpisodes: Int? { raw["number_of_episodes"]?.intValue }

    /// 展示用海报地址。TMDB 适配器给完整 URL；个别源给相对路径时按 TMDB 规则补齐。
    public var posterURL: URL? {
        guard let poster = raw["poster_path"]?.stringValue, !poster.isEmpty else { return nil }
        if poster.hasPrefix("http") {
            return URL(string: poster)
        }
        return URL(string: "https://image.tmdb.org/t-p/w500\(poster)")
    }

    /// 一行式副标题：类型 · 年份 · 评分。
    public var subtitle: String {
        var parts: [String] = []
        if let type { parts.append(type) }
        if let displayYear = titleYear ?? year { parts.append(displayYear) }
        if let voteAverage, voteAverage > 0 {
            parts.append(String(format: "★ %.1f", voteAverage))
        }
        if let mediaSource { parts.append(mediaSource.uppercased()) }
        return parts.joined(separator: " · ")
    }
}

/// 站点资源（`/api/v1/search/media/{id}` 的元素）。
public struct MPTorrent: Sendable, Equatable, Identifiable {
    public let raw: [String: JSONValue]

    public init(raw: [String: JSONValue]) {
        self.raw = raw
    }

    public var id: String {
        raw["enclosure"]?.stringValue ?? raw["title"]?.stringValue ?? UUID().uuidString
    }

    public var siteName: String? { raw["site_name"]?.stringValue }
    /// 种子标题（识别名）。
    public var title: String? { raw["title"]?.stringValue }
    public var description: String? { raw["description"]?.stringValue }
    /// 种子下载地址。
    public var enclosure: String? { raw["enclosure"]?.stringValue }
    public var pageURL: String? { raw["page_url"]?.stringValue }
    /// 字节。
    public var size: Double? { raw["size"]?.doubleValue }
    public var seeders: Int? { raw["seeders"]?.intValue }
    public var peers: Int? { raw["peers"]?.intValue }
    public var pubdate: String? { raw["pubdate"]?.stringValue }
    public var dateElapsed: String? { raw["date_elapsed"]?.stringValue }
    /// 下载体积因子：0 = 免费（FREE）。
    public var downloadVolumeFactor: Double? { raw["downloadvolumefactor"]?.doubleValue }
    public var uploadVolumeFactor: Double? { raw["uploadvolumefactor"]?.doubleValue }
    public var labels: [String] {
        if case .array(let values) = raw["labels"] ?? .null {
            return values.compactMap(\.stringValue)
        }
        return []
    }

    public var isFree: Bool {
        guard let factor = downloadVolumeFactor else { return false }
        return factor == 0
    }

    public var sizeText: String {
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// 下载任务（`GET /api/v1/download/` 的元素）。
public struct MPDownloadTask: Sendable, Equatable, Identifiable {
    public let raw: [String: JSONValue]

    public init(raw: [String: JSONValue]) {
        self.raw = raw
    }

    public var id: String { raw["hash"]?.stringValue ?? UUID().uuidString }

    public var hash: String? { raw["hash"]?.stringValue }
    public var name: String? { raw["name"]?.stringValue }
    public var title: String? { raw["title"]?.stringValue }
    public var siteName: String? { raw["site_name"]?.stringValue }
    /// 字节。
    public var size: Double? { raw["size"]?.doubleValue }
    /// 0…1。
    public var progress: Double? { raw["progress"]?.doubleValue }
    public var state: String? { raw["state"]?.stringValue }
    /// 服务端已格式化好的速度文本（如 "12.3 MB/s"）。
    public var dlspeed: String? { raw["dlspeed"]?.stringValue }
    public var upspeed: String? { raw["upspeed"]?.stringValue }
    public var leftTime: String? { raw["left_time"]?.stringValue }
    public var username: String? { raw["username"]?.stringValue }

    public var progressFraction: Double {
        min(max(progress ?? 0, 0), 1)
    }

    public var sizeText: String {
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    public var isPaused: Bool {
        guard let state else { return false }
        return state.lowercased().contains("paus") || state.lowercased().contains("stop")
    }
}

/// `schemas.Response` 包裹：{success, message, data}。
struct MPStatusResponse: Decodable {
    let success: Bool?
    let message: String?
}

/// POST /download/ 的请求体。media_in / torrent_in 必须是搜索结果的原始对象。
struct MPDownloadBody: Encodable {
    let mediaIn: JSONValue
    let torrentIn: JSONValue

    enum CodingKeys: String, CodingKey {
        case mediaIn = "media_in"
        case torrentIn = "torrent_in"
    }
}

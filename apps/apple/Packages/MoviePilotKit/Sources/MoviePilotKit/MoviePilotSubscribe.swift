import Foundation

/// 媒体订阅条目（`GET /api/v1/subscribe/` 的元素）。
///
/// 同样持有原始 JSON（`raw`）：展示字段做类型化读取（宽容解析，缺字段为 nil），
/// 更新/添加时把 `raw` 原样回传服务端。
public struct MPSubscribe: Sendable, Equatable, Identifiable {
    public let raw: [String: JSONValue]

    public init(raw: [String: JSONValue]) {
        self.raw = raw
    }

    public var id: String {
        if let subId = subscribeId {
            return "sub:\(subId)"
        }
        if let name, let year {
            return "\(name):\(year):\(season ?? 0)"
        }
        // 主键/名称都缺失时的兜底：用内容稳定哈希，替代每次读取都换一个的 UUID()
        // （计算属性当 ForEach id 时，UUID 会让每行每次重绘都被当成新元素重建）。
        return "mp-sub-\(raw.stableContentHash)"
    }

    /// 订阅 ID（后端主键，删除/更新接口使用）。
    public var subscribeId: Int? {
        raw["id"]?.intValue ?? raw["id"]?.stringValue.flatMap(Int.init)
    }

    /// 媒体名称 / 标题。
    public var name: String? {
        raw["name"]?.stringValue ?? raw["title"]?.stringValue
    }

    /// 媒体展示年份。
    public var year: String? {
        if let y = raw["year"]?.stringValue, !y.isEmpty { return y }
        if let y = raw["year"]?.intValue { return String(y) }
        return nil
    }

    /// 媒体类型："电影" / "电视剧" / "动漫" 等。
    public var type: String? {
        raw["type"]?.stringValue
    }

    /// 是否是电影。
    public var isMovie: Bool {
        if let t = type {
            return t.contains("电影") || t.uppercased() == "MOV" || t.uppercased() == "MOVIE"
        }
        return false
    }

    /// 是否是电视剧 / 动漫 / 剧集。
    public var isTV: Bool {
        if isMovie { return false }
        if let t = type {
            return t.contains("剧") || t.contains("动漫") || t.contains("动画") || t.uppercased() == "TV" || t.uppercased() == "ANIME"
        }
        return season != nil || totalEpisode != nil
    }

    /// 季数（如第 1 季）。
    public var season: Int? {
        if let s = raw["season"]?.intValue { return s }
        if let str = raw["season"]?.stringValue {
            let cleaned = str.replacingOccurrences(of: "S", with: "").replacingOccurrences(of: "s", with: "")
            return Int(cleaned)
        }
        return nil
    }

    /// 季数格式化文案（如 "第 1 季"）。
    public var seasonText: String? {
        guard let season, season > 0 else { return nil }
        return "第 \(season) 季"
    }

    /// 电视剧总集数。
    public var totalEpisode: Int? {
        raw["total_episode"]?.intValue
    }

    /// 缺失集数。
    public var lackEpisode: Int? {
        raw["lack_episode"]?.intValue
    }

    /// 起始集数。
    public var startEpisode: Int? {
        raw["start_episode"]?.intValue
    }

    /// TMDB ID。
    public var tmdbId: Int? {
        raw["tmdbid"]?.intValue ?? raw["tmdb_id"]?.intValue
    }

    /// 豆瓣 ID。
    public var doubanId: String? {
        raw["doubanid"]?.stringValue ?? raw["douban_id"]?.stringValue
    }

    /// Bangumi ID。
    public var bangumiId: Int? {
        raw["bangumiid"]?.intValue ?? raw["bangumi_id"]?.intValue
    }

    /// 海报地址。
    public var poster: String? {
        raw["poster"]?.stringValue ?? raw["poster_path"]?.stringValue
    }

    /// 展示用海报 URL。
    public var posterURL: URL? {
        guard let poster, !poster.isEmpty else { return nil }
        if poster.hasPrefix("http") {
            return URL(string: poster)
        }
        // TMDB 标准图床路径是 /t/p/w500/...（此前误写成 /t-p/，相对路径补齐时海报全 404）。
        return URL(string: "https://image.tmdb.org/t/p/w500\(poster)")
    }

    /// 背景海报。
    public var backdrop: String? {
        raw["backdrop"]?.stringValue ?? raw["backdrop_path"]?.stringValue
    }

    /// 评分。
    public var voteAverage: Double? {
        raw["vote_average"]?.doubleValue
    }

    /// 简介。
    public var description: String? {
        raw["description"]?.stringValue ?? raw["overview"]?.stringValue
    }

    /// 订阅状态代码（"R" 运行中, "P"/"S" 暂停, "O" 完成, "N" 新建）。
    public var state: String? {
        raw["state"]?.stringValue
    }

    /// 人类可读的订阅状态。
    public var stateText: String {
        guard let state = state?.uppercased() else { return "追更中" }
        switch state {
        case "R":
            return "追更中"
        case "P", "S":
            return "已暂停"
        case "O":
            return "已完成"
        case "N":
            return "新订阅"
        default:
            return state
        }
    }

    /// 最后更新时间。
    public var lastUpdate: String? {
        raw["last_update"]?.stringValue ?? raw["updated_at"]?.stringValue
    }

    /// 搜索关键词过滤。
    public var keyword: String? {
        raw["keyword"]?.stringValue
    }

    /// 包含关键词（规则过滤）。
    public var include: String? {
        raw["include"]?.stringValue
    }

    /// 排除关键词（规则过滤）。
    public var exclude: String? {
        raw["exclude"]?.stringValue
    }

    /// 分辨率/质量偏好（如 4K, 1080p, WEB-DL 等）。
    public var quality: String? {
        raw["quality"]?.stringValue
    }

    /// 自定义存储路径。
    public var savePath: String? {
        raw["save_path"]?.stringValue
    }

    /// 限制搜索站点 ID 列表。
    public var sites: [Int] {
        if case .array(let values) = raw["sites"] ?? .null {
            return values.compactMap(\.intValue)
        }
        return []
    }

    /// 最佳版本开关。
    public var bestVersion: Bool {
        raw["best_version"]?.boolValue ?? (raw["best_version"]?.intValue == 1)
    }

    /// 集数更新进度描述。
    public var progressText: String? {
        if isMovie {
            return nil
        }
        if let total = totalEpisode, total > 0 {
            if let lack = lackEpisode {
                if lack <= 0 {
                    return "全 \(total) 集已下完"
                } else {
                    let completed = max(total - lack, 0)
                    return "已下 \(completed)/\(total) 集 (缺 \(lack))"
                }
            } else {
                return "共 \(total) 集"
            }
        } else if let lack = lackEpisode, lack > 0 {
            return "缺失 \(lack) 集"
        }
        return nil
    }

    /// 转换为 MPMediaInfo，用于点击订阅卡片直达资源搜索页。
    public var asMediaInfo: MPMediaInfo {
        var mediaRaw = raw
        if mediaRaw["title"] == nil, let n = name {
            mediaRaw["title"] = .string(n)
        }
        if mediaRaw["poster_path"] == nil, let p = poster {
            mediaRaw["poster_path"] = .string(p)
        }
        if mediaRaw["overview"] == nil, let d = description {
            mediaRaw["overview"] = .string(d)
        }
        if mediaRaw["media_id"] == nil {
            if let tmdb = tmdbId {
                mediaRaw["media_id"] = .string("tmdb:\(tmdb)")
                mediaRaw["tmdb_id"] = .number(Double(tmdb))
                mediaRaw["media_source"] = .string("tmdb")
            } else if let bgm = bangumiId {
                mediaRaw["media_id"] = .string("bangumi:\(bgm)")
                mediaRaw["bangumi_id"] = .number(Double(bgm))
                mediaRaw["media_source"] = .string("bangumi")
            } else if let douban = doubanId {
                mediaRaw["media_id"] = .string("douban:\(douban)")
                mediaRaw["douban_id"] = .string(douban)
                mediaRaw["media_source"] = .string("douban")
            }
        }
        return MPMediaInfo(raw: mediaRaw)
    }
}

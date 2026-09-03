import Foundation

/// 动画文件名解析出的结构化元数据。
public struct ParsedAnimeInfo: Sendable, Equatable {
    /// 原始文件名或标题
    public let rawName: String
    /// 提纯后的动画主标题（剥除发布组、规格、集数、副标签等）
    public let title: String
    /// 提取出的集数（例如 1, 12, 24）
    public let episodeNumber: Int?
    /// 提取出的季数（例如 1, 2, 3），若无法识别则为 nil
    public let seasonNumber: Int?
    /// 是否标识为最终季/完结篇
    public let isFinal: Bool

    public init(
        rawName: String,
        title: String,
        episodeNumber: Int? = nil,
        seasonNumber: Int? = nil,
        isFinal: Bool = false
    ) {
        self.rawName = rawName
        self.title = title
        self.episodeNumber = episodeNumber
        self.seasonNumber = seasonNumber
        self.isFinal = isFinal
    }
}

/// 动画文件名与标题提取工具。
/// 能够从各类 BT/PT 发布组、WEB-DL、内嵌字幕及各种命名习惯中提取纯净的动画名、季数与集数。
public enum DanmakuFilenameParser {

    /// 全角字符转半角。
    public static func normalizeFullWidth(_ str: String) -> String {
        var result = ""
        for scalar in str.unicodeScalars {
            if scalar.value >= 0xFF01 && scalar.value <= 0xFF5E {
                if let converted = UnicodeScalar(scalar.value - 0xFEE0) {
                    result.append(Character(converted))
                    continue
                }
            } else if scalar.value == 0x3000 {
                result.append(" ")
                continue
            }
            result.append(Character(scalar))
        }
        return result
    }

    /// 中文数字转换为阿拉伯数字（0-99）。
    public static func parseChineseNumber(_ str: String) -> Int? {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        if let direct = Int(trimmed) { return direct }
        let map: [Character: Int] = [
            "零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
            "六": 6, "七": 7, "八": 8, "九": 9, "十": 10
        ]
        if trimmed.count == 1, let val = map[trimmed.first!] {
            return val
        }
        if trimmed == "十" { return 10 }
        if trimmed.hasPrefix("十") && trimmed.count == 2 {
            if let second = map[trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)]] {
                return 10 + second
            }
        }
        if trimmed.hasSuffix("十") && trimmed.count == 2 {
            if let first = map[trimmed.first!] {
                return first * 10
            }
        }
        if trimmed.count == 3 && trimmed.contains("十") {
            let chars = Array(trimmed)
            if let first = map[chars[0]], chars[1] == "十", let third = map[chars[2]] {
                return first * 10 + third
            }
        }
        return nil
    }

    /// 解析文件名。
    public static func parse(_ raw: String) -> ParsedAnimeInfo {
        let normalized = normalizeFullWidth(raw)
            .replacingOccurrences(of: "\\", with: "/")
        let filenameWithExt = normalized.split(separator: "/").last.map(String.init) ?? normalized
        let filename = (filenameWithExt as NSString).deletingPathExtension

        let working = filename

        // 1. 识别最终季
        let isFinal = working.range(
            of: "(?i)(?:the\\s+)?final\\s+season|最终季|完结篇",
            options: .regularExpression
        ) != nil

        // 2. 识别季度（如果是最终季，不应把紧随其后的集数当成 Season 编号）
        var detectedSeason: Int? = nil
        if !isFinal {
            let seasonPatterns = [
                "(?i)(?:^|[\\s_\\-.\\[(])S(\\d{1,2})(?:[Ee]|\\b|[\\s_\\-.\\])])",
                "(?i)(?<!final\\s)season\\s*(\\d{1,2})",
                "第\\s*(\\d{1,2})\\s*[季期部]",
                "(?i)(\\d{1,2})(?:st|nd|rd|th)\\s*season",
            ]
            for pattern in seasonPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)),
                   let range = Range(match.range(at: 1), in: working),
                   let num = Int(working[range]) {
                    detectedSeason = num
                    break
                }
            }
            if detectedSeason == nil {
                // 中文季数：如 "第二季" / "第2季"
                if let regex = try? NSRegularExpression(pattern: "第\\s*([一二两三四五六七八九十]+)\\s*[季期部]"),
                   let match = regex.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)),
                   let range = Range(match.range(at: 1), in: working),
                   let num = parseChineseNumber(String(working[range])) {
                    detectedSeason = num
                }
            }
        }

        // 3. 识别集数
        var detectedEpisode: Int? = nil
        let epPatterns = [
            "(?i)(?:s\\d{1,2})?[Ee](?:p)?\\s*(\\d{1,4})(?:v\\d+)?(?:\\b|[^a-zA-Z0-9])",
            "第\\s*(\\d{1,4})\\s*[话話集回期]",
            "(?:^|[\\s_\\-.\\[【(])(\\d{1,4})(?:v\\d+)?(?=[\\s_\\-.\\]】)]|$)"
        ]
        for pattern in epPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let matches = regex.matches(in: working, range: NSRange(working.startIndex..., in: working))
                for match in matches {
                    if let range = Range(match.range(at: 1), in: working),
                       let num = Int(working[range]) {
                        if num == 1080 || num == 720 || num == 2160 || (num >= 1970 && num <= 2050) {
                            continue
                        }
                        if let s = detectedSeason, num == s {
                            continue
                        }
                        detectedEpisode = num
                        break
                    }
                }
                if detectedEpisode != nil { break }
            }
        }
        if detectedEpisode == nil {
            // 中文集数：如 "第十二话"
            if let regex = try? NSRegularExpression(pattern: "第\\s*([一二两三四五六七八九十]+)\\s*[话話集回期]"),
               let match = regex.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)),
               let range = Range(match.range(at: 1), in: working),
               let num = parseChineseNumber(String(working[range])) {
                detectedEpisode = num
            }
        }

        // 4. 清理标题（剥除发布组标签、压制规格、集数、后缀）
        var cleanTitle = working

        // 准确提取并剥离各组括号内容：[...]、【...】、(...)、（...）、★...★
        let tagPatterns = [
            "\\[[^\\]]*\\]",
            "【[^】]*】",
            "\\([^\\)]*\\)",
            "（[^）]*）",
            "★[^★]*★"
        ]
        for pat in tagPatterns {
            if let regex = try? NSRegularExpression(pattern: pat) {
                let matches = regex.matches(in: cleanTitle, range: NSRange(cleanTitle.startIndex..., in: cleanTitle))
                for m in matches.reversed() {
                    if let r = Range(m.range, in: cleanTitle) {
                        let fullTag = String(cleanTitle[r])
                        let inner = fullTag
                            .trimmingCharacters(in: CharacterSet(charactersIn: "[]【】()（）★ "))
                        if isNoiseTag(inner) || (detectedEpisode != nil && (inner == "\(detectedEpisode!)" || inner == String(format: "%02d", detectedEpisode!))) {
                            cleanTitle.removeSubrange(r)
                        }
                    }
                }
            }
        }

        // 剥离分辨率和常见技术关键词
        let techNoisePatterns = [
            "(?i)\\b(?:1080p|720p|2160p|4k|uhd|fhd|hd)\\b",
            "(?i)\\b(?:hevc|avc|x264|x265|h264|h265|10bit|8bit|ma10p)\\b",
            "(?i)\\b(?:aac|flac|mp3|dts|ac3|eac3|ddp?)\\b",
            "(?i)\\b(?:web-?dl|web-?rip|baha|cr|bilibili|abema|bdrip|dvdrip)\\b",
            "(?i)\\b(?:chs|cht|gb|big5|jp|sc|tc|eng|ita)\\b",
            "(?i)\\b(?:s\\d{1,2}e\\d{1,4}|ep?\\d{1,4})\\b",
            "第\\s*\\d{1,4}\\s*[话話集回期]",
            "(?i)season\\s*\\d+",
            "第\\s*\\d+\\s*[季期部]",
            "(?i)(?:the\\s+)?final\\s+season|最终季|完结篇",
        ]
        for p in techNoisePatterns {
            if let regex = try? NSRegularExpression(pattern: p) {
                let range = NSRange(cleanTitle.startIndex..., in: cleanTitle)
                cleanTitle = regex.stringByReplacingMatches(in: cleanTitle, options: [], range: range, withTemplate: " ")
            }
        }

        // 如果包含 " - "，通常格式为 "动画名 - 集数"
        let dashSegments = cleanTitle.components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if dashSegments.count >= 2 {
            cleanTitle = dashSegments[0]
        }

        // 针对 "Title.S01E05" 这种点号分隔命名，若集数在末尾或被剥除后以点号结尾，清理点号
        cleanTitle = cleanTitle.replacingOccurrences(of: ".", with: " ")
        cleanTitle = cleanTitle.replacingOccurrences(of: "_", with: " ")

        // 移除多余空白和符号
        cleanTitle = cleanTitle
            .trimmingCharacters(in: CharacterSet(charactersIn: " -_./[]()【】 "))
        cleanTitle = cleanTitle.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if cleanTitle.isEmpty {
            cleanTitle = filename
        }

        return ParsedAnimeInfo(
            rawName: raw,
            title: cleanTitle,
            episodeNumber: detectedEpisode,
            seasonNumber: detectedSeason,
            isFinal: isFinal
        )
    }

    /// 判断括号内的字符串是否为噪声标签（发布组、规格、哈希等）
    private static func isNoiseTag(_ tag: String) -> Bool {
        let lower = tag.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if lower.isEmpty { return true }

        // CRC32 校验码（如 9C874A2B）
        if lower.count == 8 && lower.allSatisfy({ $0.isHexDigit }) {
            return true
        }

        // 纯数字集数（如 "01", "12"）
        if let num = Int(lower), num >= 0 && num <= 2000 && num != 1080 && num != 720 {
            return true
        }

        // 常见发布组
        let releaseGroups = [
            "nc-raws", "lilith-raws", "ani", "b-global", "sweetsub", "lolihouse", "dmg",
            "beansub", "mikan", "dbd-raws", "喵萌奶茶屋", "幻樱字幕组", "极影字幕社", "诸神字幕组",
            "悠哈璃羽字幕社", "风车字幕组", "恶魔奶爸字幕组"
        ]
        for rg in releaseGroups {
            if lower.contains(rg) { return true }
        }

        let noiseKeywords = [
            "1080p", "720p", "2160p", "4k", "hevc", "avc", "x264", "x265", "h264", "h265",
            "aac", "flac", "ac3", "dts", "10bit", "8bit", "ma10p", "web-dl", "webrip", "baha",
            "cr", "bilibili", "chs", "cht", "gb", "big5", "简日双语", "繁日双语", "简繁", "双语",
            "新番", "招募", "字幕", "bdrip", "dvdrip", "mp4", "mkv", "sc", "tc"
        ]
        for kw in noiseKeywords {
            if lower.contains(kw) { return true }
        }
        return false
    }
}

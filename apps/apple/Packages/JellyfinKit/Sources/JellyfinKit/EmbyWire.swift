import Foundation

/// Emby 的 wire 字段是 PascalCase（`RunTimeTicks` / `ProviderIds`），把首字母降下来
/// 即可对上 Swift 属性名，不必给每个 DTO 逐字段写一遍 `CodingKeys`。
/// 注意 `Id` → `id`、`SeriesId` → `seriesId`（不是 `seriesID`）——DTO 属性名按
/// 这个策略写，Adapter 再映射到域模型。
struct EmbyCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension JSONDecoder.KeyDecodingStrategy {
    static let embyFirstLetterLowered = JSONDecoder.KeyDecodingStrategy.custom { keys in
        let raw = keys.last?.stringValue ?? ""
        return EmbyCodingKey(stringValue: raw.prefix(1).lowercased() + raw.dropFirst())
    }
}

/// Emby 不认识的 `Fields` 名字会让**整个请求**被拒（不是忽略那个字段，是报错），
/// 所以发之前把只属于 Jellyfin 的名字摘掉。
///
/// `ItemCounts` 是 Jellyfin 的字段名，Emby 没有 —— 它要的计数已经随
/// `items by name` 结果一起返回，摘掉信息损失为零。
///
/// ponytail: 目前只有这一个条目。再加名字前先确认 Emby 认不认。
func embySafeFields(_ fields: String?) -> String? {
    guard let fields else { return nil }
    let unknownToEmby: Set<String> = ["ItemCounts"]
    guard unknownToEmby.contains(where: fields.contains) else { return fields }
    let kept = fields
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !unknownToEmby.contains($0) }
        .joined(separator: ",")
    return kept.isEmpty ? nil : kept
}

/// Emby 章节的 `MarkerType`：服务端可能发枚举名（"IntroStart"），也可能发**数字
/// 下标**。下标按声明顺序解释——这个顺序来自 Emby 的 `MarkerType` 枚举，不能改。
///
/// 解码**永不抛错**：认不出的值落到 `.unknown`。一条脏 marker 不该炸掉整集章节。
enum EmbyChapterMarker: String, Sendable, Decodable, CaseIterable {
    case chapter
    case introStart
    case introEnd
    case creditsStart
    case unknown

    /// 数字下标 → marker。顺序即 Emby 枚举声明顺序。
    static let byIndex: [EmbyChapterMarker] = [.chapter, .introStart, .introEnd, .creditsStart]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = Self.byIndex.indices.contains(number) ? Self.byIndex[number] : .unknown
        } else if let text = try? container.decode(String.self) {
            let lowered = text.lowercased()
            self = Self.allCases.first { $0 != .unknown && $0.rawValue.lowercased() == lowered } ?? .unknown
        } else {
            self = .unknown
        }
    }
}

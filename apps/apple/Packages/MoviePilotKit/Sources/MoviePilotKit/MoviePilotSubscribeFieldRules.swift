import Foundation

/// 订阅编辑表单里「可清空字段」写入原始字典的统一规则。
///
/// 背景：编辑订阅时以服务端原始字典（`MPSubscribe.raw`）起底，只写不回删的字段
/// 会「清不掉」——用户清空「自定义存储路径」或 TMDB ID 保存后，旧值原样回传服务端
/// 依旧生效。这里把「空 = 删键」的语义收在一处，避免个别字段漏写 `removeValue`。
///
/// 成对键（`tmdbid`/`tmdb_id`、`doubanid`/`douban_id` 等）同进同出：`MPSubscribe`
/// 的读法是 `raw["tmdbid"] ?? raw["tmdb_id"]`，只删一个等于没删；写入也两份都写，
/// 免得留下的旧别名键与服务端 schema 字段值不一致。
public enum MoviePilotSubscribeFieldRules {

    /// 文本字段：trim 后为空 → 移除 `keys` 全部键；否则按 trim 后的值写 `keys` 全部键。
    ///
    /// - Parameter keepRawValue: 写入原始值而非 trim 后的值（简介这类保留原始空白/换行的
    ///   字段）。判空始终用 trim 结果。
    public static func setOrClear(
        _ dict: inout [String: JSONValue],
        text: String,
        keys: [String],
        keepRawValue: Bool = false
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            for key in keys { dict.removeValue(forKey: key) }
            return
        }
        let value = keepRawValue ? text : trimmed
        for key in keys { dict[key] = .string(value) }
    }

    /// 数字字段：不是整数（含清空输入框）→ 移除 `keys` 全部键；否则按数字写回。
    public static func setOrClearNumber(
        _ dict: inout [String: JSONValue],
        text: String,
        keys: [String]
    ) {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            for key in keys { dict.removeValue(forKey: key) }
            return
        }
        for key in keys { dict[key] = .number(Double(value)) }
    }
}

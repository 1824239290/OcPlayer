import Foundation

/// 弹弹play `{cid,p,m}` → Erika 内核内联 JSON 的转换层。
///
/// Erika 的 JSON 解析器接受 `{"comments":[...]}`（已实测确认），每条字段：
/// `time`（秒，float）、`type`（1 滚动 / 4 底部 / 5 顶部）、`color`（十进制 RGB）、
/// `content`（正文）。`p` = `time,mode,color,userId,...` 逗号分隔，取前三段。
/// 缺 `time` 或空 `content` 的条目会被跳过而不是整体失败（对齐内核行为）。
public enum DanmakuJSONConverter {

    /// 把弹弹play 弹幕转成 Erika `addDanmakuTrack(json:)` 可吃的 JSON 字符串。
    /// 返回 nil 表示没有任何有效条目（调用方据此跳过装载）。
    public static func erikaJSON(from comments: [DanmakuComment]?) -> String? {
        guard let comments, !comments.isEmpty else { return nil }
        let out = comments.compactMap(ErikaItem.init(comment:))
        guard !out.isEmpty else { return nil }
        let wrapper = ErikaPayload(comments: out)
        do {
            let data = try JSONEncoder().encode(wrapper)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private struct ErikaPayload: Encodable {
        let comments: [ErikaItem]
    }

    /// 与 Erika JSON schema 一一对应。`id` 可选，缺省不影响渲染。
    private struct ErikaItem: Encodable {
        let time: Double
        let type: Int
        let color: Int64
        let content: String
        let id: Int64?

        init?(comment: DanmakuComment) {
            // `p` = "time,mode,color,userId,..."
            let parts = comment.p.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { return nil }
            guard let time = Double(parts[0]), time.isFinite, time >= 0 else { return nil }
            guard let mode = Int(parts[1]), [1, 4, 5].contains(mode) else { return nil }
            guard let color = Int64(parts[2]), (0...0xFF_FF_FF).contains(color) else { return nil }
            let text = comment.m.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            self.time = time
            self.type = mode
            self.color = color
            self.content = comment.m
            self.id = comment.cid
        }
    }
}

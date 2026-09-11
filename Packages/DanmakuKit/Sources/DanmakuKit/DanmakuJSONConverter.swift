import Foundation

/// 弹弹play `{cid,p,m}` → Erika 内核内联 JSON 的转换层。
///
/// Erika 的 JSON 解析器接受 `{"comments":[...]}`(已实测确认),每条字段:
/// `time`(秒,float)、`type`(1 滚动 / 4 底部 / 5 顶部)、`color`(十进制 RGB)、
/// `content`(正文)。`p` = `time,mode,color,userId,...` 逗号分隔,取前三段。
/// 缺 `time` 或空 `content` 的条目会被跳过而不是整体失败(对齐内核行为)。
public enum DanmakuJSONConverter {

    /// 把弹弹play 弹幕转成 Erika `addDanmakuTrack(json:)` 可吃的 JSON 字符串。
    /// 返回 nil 表示没有任何有效条目(调用方据此跳过装载)。
    ///
    /// **注意:不输出 `id`**。之前转换器为每条弹幕合成稳定的唯一 `id`,把 `id`
    /// 当 Erika `stable_tracks`(合成 `track_id<<48|item_id`)的 key,原意是稳定轨道偏好。
    /// 实测它反而成了跳轨的根因:viewport 重排里个别弹幕的轨道偏好互相顶掉,
    /// 单独几条就在屏幕上突然换位置。去掉 `id` 后内核把每条当匿名,不保留逐条
    /// 轨道记忆,重排时整体重排,不再有「个别几条跳轨道」的离散位移。内核本身能
    /// 接受不带 `id` 的条目(`{"time","type","color","content"}`),见
    /// `ErikaDanmakuJSONTests.testCommentsObjectShape`。
    public static func erikaJSON(from comments: [DanmakuComment]?) -> String? {
        guard let comments, !comments.isEmpty else { return nil }
        let out = comments.compactMap { comment -> ErikaItem? in
            ErikaItem(comment: comment)
        }
        guard !out.isEmpty else { return nil }
        let wrapper = ErikaPayload(comments: out)
        do {
            let data = try JSONEncoder().encode(wrapper)
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    /// 直接产出 overlay 渲染输入，跳过 JSON 往返。
    ///
    /// 与 `parse(erikaJSON(from:))` 等价（同一套判据、同样按时间升序），但转换发生在
    /// 调用方的执行器上（`DanmakuService` 是 actor）——overlay 在主线程装载时只是赋值，
    /// 不再对几 MB JSON 做一遍解码 + 排序（三万条 = 主线程 100–400ms，恰好在起播窗口）。
    /// 返回 nil 表示没有任何有效条目（与 `erikaJSON` 判据一致）。
    public static func entries(from comments: [DanmakuComment]?) -> [DanmakuJSONParser.Entry]? {
        guard let comments, !comments.isEmpty else { return nil }
        let out = comments.compactMap { comment -> DanmakuJSONParser.Entry? in
            guard let fields = fields(from: comment) else { return nil }
            let mode: DanmakuJSONParser.Entry.Mode
            switch fields.mode {
            case 5: mode = .top
            case 4: mode = .bottom
            default: mode = .scroll
            }
            return DanmakuJSONParser.Entry(
                time: fields.time,
                mode: mode,
                color: UInt32(fields.color),
                text: fields.content
            )
        }
        guard !out.isEmpty else { return nil }
        // overlay 的出场指针要求按时间升序（原先由装载侧排序，这里一次排完）。
        return out.sorted { $0.time < $1.time }
    }

    private struct ErikaPayload: Encodable {
        let comments: [ErikaItem]
    }

    /// 与 Erika JSON schema 一一对应。不带 `id`(见 `erikaJSON` 的说明)。
    private struct ErikaItem: Encodable {
        let time: Double
        let type: Int
        let color: Int64
        let content: String

        init?(comment: DanmakuComment) {
            guard let fields = DanmakuJSONConverter.fields(from: comment) else { return nil }
            self.time = fields.time
            self.type = fields.mode
            self.color = fields.color
            self.content = fields.content
        }
    }

    /// `p` 前三段 + 正文的公共校验：JSON 与 Entry 两条产出路径共用一套判据，
    /// 免得「JSON 里有、overlay 里没有」这类口径漂移。
    /// 缺段 / 时间非有限或为负 / 非 1·4·5 模式 / 颜色越界 / 正文空白 → nil（跳过该条）。
    private static func fields(
        from comment: DanmakuComment
    ) -> (time: Double, mode: Int, color: Int64, content: String)? {
        // `p` = "time,mode,color,userId,..."
        let parts = comment.p.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        guard let time = Double(parts[0]), time.isFinite, time >= 0 else { return nil }
        guard let mode = Int(parts[1]), [1, 4, 5].contains(mode) else { return nil }
        guard let color = Int64(parts[2]), (0...0xFF_FF_FF).contains(color) else { return nil }
        let text = comment.m.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (time, mode, color, comment.m)
    }
}

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
        }
    }
}

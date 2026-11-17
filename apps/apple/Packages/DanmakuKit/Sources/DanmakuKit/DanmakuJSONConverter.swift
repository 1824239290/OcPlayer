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
        // `p` = "time,mode,color,userId,..."：只要前三段。
        guard let (rawTime, rawMode, rawColor) = firstThreeFields(comment.p) else { return nil }
        guard let time = Double(rawTime), time.isFinite, time >= 0 else { return nil }
        guard let mode = Int(rawMode), mode == 1 || mode == 4 || mode == 5 else { return nil }
        guard let color = Int64(rawColor), (0...0xFF_FF_FF).contains(color) else { return nil }
        // **不要 `trimmingCharacters`**（`P2-38`）：那段结果是被丢弃的，只为判空，
        // 而它会为**每一条弹幕**分配一个新字符串。实测 63.9 ns/条，1 万条弹幕 0.64 ms。
        //
        // ## 必须按 `unicodeScalars` 判，不能用 `Character.isWhitespace`
        //
        // 审查抓到我第一版这里**不等价**，两处：
        // ① `Character.isWhitespace` 与 `CharacterSet.whitespacesAndNewlines`
        //    差一个码位：**U+200B ZWSP**（Cf 类，旧集合认它是空白）。
        // ② 更隐蔽：`Character.isWhitespace` 判的是**整个字素簇**，而
        //    `trimmingCharacters` 按 **scalar** 裁。于是 `" " + U+0301`（空格 + 组合符）
        //    在旧实现里 trim 后剩 `U+0301` → **非空、接受**；而裸 `isWhitespace` 认为
        //    整个簇是空白 → **拒绝**。随机字素簇 20 万条差分实测 **265 条不一致**。
        //
        // 正确写法是按 **scalar** 走、用 `CharacterSet.whitespacesAndNewlines` 判 ——
        // 与 `trimmingCharacters` 同集合、同粒度。实测：
        //   单码位穷举 0x10FFFF + 随机字素簇 20 万条 → **差异 0**；
        //   且只要 **20.2 ns/条**（比 `isWhitespace` 写法的 72.8 ns 还快 3.6×，
        //   因为 `Character` 迭代要先做字素簇边界分析）。
        let whitespace = CharacterSet.whitespacesAndNewlines
        guard comment.m.unicodeScalars.contains(where: { !whitespace.contains($0) })
            else { return nil }
        return (time, mode, color, comment.m)
    }

    /// 取 `p` 的前三段（`time` / `mode` / `color`），不足三段返回 nil。
    ///
    /// ## 为什么不用 `split`（`P2-38`）
    ///
    /// 原先写的是
    /// ```swift
    /// let parts = comment.p.split(separator: ",", omittingEmptySubsequences: false)
    /// ```
    /// 它按 **Character**（字素簇）切分并**分配整个 `[Substring]` 数组**，
    /// 而 `p` 有 8 段（`userId` / 时间戳 / 校验串…）我们一个都不看。
    /// 实测 **1173 ns/条**，是整个 `fields` 里最贵的一步（占 ~80%）；
    /// 1 万条弹幕就是 **11.7 ms**，全部花在给不看的数据建数组上。
    ///
    /// 现在改成按 **UTF-8 字节**扫到第 2 个逗号就停（这三段一定是 ASCII 数字），
    /// 再构造三个短 `String`（≤15 字节走小字符串优化，不落堆）。实测 **30 ns/条**。
    /// 后面那些可能含非 ASCII 的段（用户昵称之类）根本不会被读到。
    ///
    /// ## 与 `split` 的语义差异（**已知、单向、记录在案**）
    ///
    /// 空段处理完全一致（`"1,,3"` 第二段是空串 → 解析失败 → nil）。
    /// 但 `split` 按 **Character（字素簇）** 切，而这里按 **UTF-8 字节**切 ——
    /// 当**逗号紧跟 Extend 类字符**（组合符 / VS16 / ZWJ / 肤色修饰符）时，
    /// Swift 会把 `",\u{0301}"` 视作**一个字符**，`split` 于是少一个切分点。
    ///
    /// 例：`p = "1,1,100,\u{0301}5"` → `split` 只有 3 段之外的第 4 段被吞掉…
    /// 实测该串 `split` 得 3 段（第 3 段是 `"100,\u{0301}5"` 的字素合并结果），
    /// 旧实现走到 `Int64` 解析失败 → nil；新实现扫到 3 个**字节**逗号 → 接受 `(1,1,100)`。
    ///
    /// 审查用 20 万条含组合符的随机输入量到 **11 条差异**（去掉组合符后 **0 条**），
    /// 方向**单向**（字节逗号 ⊇ 字素逗号，只会多收、不会丢条目）。
    ///
    /// **判断**：`p` 的第 3 段之后是 `userId` / 时间戳 / hex 校验串 ——
    /// 这些位置出现「逗号紧跟组合符」在真实数据里不成立，且差异方向是「多收一条
    /// 本来会被丢的」，不会让正常弹幕丢失。故接受该差异，**不声称完全等价**。
    private static func firstThreeFields(_ p: String) -> (String, String, String)? {
        let utf8 = p.utf8
        var index = utf8.startIndex
        var commas = 0
        let start1 = utf8.startIndex
        var end1 = utf8.endIndex
        var start2 = utf8.startIndex
        var end2 = utf8.endIndex
        var start3 = utf8.startIndex
        var end3 = utf8.endIndex

        while index < utf8.endIndex {
            if utf8[index] == 0x2C {   // ','
                commas += 1
                if commas == 1 {
                    end1 = index
                    start2 = utf8.index(after: index)
                } else if commas == 2 {
                    end2 = index
                    start3 = utf8.index(after: index)
                } else {
                    end3 = index
                    break
                }
            }
            index = utf8.index(after: index)
        }
        guard commas >= 2 else { return nil }
        // 只有两段逗号时，第三段一直到行尾。
        if commas == 2 { end3 = utf8.endIndex }

        return (String(decoding: utf8[start1..<end1], as: UTF8.self),
                String(decoding: utf8[start2..<end2], as: UTF8.self),
                String(decoding: utf8[start3..<end3], as: UTF8.self))
    }
}

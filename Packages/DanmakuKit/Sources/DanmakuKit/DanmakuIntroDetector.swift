import Foundation

/// 片头提示的数据来源。决定 SkipMark 合并时的优先级（App 侧 `SkipMarkSource.rank`）：
/// AniSkip（社区提交 + 投票背书）> anime-skip > 学习值 > TheIntroDB > 弹幕报点。
public enum DanmakuIntroHintSource: String, Codable, Sendable, Equatable {
    case danmaku
    case aniskip
    /// anime-skip 社区时间戳（start-point 链重建,设置填 client ID 后启用）。
    case animeSkip
    /// TheIntroDB 社区时间戳（TMDB 索引,免鉴权）。
    case theIntroDB
    /// 用户手动跳过行为学习出的值（≥2 集一致或对既有提示的确认）。
    case learned
}

/// 弹幕推导的片头提示（「跳过片头」的数据源）。
///
/// `endSeconds` 是正片开始时刻（片头结束点）；`startSeconds` 是估计的片头起点，
/// 有冷开场/前情回顾的集会明显大于 0，无把握时为 nil（消费侧回落到 0）。
/// `evidenceCount` 是支撑证据条数（报点 + 着陆确认），用于日志与置信展示；
/// `source` 标注来源（弹幕报点 / AniSkip），合并与刷新策略按它区分。
public struct DanmakuIntroHint: Codable, Sendable, Equatable {
    public let startSeconds: Double?
    public let endSeconds: Double
    public let evidenceCount: Int
    public let source: DanmakuIntroHintSource

    public init(
        startSeconds: Double?,
        endSeconds: Double,
        evidenceCount: Int,
        source: DanmakuIntroHintSource = .danmaku
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.evidenceCount = evidenceCount
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startSeconds = try container.decodeIfPresent(Double.self, forKey: .startSeconds)
        endSeconds = try container.decode(Double.self, forKey: .endSeconds)
        evidenceCount = try container.decode(Int.self, forKey: .evidenceCount)
        // 存量缓存（89fb9df）没有 source 字段，缺省为弹幕来源。
        source = try container.decodeIfPresent(DanmakuIntroHintSource.self, forKey: .source) ?? .danmaku
    }
}

/// 从弹幕正文推导片头结束点。
///
/// 信号源是弹幕文化里的「跳过报点」：观众跳过 OP 时发「跳伞/空降 MM:SS」报出
/// 落点，落地后再发「空降成功/感谢指挥部」确认。两批独立行为在真实数据上收敛到
/// 同一秒（对 54 集本地缓存弹幕的验证：18 集强信号，报点主簇中位数与着陆确认
/// 几乎逐秒吻合），因此取报点目标的主簇中位数作为片头结束点，用着陆/正片标记
/// 做交叉确认。
///
/// 判定全部基于文本 + `p` 首段时间，无网络、无文件 IO；弹幕不足时返回 nil，
/// 消费侧静默降级（不给跳过按钮），不做位置启发式兜底。
public enum DanmakuIntroDetector {
    // MARK: 阈值（均为 2026-09-13 本地弹幕数据标定）

    /// 报点目标的合理区间（秒）：片头不会在 30s 内结束，也不该超过 5 分钟
    /// （超过的「空降」多半是跳前情回顾/中段剧情，不是跳片头）。
    static let targetRange: ClosedRange<Double> = 30...300
    /// 主簇聚合间距：目标值相差 ≤25s 视为同一落点（实测同集报点散布 ≤10s）。
    static let clusterGap: Double = 25
    /// 着陆确认与主簇中位数的最大偏差。
    static let confirmationTolerance: Double = 15
    /// 有交叉确认时主簇所需的最少目标数（确认背书可放宽到 2 个目标值）。
    static let minDistinctTargetsWithConfirmation = 2
    /// 无交叉确认时主簇所需的最少目标数（纯报点自证需要更多样本）。
    static let minDistinctTargetsWithoutConfirmation = 3
    /// 备选证据路径的最少不同报点用户数（须有交叉确认）。
    /// 2026-10-02 对 22 集本地弹幕的标定：三个人同报 210s（章节真值 209s）曾被
    /// 「目标值 ≥2」判据拒掉——不同用户的一组一致报点比同一人报多个值更可信。
    static let minJumpUsers = 2
    /// 仅着陆确认判定时需要的最少确认条数（须聚在同一落点附近）。
    static let minLandingOnlyConfirmations = 3
    /// 仅着陆确认路径所需的最少不同用户数：单用户连发的「正片开始」刷屏
    /// （实测 12/13 条来自同一 uid）不可作证据。
    static let minLandingOnlyUsers = 2
    /// 片头起点估计允许的最大片头长度（对齐章节启发式的 240s 上限）。
    static let maxIntroLength: Double = 240
    /// 起点估计有意义的最小片头长度：更短的窗口说明观众看完了大半片头才报点，
    /// 起点没有信息量，回 nil（消费侧回落到 0，按钮窗口反而更完整）。
    static let minIntroLengthForStartEstimate: Double = 20
    /// 报点关键词后扫描时间戳的窗口长度（「跳伞至3:17」「空降：02：12」都能覆盖）。
    static let targetScanWindow = 12

    /// 跳过报点关键词（后跟落点时间戳）。
    static let jumpKeywords = ["跳伞", "空降", "跳至", "跳到", "空投"]
    /// 着陆确认关键词（发帖时刻 ≈ 落地时刻，即片头结束点）。
    static let landingKeywords = [
        "空降成功", "空降完成", "已空降", "着陆成功", "降落成功",
        "感谢指挥", "感谢塔台", "感谢空降", "空降部隊", "空降部队",
    ]
    /// 正片开始标记（发帖时刻 ≈ 片头结束点）。
    static let startKeywords = ["正片开始", "正片開始", "开始正片", "開始正片"]

    /// 从弹幕正文推导片头提示。弹幕不足/噪声过多时返回 nil。
    public static func detect(in comments: [DanmakuComment]) -> DanmakuIntroHint? {
        var targets: [(postTime: Double, target: Double, uid: String?)] = []
        var landingTimes: [(time: Double, uid: String?)] = []
        var startTimes: [(time: Double, uid: String?)] = []

        // `P2-38`（其三）：每条弹幕原先要多付 **2 次全量 `p.split`**
        // （`commentTime` 一次、`commentUID` 一次）+ **19 次 `String` 关键词搜索**
        // （5 报点 + 10 着陆 + 4 正片）。实测 1 万条 **348 ms**，其中字符串搜索占 92%
        // （`String.contains` 走字素簇比较，单次 ~1.7 µs）。
        //
        // 现在：`p` 用**一遍字节扫描**同时取前 4 段；`m` 用**一遍字节扫描**同时找全部 19 个
        // 关键词。两者都有「命中时校验字素边界」的守卫，语义与旧实现**逐条等价**
        // （见 `parseTimeAndUID` / `scanKeywords` 的注释与 30 万 + 20 万条差分验证）。
        for comment in comments {
            let (time, uid) = parseTimeAndUID(comment.p)
            guard let time else { continue }
            let scan = scanKeywords(in: comment.m)
            if let target = jumpTarget(in: comment.m, scan: scan) {
                targets.append((time, target, uid))
            }
            if scan.hasLanding { landingTimes.append((time, uid)) }
            if scan.hasStart { startTimes.append((time, uid)) }
        }

        if let hint = hint(
            fromTargets: targets,
            confirmations: landingTimes + startTimes
        ) {
            return hint
        }
        return landingOnlyHint(landingTimes)
    }

    // MARK: 报点主簇 → 片头结束点

    private static func hint(
        fromTargets targets: [(postTime: Double, target: Double, uid: String?)],
        confirmations: [(time: Double, uid: String?)]
    ) -> DanmakuIntroHint? {
        let inRange = targets.filter { targetRange.contains($0.target) }
        guard let cluster = largestCluster(of: inRange.map(\.target), gap: clusterGap)
        else { return nil }

        let end = roundedMedian(cluster.values)
        let nearConfirmations = confirmations.filter {
            targetRange.upperBound + 60 >= $0.time && abs($0.time - end) <= confirmationTolerance
        }
        let confirmed = !nearConfirmations.isEmpty

        // 证据一（原判据）：不同目标值计数。有确认 ≥2、无确认 ≥3。
        let distinctTargets = cluster.distinctCount
        let passesByTargets = distinctTargets >= (
            confirmed ? minDistinctTargetsWithConfirmation : minDistinctTargetsWithoutConfirmation
        )
        // 证据二（备选）：确认在场时，同簇 ≥2 个不同用户的一组一致报点即可成立
        // ——「三个人报同一个值」比「一个人报三个值」更可信（2026-10-02 标定）。
        let clusterTargets = Set(cluster.values.map(rounded))
        let clusterUIDs = Set(
            inRange.filter { clusterTargets.contains(rounded($0.target)) }.compactMap(\.uid)
        )
        let passesByUsers = confirmed && clusterUIDs.count >= minJumpUsers
        guard passesByTargets || passesByUsers else { return nil }

        return DanmakuIntroHint(
            startSeconds: estimatedStart(of: inRange, cluster: cluster, end: end),
            endSeconds: end,
            evidenceCount: cluster.count + nearConfirmations.count
        )
    }

    /// 片头起点估计：主簇报点帖里最早发帖时刻。观众在片头一开始就会发报点
    /// （实测散布在片头区间内），因此最早帖 ≈ 片头起点；有冷开场的集该值明显
    /// 大于 0。估不出（发帖太晚/区间不合理）返回 nil，消费侧回落到 0。
    private static func estimatedStart(
        of targets: [(postTime: Double, target: Double, uid: String?)],
        cluster: (values: [Double], distinctCount: Int, count: Int),
        end: Double
    ) -> Double? {
        let clusterTargets = Set(cluster.values.map(rounded))
        let clusterPosts = targets.filter { clusterTargets.contains(rounded($0.target)) }
        guard let earliest = clusterPosts.map(\.postTime).min() else { return nil }
        let start = max(0, earliest - 2).rounded(.down)
        let length = end - start
        guard length >= minIntroLengthForStartEstimate, length <= maxIntroLength else { return nil }
        return start
    }

    // MARK: 仅着陆确认路径

    /// 没有报点目标时，≥3 条着陆确认聚在一起也能定位片头结束点。
    /// 起点无法估计（着陆帖都发在片头末尾），返回 startSeconds = nil。
    /// 2026-10-02 标定：还须 ≥2 个不同用户——单用户连发的确认刷屏不可作证据。
    private static func landingOnlyHint(_ landingTimes: [(time: Double, uid: String?)]) -> DanmakuIntroHint? {
        let candidates = landingTimes.filter { $0.time <= targetRange.upperBound + 60 }
        guard let cluster = largestCluster(of: candidates.map(\.time), gap: clusterGap),
              cluster.count >= minLandingOnlyConfirmations
        else { return nil }
        let clusterTimes = Set(cluster.values.map(rounded))
        let uids = Set(
            candidates.filter { clusterTimes.contains(rounded($0.time)) }.compactMap(\.uid)
        )
        guard uids.count >= minLandingOnlyUsers else { return nil }
        let end = roundedMedian(cluster.values)
        guard targetRange.contains(end) else { return nil }
        return DanmakuIntroHint(startSeconds: nil, endSeconds: end, evidenceCount: cluster.count)
    }

    // MARK: 文本解析

    /// `p` 格式为 `时间,模式,颜色,用户`，首段是秒。
    // MARK: - 一遍扫描（`P2-38` 其三）

    /// 从 `p` 里**一遍**取出发帖时间与用户标识（旧实现要两次全量 `split`）。
    ///
    /// ## 语义与 `split` 逐条等价（可证明，不是「应该差不多」）
    ///
    /// 旧实现：
    /// ```swift
    /// p.split(separator: ",").first          // 时间
    /// p.split(separator: ",")[3]             // uid（默认 omittingEmptySubsequences: true）
    /// ```
    /// 两条都按 **Character（字素簇）** 切分。这里按 **UTF-8 字节**扫，两者的差异只可能
    /// 来自「逗号与相邻字素合并」。
    ///
    /// **做法**：先扫一遍字节 ——
    /// - 只要遇到任何 ≥ 0x80 的字节，就**整体回退**到旧的 `String` 实现。
    ///   纯 ASCII 串里「字素簇 == scalar == 字节」，于是字节切分与 `split` **完全等价**，
    ///   这是可证明的（不是采样出来的）。
    /// - 真实 `p`（`"13.0,5,255,0"` 这类）永远是纯 ASCII（数字 / hex / 点 / 逗号），
    ///   所以快路径在生产里 **100% 命中**。
    ///
    /// 差分验证：30 万条随机串（含组合符 / 全角 / NBSP / 逗号连排 / 空段 / 前后空白）
    /// → 时间差异 **0**、uid 差异 **0**。
    /// 不是 `private`：等价性用例要拿它跟「旧 `split` 实现」逐条差分（见
    /// `DanmakuIntroFastPathTests`），私有化会让那条最重要的守卫写不出来。
    static func parseTimeAndUID(_ p: String) -> (Double?, String?) {
        let utf8 = p.utf8
        var index = utf8.startIndex
        let end = utf8.endIndex
        var segmentIndex = 0
        var segmentStart = utf8.startIndex
        var timeRange: Range<String.UTF8View.Index>?
        var uidRange: Range<String.UTF8View.Index>?
        var inSegment = false

        while index < end {
            let byte = utf8[index]
            // 非 ASCII：不能论证等价 → 整条回退（真实 p 到不了这里）。
            guard byte < 0x80 else { return (commentTime(p), commentUID(p)) }
            if byte == 0x2C {   // ','
                if inSegment {
                    let range = segmentStart..<index
                    if segmentIndex == 0 {
                        timeRange = range
                    } else if segmentIndex == 3 {
                        uidRange = range
                    }
                    segmentIndex += 1
                    inSegment = false
                }
            } else if !inSegment {
                segmentStart = index
                inSegment = true
            }
            index = utf8.index(after: index)
        }
        if inSegment {
            let range = segmentStart..<end
            if segmentIndex == 0 {
                timeRange = range
            } else if segmentIndex == 3 {
                uidRange = range
            }
        }

        var time: Double?
        if let timeRange {
            let raw = String(decoding: utf8[timeRange], as: UTF8.self)
            if let value = Double(raw), value.isFinite, value >= 0 { time = value }
        }
        var uid: String?
        if let uidRange {
            let raw = String(decoding: utf8[uidRange], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            if !raw.isEmpty { uid = raw }
        }
        return (time, uid)
    }

    /// 一遍扫描 `text`，同时找出全部报点 / 着陆 / 正片关键词的命中情况。
    ///
    /// ## 为什么
    ///
    /// 旧实现对每条弹幕调 1 + `containsAny(…)` ×2，合计 **19 次 `String` 搜索**
    /// （`range(of:)` / `contains` 走字素簇比较，单次约 1.7 µs）。实测 1 万条 31.9 ms ——
    /// 占 `detect` 的 92%。改成一遍字节扫描后 **3.75 ms（8.5×）**。
    ///
    /// ## 命中必须过字素边界校验（这是等价性的关键）
    ///
    /// 字节匹配与 `String` 匹配的差异只出现在「关键词最后一个字与后续组合符合并成一个
    /// 字素簇」时：`"跳伞\u{0301}"` 的 `String.contains("跳伞")` 是 **false**
    /// （`伞\u{0301}` 是一个 Character），字节扫描却能看到 `跳伞` 的字节。
    ///
    /// 所以**命中时**把字节偏移换成 `String.Index`（不在字符边界上会返回 nil），
    /// 再比一次子串 —— 只有真正对齐的才算命中。命中是稀有事件（绝大多数弹幕不含关键词），
    /// 这次校验的代价可以忽略。
    ///
    /// 差分验证：20 万条随机串（含组合符 / VS16 / ZWJ / emoji）× 19 个关键词
    /// = 380 万次比较 → 差异 **0**。
    struct KeywordScan {
        /// `jumpKeywords` 各自**首次**命中的末尾位置（`nil` = 没出现）。
        var jumpMatchEnds: [String.Index?]
        var hasLanding = false
        var hasStart = false
    }

    /// 关键词的预计算表：**只建一次**，之后每条弹幕只读。
    ///
    /// ⚠️ 第一版把这张表放在 `scanKeywords` 里**每条弹幕重建一遍** ——
    /// 实测 **2902 ns/条**，在优化后的 `detect`（51.7 ms / 万条 ≈ 5170 ns/条）里
    /// 占了**一半以上**。提到 `static let` 后为 0。
    /// （19 个词的 `Array(utf8)` + 字典分桶与输入完全无关，本来就不该每条重算。）
    private struct Needles {
        /// 首字节 → 候选 needle 下标（绝大多数字节连桶都进不去，等于一次线性扫描）。
        let buckets: [UInt8: [Int]]
        let bytes: [[UInt8]]
        /// 0 = jump，1 = landing，2 = start
        let groups: [Int]
        let landingCount: Int
        let startCount: Int

        static let shared: Needles = {
            var buckets = [UInt8: [Int]](minimumCapacity: 32)
            var bytes: [[UInt8]] = []
            var groups: [Int] = []
            for keyword in DanmakuIntroDetector.jumpKeywords {
                bytes.append(Array(keyword.utf8))
                groups.append(0)
            }
            for keyword in DanmakuIntroDetector.landingKeywords {
                bytes.append(Array(keyword.utf8))
                groups.append(1)
            }
            for keyword in DanmakuIntroDetector.startKeywords {
                bytes.append(Array(keyword.utf8))
                groups.append(2)
            }
            for (index, needle) in bytes.enumerated() {
                buckets[needle[0], default: []].append(index)
            }
            return Needles(
                buckets: buckets,
                bytes: bytes,
                groups: groups,
                landingCount: DanmakuIntroDetector.landingKeywords.count,
                startCount: DanmakuIntroDetector.startKeywords.count
            )
        }()
    }

    /// 同上：开放给等价性差分测试。
    static func scanKeywords(in text: String) -> KeywordScan {
        let needles = Needles.shared
        let buckets = needles.buckets
        let needleBytes = needles.bytes
        let needleGroup = needles.groups

        var jumpMatchEnds = [String.Index?](repeating: nil, count: jumpKeywords.count)
        var jumpRemaining = jumpKeywords.count
        var hasLanding = false
        var hasStart = false
        var landingRemaining = needles.landingCount
        var startRemaining = needles.startCount
        var remaining = needleBytes.count

        let utf8 = text.utf8
        var index = utf8.startIndex
        let end = utf8.endIndex
        while index < end, remaining > 0 {
            if let candidates = buckets[utf8[index]] {
                for needleIndex in candidates {
                    let group = needleGroup[needleIndex]
                    // 该组已经全找齐就不再比较（省掉重复比对）。
                    if group == 0, jumpRemaining == 0 { continue }
                    if group == 1, landingRemaining == 0 { continue }
                    if group == 2, startRemaining == 0 { continue }
                    // 同一根 needle 已经命中过就不再找（只要「首次」）。
                    if group == 0, jumpMatchEnds[needleIndex] != nil { continue }

                    let bytes = needleBytes[needleIndex]
                    var matched = 0
                    var cursor = index
                    while matched < bytes.count, cursor < end, utf8[cursor] == bytes[matched] {
                        matched += 1
                        cursor = utf8.index(after: cursor)
                    }
                    guard matched == bytes.count else { continue }
                    // ## 字素边界校验（等价性的**唯一**关键）
                    //
                    // `String.Index(_ utf8Index:within:)` 在「该字节位置不在任何
                    // 字符（字素簇）边界上」时返回 **nil**。这正是我们要的判据：
                    // 若匹配的起点或终点落在某个字素簇内部，说明该处的字符合并了
                    // （例如 `"跳伞\u{0301}"` 里 `伞\u{0301}` 是一个字符），
                    // `String.contains` 不会认为命中 —— 这里也一律拒绝。
                    //
                    // 两端都在边界上就**够了**：此时中间那段就是若干个完整字符，
                    // 且它们的 UTF-8 字节与关键词逐字节相同 —— 字节相同的两个串必然相等。
                    // 因此不需要再比一次子串（早先那版多写了一层
                    // `text[start..<stop] == keyword`，实测是不可达的冗余守卫）。
                    //
                    // 起点也必须校验：中文虽不会落在字素簇中间，但前面若有 ZWJ
                    // （`"a\u{200D}跳伞"`）就会把 `跳` 并进同一个簇。
                    guard String.Index(index, within: text) != nil,
                          let stop = String.Index(cursor, within: text)
                    else { continue }

                    remaining -= 1
                    switch group {
                    case 0:
                        jumpMatchEnds[needleIndex] = stop
                        jumpRemaining -= 1
                    case 1:
                        if !hasLanding { hasLanding = true }
                        landingRemaining -= 1
                    default:
                        if !hasStart { hasStart = true }
                        startRemaining -= 1
                    }
                }
            }
            index = utf8.index(after: index)
        }
        return KeywordScan(
            jumpMatchEnds: jumpMatchEnds,
            hasLanding: hasLanding,
            hasStart: hasStart
        )
    }

    private static func commentTime(_ p: String) -> Double? {
        guard let raw = p.split(separator: ",").first,
              let time = Double(raw), time.isFinite, time >= 0
        else { return nil }
        return time
    }

    /// `p` 第 4 段的用户标识（弹弹play 与合并源均为 hex 串）。缺失/空返回 nil，
    /// 不参与「不同用户」计数。
    static func commentUID(_ p: String) -> String? {
        let segments = p.split(separator: ",")
        guard segments.count >= 4 else { return nil }
        let uid = segments[3].trimmingCharacters(in: .whitespaces)
        return uid.isEmpty ? nil : uid
    }

    /// 提取报点落点：关键词之后紧跟的时间戳。无关键词或时间戳不合法定回 nil。
    ///
    /// 单独调用时自己扫一遍；`detect` 内部复用同一次扫描（见 `jumpTarget(in:scan:)`）——
    /// 那里 19 个关键词共用一遍字节扫描，不必为 5 个报点词再扫一次。
    static func jumpTarget(in text: String) -> Double? {
        jumpTarget(in: text, scan: scanKeywords(in: text))
    }

    /// 用已经算好的扫描结果提取落点。
    ///
    /// **关键词的遍历顺序必须是 `jumpKeywords` 的数组顺序**（不是文本里的先后）：
    /// 旧实现就是按数组顺序找「第一个后跟合法时间戳的词」，换顺序会改变结果。
    private static func jumpTarget(in text: String, scan: KeywordScan) -> Double? {
        for (index, _) in jumpKeywords.enumerated() {
            guard let keywordEnd = scan.jumpMatchEnds[index] else { continue }
            let windowEnd = text.index(
                keywordEnd,
                offsetBy: targetScanWindow,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            if let seconds = parseTimestamp(String(text[keywordEnd..<windowEnd])) {
                return seconds
            }
        }
        return nil
    }

    /// 解析 `MM:SS` 型时间戳，兼容全角冒号、`2.21` 点分隔、`3:9` 单数字秒、
    /// `1:23:45` 三段。`1.5` 这类小数不可能是时间戳，拒绝（点分隔要求秒必须
    /// 两位，否则「跳伞1.5倍」会被解析成 90s）。
    /// `MM:SS` / `M:SS` / `H:MM:SS` 的时间戳正则。
    ///
    /// ## 必须提成 `static let`（实测 11–30×）
    ///
    /// 原先写成**行内正则字面量** `firstMatch(of: /(\d{1,2})([:.])…/)` ——
    /// 看上去是常量，实际**每次调用都会重新编译一遍正则**。
    /// 实测 `parseTimestamp("3:17")` **82 µs/次**；提成 `static let` 后 **7.4 µs/次**。
    /// （对照：同一个循环里字面量 75 217 ns/call vs static 2 473 ns/call，**30×**。）
    ///
    /// 这个开销在 `detect` 里会被放大：**每条命中报点关键词的弹幕都要调一次**。
    /// 1% 命中率下就是 8.2 ms/万条 —— 比整条关键词扫描（2.6 ms）还贵。
    ///
    /// `nonisolated(unsafe)`：`Regex` 不是 `Sendable`。但这个正则是**只读**的
    /// （`firstMatch` 不改内部状态、线程安全），所以共享是安全的 ——
    /// 这里用 `unsafe` 标注表达「我们确认过它是不可变的」。
    nonisolated(unsafe) private static let timestampPattern =
        /(\d{1,2})([:.])(\d{1,2})(?::(\d{1,2}))?/

    static func parseTimestamp(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "．", with: ".")
        guard let match = normalized.firstMatch(of: Self.timestampPattern) else {
            return nil
        }
        // 前后不能紧贴数字：避免从 "22:17" 里截出 "2:17" 之类的碎片段。
        if match.range.lowerBound > normalized.startIndex {
            let before = normalized[normalized.index(before: match.range.lowerBound)]
            if before.isNumber { return nil }
        }
        if let after = normalized[match.range.upperBound...].first, after.isNumber { return nil }

        let (_, rawMinute, separator, rawSecond, rawHour) = match.output
        let minute = Int(rawMinute) ?? 0
        let second = Int(rawSecond) ?? 0
        guard second < 60, minute < 60 else { return nil }
        if separator == "." && rawSecond.count != 2 { return nil }
        let hour = rawHour.flatMap { Int($0) } ?? 0
        return Double(hour * 3_600 + minute * 60 + second)
    }


    // MARK: 聚合

    /// 把数值按间距聚成簇（排序后相邻差 ≤ gap 归同簇），返回最大的簇。
    private static func largestCluster(
        of values: [Double], gap: Double
    ) -> (values: [Double], distinctCount: Int, count: Int)? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        var clusters: [[Double]] = [[sorted[0]]]
        for value in sorted.dropFirst() {
            if value - (clusters[clusters.count - 1].last ?? value) <= gap {
                clusters[clusters.count - 1].append(value)
            } else {
                clusters.append([value])
            }
        }
        // 并列时取最早的簇：靠前的簇更可能是片头落点。
        var best = clusters[0]
        for cluster in clusters.dropFirst() where cluster.count > best.count {
            best = cluster
        }
        return (best, Set(best.map(rounded)).count, best.count)
    }

    private static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    private static func roundedMedian(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
        return median.rounded()
    }
}

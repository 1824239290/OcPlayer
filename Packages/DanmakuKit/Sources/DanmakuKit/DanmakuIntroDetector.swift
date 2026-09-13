import Foundation

/// 弹幕推导的片头提示（「跳过片头」的数据源）。
///
/// `endSeconds` 是正片开始时刻（片头结束点）；`startSeconds` 是估计的片头起点，
/// 有冷开场/前情回顾的集会明显大于 0，无把握时为 nil（消费侧回落到 0）。
/// `evidenceCount` 是支撑证据条数（报点 + 着陆确认），用于日志与置信展示。
public struct DanmakuIntroHint: Codable, Sendable, Equatable {
    public let startSeconds: Double?
    public let endSeconds: Double
    public let evidenceCount: Int

    public init(startSeconds: Double?, endSeconds: Double, evidenceCount: Int) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.evidenceCount = evidenceCount
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
    /// 主簇需要的最少报点目标数（不同的目标值）。
    static let minDistinctTargets = 2
    /// 有交叉确认时主簇所需的最少目标数（确认背书可放宽到 2 个目标值）。
    static let minDistinctTargetsWithConfirmation = 2
    /// 无交叉确认时主簇所需的最少目标数（纯报点自证需要更多样本）。
    static let minDistinctTargetsWithoutConfirmation = 3
    /// 片头起点估计允许的最大片头长度（对齐章节启发式的 240s 上限）。
    static let maxIntroLength: Double = 240
    /// 起点估计有意义的最小片头长度：更短的窗口说明观众看完了大半片头才报点，
    /// 起点没有信息量，回 nil（消费侧回落到 0，按钮窗口反而更完整）。
    static let minIntroLengthForStartEstimate: Double = 20
    /// 仅靠着陆确认判定时需要的最少确认条数（须聚在同一落点附近）。
    static let minLandingOnlyConfirmations = 3
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
        var targets: [(postTime: Double, target: Double)] = []
        var landingTimes: [Double] = []
        var startTimes: [Double] = []

        for comment in comments {
            let time = commentTime(comment.p)
            let text = comment.m
            if let time, let target = jumpTarget(in: text) {
                targets.append((time, target))
            }
            if let time {
                if containsAny(text, landingKeywords) { landingTimes.append(time) }
                if containsAny(text, startKeywords) { startTimes.append(time) }
            }
        }

        if let hint = hint(fromTargets: targets, confirmations: landingTimes + startTimes) {
            return hint
        }
        return landingOnlyHint(landingTimes)
    }

    // MARK: 报点主簇 → 片头结束点

    private static func hint(
        fromTargets targets: [(postTime: Double, target: Double)],
        confirmations: [Double]
    ) -> DanmakuIntroHint? {
        let inRange = targets.filter { targetRange.contains($0.target) }
        guard let cluster = largestCluster(of: inRange.map(\.target), gap: clusterGap),
              cluster.distinctCount >= minDistinctTargets
        else { return nil }

        let end = roundedMedian(cluster.values)
        let nearConfirmations = confirmations.filter {
            targetRange.upperBound + 60 >= $0 && abs($0 - end) <= confirmationTolerance
        }
        let confirmed = !nearConfirmations.isEmpty
        let required = confirmed
            ? minDistinctTargetsWithConfirmation
            : minDistinctTargetsWithoutConfirmation
        guard cluster.distinctCount >= required else { return nil }

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
        of targets: [(postTime: Double, target: Double)],
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
    private static func landingOnlyHint(_ landingTimes: [Double]) -> DanmakuIntroHint? {
        let candidates = landingTimes.filter { $0 <= targetRange.upperBound + 60 }
        guard let cluster = largestCluster(of: candidates, gap: clusterGap),
              cluster.count >= minLandingOnlyConfirmations
        else { return nil }
        let end = roundedMedian(cluster.values)
        guard targetRange.contains(end) else { return nil }
        return DanmakuIntroHint(startSeconds: nil, endSeconds: end, evidenceCount: cluster.count)
    }

    // MARK: 文本解析

    /// `p` 格式为 `时间,模式,颜色,用户`，首段是秒。
    private static func commentTime(_ p: String) -> Double? {
        guard let raw = p.split(separator: ",").first,
              let time = Double(raw), time.isFinite, time >= 0
        else { return nil }
        return time
    }

    /// 提取报点落点：关键词之后紧跟的时间戳。无关键词或时间戳不合法定回 nil。
    static func jumpTarget(in text: String) -> Double? {
        for keyword in jumpKeywords {
            guard let range = text.range(of: keyword) else { continue }
            let windowEnd = text.index(
                range.upperBound,
                offsetBy: targetScanWindow,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            if let seconds = parseTimestamp(String(text[range.upperBound..<windowEnd])) {
                return seconds
            }
        }
        return nil
    }

    /// 解析 `MM:SS` 型时间戳，兼容全角冒号、`2.21` 点分隔、`3:9` 单数字秒、
    /// `1:23:45` 三段。`1.5` 这类小数不可能是时间戳，拒绝（点分隔要求秒必须
    /// 两位，否则「跳伞1.5倍」会被解析成 90s）。
    static func parseTimestamp(_ text: String) -> Double? {
        let normalized = text
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "．", with: ".")
        guard let match = normalized.firstMatch(of: /(\d{1,2})([:.])(\d{1,2})(?::(\d{1,2}))?/) else {
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

    private static func containsAny(_ text: String, _ keywords: [String]) -> Bool {
        keywords.contains { text.contains($0) }
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

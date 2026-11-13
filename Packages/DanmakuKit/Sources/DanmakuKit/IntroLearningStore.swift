import DiagnosticsKit
import Foundation
import OcPlayerCore

/// 一条手动跳过学习事件（用户主动前跳的落点）。
public struct IntroSeekEvent: Codable, Sendable, Equatable {
    public let episodeID: Int64
    public let position: Double
    public let at: Date

    public init(episodeID: Int64, position: Double, at: Date) {
        self.episodeID = episodeID
        self.position = position
        self.at = at
    }
}

/// 手动跳过学习的全部判定参数（**单源**）。
///
/// 「什么算一次有效落点」此前一半写在 App 层（`DanmakuCoordinator.handleUserSeek`
/// 的过滤窗/最小前跳/确认容差）、一半写在本包（聚簇容差/合理性窗），±10s 的
/// 「同一落点」容差两侧各写一份——它们是同一物理意义，必须同调，所以全部收在这里。
public enum IntroLearningPolicy {
    /// 落点过滤窗：片头结束点的合理区间（秒）。
    public static let landingWindow: ClosedRange<Double> = 30...360
    /// 触发学习的最小前跳秒数（太小的拖动不是「跳过片头」）。
    public static let minimumSeekSeconds: Double = 5
    /// 「同一落点」容差（秒）：确认升级（落点贴合既有提示）与跨集聚簇共用。
    public static let snapToleranceSeconds: Double = 10
    /// 跨集共识要求的最少**不同集**数（同人同集反复跳不算跨集证据）。
    public static let minimumConsensusEpisodes = 2
    /// 每番学习事件上限（最新优先），防长跑库无限膨胀。
    public static let maxEventsPerAnime = 200

    /// Keeps the playback boundary and shared consensus on the same policy.
    public static func eligibleSeek(from: Double, to: Double) -> Bool {
        guard to.isFinite, !from.isNaN, from != .infinity else { return false }
        if let rust = RustDanmakuPolicy.active {
            return rust.intro("eligibleSeek", arguments: [
                "from": from == -.infinity ? -Double.greatestFiniteMagnitude : from, "to": to,
            ])
        }
        return landingWindow.contains(to) && from < to - minimumSeekSeconds
    }

    public static func confirmedHint(forLanding to: Double, current: DanmakuIntroHint?) -> DanmakuIntroHint? {
        guard to.isFinite, let current, current.endSeconds.isFinite else { return nil }
        if let rust = RustDanmakuPolicy.active {
            guard let data = try? JSONEncoder().encode(current) else { return nil }
            return rust.intro("confirmedHint", arguments: [
                "to": to, "payloadJSON": String(decoding: data, as: UTF8.self),
            ])
        }
        guard current.source == .danmaku,
              abs(to - current.endSeconds) <= snapToleranceSeconds else { return nil }
        return DanmakuIntroHint(startSeconds: current.startSeconds, endSeconds: current.endSeconds,
            evidenceCount: current.evidenceCount + 1, source: .learned)
    }
}

/// 手动跳过学习存储（`learned-intros.json`，anime 级，永久；已列入
/// `DanmakuCache.permanentFileNames` 白名单，不会被缓存清理删掉）。
///
/// 学习信号 = 用户在播放中**主动前跳**且落点落在片头结束区间（范围过滤在 App
/// 层按 `IntroLearningPolicy` 做完才喂进来）。两条晋升路径：
/// 1. **确认升级**：落点与该集既有提示 end ±`snapToleranceSeconds` → 用户背书了
///    猜测，该提示升级为 `.learned`（防后续低优先级来源覆盖）——判定在 App 层做
///    （它持有当前提示）；
/// 2. **跨集晋升**：≥`minimumConsensusEpisodes` 个不同集的落点聚簇 → 同季 OP 恒定，
///    中位数推广到全番。变量 OP 的番（各集冷开场/前情不同）落点自然离散，
///    聚不起来不会误套。
public actor IntroLearningStore {
    private struct AnimeLearning: Codable, Sendable {
        var events: [IntroSeekEvent] = []
        var promoted: DanmakuIntroHint?
    }

    private let directory: URL
    private let rust: RustIntroLearningStore?
    var usesCoreLearning: Bool { rust != nil }
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var cached: [String: AnimeLearning]?
    private var loaded = false

    public init(directory: URL, fileManager: FileManager = .default, useCore: Bool? = nil) {
        self.directory = directory
        self.fileManager = fileManager
        if (useCore ?? OcpCoreFeature.isEnabled) && fileManager === FileManager.default {
            rust = try? RustIntroLearningStore(directory: directory)
        } else {
            rust = nil
        }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 记录一次用户跳过落点。
    public func record(animeID: Int64, event: IntroSeekEvent) {
        if let rust {
            rust.write("record", animeID: animeID, value: event)
            return
        }
        var learning = load()[String(animeID)] ?? AnimeLearning()
        learning.events.append(event)
        // 事件有界:最新优先截断（上限见 IntroLearningPolicy）。
        if learning.events.count > IntroLearningPolicy.maxEventsPerAnime {
            learning.events = Array(learning.events.suffix(IntroLearningPolicy.maxEventsPerAnime))
        }
        setLearning(learning, for: animeID)
    }

    /// 已晋升的 anime 级提示（无则 nil）。
    public func promotedHint(forAnime animeID: Int64) -> DanmakuIntroHint? {
        if let rust { return try? rust.call("promotedHint", animeID: animeID, as: DanmakuIntroHint?.self) }
        return load()[String(animeID)]?.promoted
    }

    /// 跨集共识判定（基于已记录事件,不落盘）。返回待晋升提示;无共识返回 nil。
    /// App 层据此决定是否 `promote`。
    public func consensusHint(forAnime animeID: Int64) -> DanmakuIntroHint? {
        if let rust { return try? rust.call("consensusHint", animeID: animeID, as: DanmakuIntroHint?.self) }
        guard let consensus = Self.crossEpisodeConsensus(of: learning(for: animeID).events)
        else { return nil }
        return DanmakuIntroHint(
            startSeconds: nil,
            endSeconds: consensus.end,
            evidenceCount: consensus.episodeCount,
            source: .learned
        )
    }

    /// 记下晋升结果。
    public func promote(animeID: Int64, hint: DanmakuIntroHint) {
        if let rust {
            rust.write("promote", animeID: animeID, value: hint)
            return
        }
        var learning = load()[String(animeID)] ?? AnimeLearning()
        learning.promoted = hint
        setLearning(learning, for: animeID)
    }

    /// 纯函数：学习事件流里是否存在跨集共识落点。
    ///
    /// 要求 ≥`minimumEpisodes` 个**不同集**的落点聚在同一 ±10s 簇内（同人同集
    /// 反复跳不算跨集证据），返回簇内位置中位数与集数。无共识返回 nil。
    public static func crossEpisodeConsensus(
        of events: [IntroSeekEvent],
        minimumEpisodes: Int = IntroLearningPolicy.minimumConsensusEpisodes
    ) -> (end: Double, episodeCount: Int)? {
        if let rust = RustDanmakuPolicy.active {
            guard let value = rust.consensus(events, minimum: minimumEpisodes) else { return nil }
            return (value.end, value.episodeCount)
        }
        return crossEpisodeConsensusNative(of: events, minimumEpisodes: minimumEpisodes)
    }

    static func crossEpisodeConsensusNative(
        of events: [IntroSeekEvent], minimumEpisodes: Int = IntroLearningPolicy.minimumConsensusEpisodes
    ) -> (end: Double, episodeCount: Int)? {
        let sorted = events.sorted { $0.position < $1.position }
        guard !sorted.isEmpty else { return nil }
        var clusters: [[IntroSeekEvent]] = [[sorted[0]]]
        for event in sorted.dropFirst() {
            if event.position - (clusters[clusters.count - 1].last?.position ?? event.position) <= IntroLearningPolicy.snapToleranceSeconds {
                clusters[clusters.count - 1].append(event)
            } else {
                clusters.append([event])
            }
        }
        // 簇按「不同集数」取最大;并列取事件多者。
        let best = clusters.max { a, b in
            let episodesA = Set(a.map(\.episodeID)).count
            let episodesB = Set(b.map(\.episodeID)).count
            return episodesA != episodesB
                ? episodesA < episodesB
                : a.count < b.count
        }
        guard let best,
              Set(best.map(\.episodeID)).count >= minimumEpisodes
        else { return nil }
        let end = median(best.map(\.position))
        // 落点合理性:与学习窗口同源（片头结束点不会在窗外）。
        guard IntroLearningPolicy.landingWindow.contains(end) else { return nil }
        return (end, Set(best.map(\.episodeID)).count)
    }

    // MARK: 内部

    private func learning(for animeID: Int64) -> AnimeLearning {
        load()[String(animeID)] ?? AnimeLearning()
    }

    private func setLearning(_ learning: AnimeLearning, for animeID: Int64) {
        var map = load()
        map[String(animeID)] = learning
        guard let data = try? encoder.encode(map) else { return }
        try? data.write(to: url(), options: .atomic)
        cached = map
        loaded = true
    }

    private func load() -> [String: AnimeLearning] {
        if loaded, let cached { return cached }
        let fileURL = url()
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let map = try? decoder.decode([String: AnimeLearning].self, from: data)
        else {
            // 文件缺失/损坏按空定下来并置 loaded(与 aniskip-ids.json 同策略:
            // 学习数据可重建,代价只是重新学)。
            cached = [:]
            loaded = true
            return [:]
        }
        cached = map
        loaded = true
        return map
    }

    private func url() -> URL {
        directory.appendingPathComponent("learned-intros.json")
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

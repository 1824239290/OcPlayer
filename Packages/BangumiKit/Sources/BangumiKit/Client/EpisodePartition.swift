import Foundation

/// 章节列表的三个分类（详情页分段控件）。
///
/// 在包里而不是视图里：`EpisodePartition.episodes(for:)` 的映射关系要能被单测守住 ——
/// 视图内部的枚举测不到，而「把 main 接成 sp」这类错在视图里**编译器不会报**
/// （两边都是 `[BangumiEpisodeDTO]`）。
public enum EpisodeTab: String, CaseIterable, Identifiable, Sendable {
    case main = "本篇"
    case sp = "SP"
    case other = "其他"

    public var id: String { rawValue }

    /// 分段控件上显示的标题（带计数）。
    public func title(count: Int) -> String {
        "\(rawValue) (\(count))"
    }
}

/// 一次分区后的三个章节列表。
///
/// ## 为什么要它（`P2-09`）
///
/// 详情页原先有三个独立 computed property，各含一次 `episodes.filter`：
/// ```swift
/// private var mainEpisodes  { episodes.filter { $0.type == .main } }
/// private var spEpisodes    { episodes.filter { $0.type == .sp } }
/// private var otherEpisodes { episodes.filter { $0.type != .main && $0.type != .sp } }
/// ```
/// 而 `episodesSection` 一次 body 里把它们读了 **3–7 次**（取决于 sp / other 是否为空：
/// 外层 OR 短路决定 1–2 次，Picker 里 0–5 次，`currentList` 的 switch 1 次）——
/// 1000 集时一次 body 要扫 3000–7000 个元素、建同样多份临时数组，
/// 而 `body` 会因 `updatingEpisodeID` / `isLoading` 变化反复重算。
///
/// ## 为什么 `episodes(for:)` 也在包里
///
/// 视图只需要 `parts.episodes(for: selectedEpisodeTab)`。把「tab → 数组」这层映射
/// 放在包里，用例就能断言 `tab == .sp` 拿到的确实是 SP 列表 —— 否则视图把
/// `main` / `sp` 接错，包用例全绿、编译器也不报（两边同类型），
/// 只有用户会发现「点 SP 显示的是本篇」。
public struct EpisodePartition: Sendable, Equatable {
    public let main: [BangumiEpisodeDTO]
    public let sp: [BangumiEpisodeDTO]
    public let other: [BangumiEpisodeDTO]

    public init(
        main: [BangumiEpisodeDTO] = [],
        sp: [BangumiEpisodeDTO] = [],
        other: [BangumiEpisodeDTO] = []
    ) {
        self.main = main
        self.sp = sp
        self.other = other
    }

    /// 按 tab 取对应列表（视图用这一条，映射被用例守住）。
    public func episodes(for tab: EpisodeTab) -> [BangumiEpisodeDTO] {
        switch tab {
        case .main: main
        case .sp: sp
        case .other: other
        }
    }

    /// 某个 tab 的条目数（Picker 标题用）。
    public func count(for tab: EpisodeTab) -> Int {
        switch tab {
        case .main: main.count
        case .sp: sp.count
        case .other: other.count
        }
    }

    /// 该 tab 是否为空。
    public func isEmpty(for tab: EpisodeTab) -> Bool {
        switch tab {
        case .main: main.isEmpty
        case .sp: sp.isEmpty
        case .other: other.isEmpty
        }
    }

    /// 三个列表加总（应当等于原数组长度；用例拿它守「不漏条目」）。
    public var totalCount: Int { main.count + sp.count + other.count }

    /// 一个分区在 UI 上的**完整描述**：该显示哪几组、每组什么标题、组内是什么。
    ///
    /// ## 为什么要有它（而不是让视图自己拼）
    ///
    /// 视图原先（`P2-10` 之前）是三个 computed property，改完后虽然只分区一次，
    /// 但仍然要在视图里手写三段 `if !parts.isEmpty(for: .x) { 标题; grid }` ——
    /// **把 `.main` 写成 `.sp` 编译器不会报**（两边都是 `[BangumiEpisodeDTO]`），
    /// 也没有视图测试能抓。这是「测试没接上生产路径」的同型缺口。
    ///
    /// 现在视图只写：
    /// ```swift
    /// ForEach(parts.displayGroups) { group in
    ///     if let title = group.title { Text(title)… }
    ///     episodeGrid(group.episodes)
    /// }
    /// ```
    /// 而「哪三组、按什么顺序、每组标题是什么」由这里决定，**可以被单测断言**。
    ///
    /// ## 顺序与标题（必须与旧实现一致）
    ///
    /// 旧实现固定顺序：本篇（无标题）→ SP（标题 "SP"）→ 其他（标题 "其他"）。
    /// 空组**不出现**（三处 `if !xxx.isEmpty`）。这里用 `title == nil` 表示「无标题」。
    public var displayGroups: [DisplayGroup] {
        var groups: [DisplayGroup] = []
        if !main.isEmpty { groups.append(DisplayGroup(tab: .main, title: nil, episodes: main)) }
        if !sp.isEmpty { groups.append(DisplayGroup(tab: .sp, title: "SP", episodes: sp)) }
        if !other.isEmpty {
            groups.append(DisplayGroup(tab: .other, title: "其他", episodes: other))
        }
        return groups
    }

    /// UI 上的一组：哪个 tab、要不要标题、组内条目。
    public struct DisplayGroup: Identifiable, Equatable, Sendable {
        public let tab: EpisodeTab
        /// nil = 不显示分组标题（本篇就是这种）。
        public let title: String?
        public let episodes: [BangumiEpisodeDTO]

        public var id: EpisodeTab { tab }
    }
}

extension Array where Element == BangumiEpisodeDTO {
    /// 按「本篇 / SP / 其他」三分，**一次扫完**。
    ///
    /// ## 分流规则（必须与旧实现逐条等价）
    ///
    /// `BangumiEpisodeType` 有 7 个 case：`main` / `sp` / `op` / `ed` / `trailer` / `mad` / `other`。
    /// 旧的第三条是 `type != .main && type != .sp` —— 也就是
    /// **`op` / `ed` / `trailer` / `mad` / `other` 全部归「其他」**。
    /// 新实现用 `switch` 的 `default` 承接它们，等价。
    ///
    /// 分类内部保持原数组顺序。
    public func partitionedByEpisodeType() -> EpisodePartition {
        var main: [BangumiEpisodeDTO] = []
        var sp: [BangumiEpisodeDTO] = []
        var other: [BangumiEpisodeDTO] = []
        for episode in self {
            switch episode.type {
            case .main: main.append(episode)
            case .sp: sp.append(episode)
            default: other.append(episode)
            }
        }
        return EpisodePartition(main: main, sp: sp, other: other)
    }
}

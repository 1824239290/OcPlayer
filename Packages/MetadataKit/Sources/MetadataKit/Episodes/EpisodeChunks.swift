import CoreModel
import Foundation

// MARK: - 每三十集一个分区

/// 选集轨道里的一段：详情页把一条长轨道按固定条数切开，一次只渲染一段。
///
/// ## 为什么要有这一层
///
/// 一季上千集时，单条横向轨道要滑几百张卡才能找到目标集——用户口径是
/// 「每三十集一个小分区，方便多集的番剧不用翻得很麻烦」。切开后轨道最多 30 格，
/// 段与段之间用一行胶囊直选；进入页面时自动停在选中集所在的那一段。
///
/// **纯展示分段**：不改轨道顺序、不改选中态、更不改可播集合——它只回答
/// 「这一段的格子从哪到哪、标签写什么」。放在 `MetadataKit` 而不是 App 层，
/// 与 `EpisodeSlotBuilder` 同一条理由：策略是纯的，就该能脱离 SwiftUI 单测。
public struct EpisodeChunk: Sendable, Hashable, Identifiable {
    /// 段序号（0 起）。按**升序**轨道切分；详情页的倒序只反转段序与段内顺序，
    /// 段号本身不动——所以「第 3 段」在两种排序下都是同一批集。
    public let index: Int
    /// 本段的选集轨道（保持输入顺序，段内不排序）。
    public let slots: [EpisodeSlot]
    /// 本段首 / 末集的集号。段内一个编号都没有（服务端没给 `IndexNumber` 的本地条目）
    /// 时，退回**本段在整条轨道里的位置号**（1 起），标签仍可读。
    public let firstNumber: Int
    public let lastNumber: Int

    public var id: Int { index }

    /// 分区胶囊上的文案：「1-30」「1001-1030」；只剩一集的尾段只写一个号「61」。
    public var rangeLabel: String {
        firstNumber == lastNumber ? "\(firstNumber)" : "\(firstNumber)-\(lastNumber)"
    }

    /// VoiceOver 文案。库内跳号时区间里并不是每一集都存在，但这里说的是
    /// **段的范围**，不是「这段里每一集都在库里」的承诺。
    public var accessibilityLabel: String {
        firstNumber == lastNumber ? "第 \(firstNumber) 集" : "第 \(firstNumber) 到 \(lastNumber) 集"
    }
}

/// 把一条选集轨道切成固定条数的分区。
public enum EpisodeChunker {
    /// 每个分区的默认集数（用户点名的数字：每三十集一个小分区）。
    public static let defaultSize = 30

    /// 顺序切分：保序、不丢格——`chunk(slots).flatMap(\.slots)` 与 `slots` 逐位相等。
    ///
    /// - Parameter size: 每段的条数。`size <= 0` 或空轨道返回 `[]`：调用方不该拿到
    ///   「空段」这种东西（空段会让分区条上多出一颗点不动的胶囊）。
    public static func chunk(_ slots: [EpisodeSlot], size: Int = defaultSize) -> [EpisodeChunk] {
        guard size > 0, !slots.isEmpty else { return [] }
        return stride(from: 0, to: slots.count, by: size).map { start in
            let end = min(start + size, slots.count)
            let segment = Array(slots[start..<end])
            let numbers = segment.compactMap(\.episodeNumber)
            return EpisodeChunk(
                index: start / size,
                slots: segment,
                // 取段内**实际存在的**集号区间的两端。用 min/max 而不是 first/last：
                // 输入理论上按集号升序（`EpisodeSlotBuilder` 就是那么排的），但真被
                // 乱序喂进来时，「首格 60、末格 31」这种倒挂标签会直接写在胶囊上。
                // 段内一个集号都没有时才退回轨道位置号（无编号的本地条目排在末尾）。
                firstNumber: numbers.min() ?? (start + 1),
                lastNumber: numbers.max() ?? end
            )
        }
    }
}

private extension EpisodeSlot {
    /// 本格代表的集号。本地条目可能没有 `IndexNumber`（服务端返回 nil），占位恒有。
    var episodeNumber: Int? {
        switch self {
        case .local(let item): item.episodeNumber
        case .placeholder(let placeholder): placeholder.number
        }
    }
}

// MARK: - 分区浏览状态

/// 选集轨道在「分区」维度上的浏览状态：展示哪些分区、当前在哪一段、这一段渲染哪些格。
///
/// 三件事都是纯值计算，收在这里是为了能脱离 SwiftUI 单测——视图侧只剩接线和一个
/// `@State` 字段。它不改选中集、不改轨道数据：分区只是浏览维度。
public struct EpisodeChunkNavigation: Sendable, Equatable {
    /// 用户手动点过的分区号（`EpisodeChunk.index`）。nil = 跟随选中集。
    public var browsedIndex: Int?

    public init(browsedIndex: Int? = nil) {
        self.browsedIndex = browsedIndex
    }

    /// 选中集变化 / 换季之后回到「跟随选中集」。
    ///
    /// 段内点卡也会调它：新选中集就在当前段里，调用前后 `activeIndex` 同值，
    /// 等于无操作——这一步只负责把「手动浏览」的状态清掉，别让旧意图压住新选中。
    public mutating func followSelection() {
        browsedIndex = nil
    }

    /// 分区条的展示顺序：倒序时段序整体反（段内顺序由 `railSlots` 负责）。
    public func displayedChunks(_ chunks: [EpisodeChunk], ascending: Bool) -> [EpisodeChunk] {
        ascending ? chunks : Array(chunks.reversed())
    }

    /// 当前分区号。优先级：用户手点（且仍在范围内）→ 选中集所在分区 →
    /// 第一个**展示出来的**分区（倒序即最后一段）。
    ///
    /// 找选中集是逐段的早退扫描（最坏扫满一季，千集 ≈ 一千次字符串比较，一次 body
    /// 求值一次）。刻意不为它再维护一张「集 id → 段号」的表：那是又一份要跟着
    /// `episodeChunks` 同步的派生状态，而这里的量级远小于改动前每次 body 都做的
    /// 整条轨道拷贝（现在只拷贝当前段的 ≤30 格）。
    public func activeIndex(
        in chunks: [EpisodeChunk],
        selectedEpisodeID: MediaItem.ID?,
        ascending: Bool
    ) -> Int {
        guard !chunks.isEmpty else { return 0 }
        if let browsedIndex, chunks.indices.contains(browsedIndex) { return browsedIndex }
        if let selectedEpisodeID,
           let chunk = chunks.first(where: { $0.slots.contains { $0.id == selectedEpisodeID } }) {
            return chunk.index
        }
        return ascending ? 0 : chunks.count - 1
    }

    /// 当前分区要渲染的格子（倒序时段内反转）。
    ///
    /// 越界（换季那一帧 `episodeChunks` 还没跟上）返回空数组：视图的轨道 `.id`
    /// 下次数据到位会当成新轨道重建，比拿旧下标硬切安全。
    public func railSlots(in chunks: [EpisodeChunk], activeIndex: Int, ascending: Bool) -> [EpisodeSlot] {
        guard chunks.indices.contains(activeIndex) else { return [] }
        let slots = chunks[activeIndex].slots
        return ascending ? slots : Array(slots.reversed())
    }
}

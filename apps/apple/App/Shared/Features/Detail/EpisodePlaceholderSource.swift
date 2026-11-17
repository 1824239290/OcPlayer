import BangumiKit
import Foundation
import MetadataKit

/// 把各来源的「整季」数据映射成中立的占位候选。
///
/// 判断策略（该不该补、补到哪、算未播出还是未入库）全在 `MetadataKit.EpisodeSlotBuilder`
/// 里，这里只做**形状转换**：字段改名、单位换算、把明显对不上的编号丢掉。放 App 层是因为
/// `MetadataKit` 不该依赖 `BangumiKit`（依赖方向）。
enum EpisodePlaceholderSource {

    /// Bangumi 章节 → 占位候选。
    ///
    /// 三处过滤都是必须的：
    /// - **只要本篇**（`.main`）：SP / 其他类型的编号与 Jellyfin 的分集号不同源。
    /// - **`sort` 必须是整数**：Bangumi 用小数编号表示特别篇（如 8.5），那不是集号。
    /// - **`sort ≥ 1`**：0 / 负数不是有效的集号。
    ///
    /// `sort` 是 `Float`，所以整数判定用 `sort == sort.rounded()`，并且要挡在 `Int` 转换
    /// 之前（`Int(Float.nan)` 会直接崩）。
    static func bangumiCandidates(from episodes: [BangumiEpisodeDTO]) -> [EpisodeCandidate] {
        episodes.compactMap { episode in
            guard episode.type == .main else { return nil }
            let sort = episode.sort
            guard sort.isFinite, sort >= 1, sort == sort.rounded(), sort <= 100_000 else { return nil }
            let nameCN = episode.nameCN.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = episode.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return EpisodeCandidate(
                number: Int(sort),
                title: nameCN.isEmpty ? name : nameCN,
                overview: episode.desc,
                // Bangumi 没有剧照；`duration` 是「24m」这种字符串，不做解析。
                stillPath: nil,
                airDate: episode.airDateValue,
                runtimeSeconds: nil)
        }
    }
}

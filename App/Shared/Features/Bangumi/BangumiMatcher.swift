import BangumiKit
import CoreModel
import Foundation

/// Jellyfin 条目 ↔ Bangumi 条目的关联匹配。
///
/// 匹配策略：先查本地持久化的关联映射；没有则按「名称」搜索 Bangumi
/// （接口按 match 排序返回），规范化名称精确匹配优先，否则取第一条。
/// 匹配结果写回 BangumiStore，下次直接命中缓存。
@MainActor
enum BangumiMatcher {

    /// 取某个 Jellyfin 条目关联的 Bangumi subject（nil = 未关联）。
    static func linkedSubjectID(forJellyfinItemID itemID: MediaItem.ID) -> Int? {
        BangumiStore().bangumiSubjectID(forJellyfinItemID: itemID)
    }

    static func setLinkedSubjectID(_ subjectID: Int?, forJellyfinItemID itemID: MediaItem.ID) {
        BangumiStore().setBangumiSubjectID(subjectID, forJellyfinItemID: itemID)
    }

    /// 自动匹配：返回命中的 subject（未命中 nil）。命中即持久化关联。
    static func autoMatch(for item: MediaItem) async throws -> BangumiSlimSubjectDTO? {
        // 剧集挂在所属剧集（series）上，电影/剧集本体挂自己。
        let matchName = item.seriesName ?? item.name
        guard let result = try await searchAndPick(name: matchName) else { return nil }
        let linkItemID = item.seriesID ?? item.id
        setLinkedSubjectID(result.id, forJellyfinItemID: linkItemID)
        return result
    }

    /// 手动搜索（关联选择器用）。
    static func search(_ keyword: String) async throws -> [BangumiSlimSubjectDTO] {
        let page = try await BangumiSubjectService.search(keyword: keyword, limit: 30, offset: 0)
        return page.data
    }

    // MARK: - 私有

    private static func searchAndPick(name: String) async throws -> BangumiSlimSubjectDTO? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let page = try await BangumiSubjectService.search(keyword: trimmed, limit: 30, offset: 0)
        let candidates = page.data
        guard !candidates.isEmpty else { return nil }

        // 1) 规范化名称完全一致
        let target = normalized(trimmed)
        if let exact = candidates.first(where: {
            normalized($0.nameCN) == target || normalized($0.name) == target
        }) {
            return exact
        }

        // 2) 名称包含匹配
        if let contained = candidates.first(where: { containsMatch($0, target) }) {
            return contained
        }

        // 3) 兜底：接口按 match 排序，取第一条
        return candidates.first
    }

    private static func normalized(_ value: String) -> String {
        var result = value.lowercased()
        result = result.replacingOccurrences(of: "\u{3000}", with: " ")
        result = result.replacingOccurrences(of: " ", with: "")
        result = result.replacingOccurrences(of: "·", with: "")
        return result
    }

    private static func containsMatch(_ subject: BangumiSlimSubjectDTO, _ target: String) -> Bool {
        let cn = normalized(subject.nameCN)
        let en = normalized(subject.name)
        if !cn.isEmpty, cn.contains(target) || target.contains(cn) { return true }
        if !en.isEmpty, en.contains(target) || target.contains(en) { return true }
        return false
    }
}

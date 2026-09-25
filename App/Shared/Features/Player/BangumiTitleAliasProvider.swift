import BangumiKit
import DanmakuKit
import DiagnosticsKit
import Foundation

/// 用 Bangumi 把番剧标题换成中文名，供弹幕匹配使用。
///
/// 为什么需要：弹弹play 库里的 `animeTitle` 固定是简体中文，且日文名召回不稳
/// （实测 `負けヒロインが多すぎる` 在弹弹play 搜不到正确作品，而 Bangumi 给出
/// `name_cn`「败犬女主太多了！」后中文搜索命中第一）。
///
/// 只取 Bangumi 搜索**第一条**结果的名称：Bangumi 按匹配度排序，后面的条目
/// 常是同名无关作品（实测搜 `Sousou no Frieren` 第 3 条是《古寺闹鬼记》），
/// 拿它们当别名会污染检索词。万一第一条也错了，编排层的降级链会退回本地标题。
struct BangumiTitleAliasProvider: DanmakuTitleAliasProviding {
    /// 搜索实现。默认走 BangumiKit 的匿名搜索；测试注入假实现（离线）。
    let search: @Sendable (String) async throws -> [BangumiSlimSubjectDTO]

    init() {
        self.search = { keyword in
            try await BangumiSubjectService.search(
                keyword: keyword, filter: .anime, limit: 5
            ).data
        }
    }

    init(search: @escaping @Sendable (String) async throws -> [BangumiSlimSubjectDTO]) {
        self.search = search
    }

    func aliases(for title: String) async -> [String] {
        do {
            let subjects = try await search(title)
            guard let subject = subjects.first else { return [] }
            // 中文名优先（弹弹play 的主语言），原名兜底。
            var aliases: [String] = []
            for candidate in [subject.nameCN, subject.name] {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != title, !aliases.contains(trimmed) else { continue }
                aliases.append(trimmed)
            }
            return aliases
        } catch {
            // 别名桥是加分项：查不到就继续用本地标题，不打断匹配。
            NetworkLog.report(
                category: "Danmaku",
                level: .info,
                "标题别名查询失败，继续用本地标题",
                fields: ["error": .string("\(error)")]
            )
            return []
        }
    }
}

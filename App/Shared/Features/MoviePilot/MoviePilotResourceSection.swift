import AppDesignKit
import CoreModel
import SwiftUI

/// 详情页内嵌的 MoviePilot 下载入口（与 BangumiChapterSection 同级同款头）。
///
/// ## 只有一个动作：跳到 MoviePilot 分区的搜索结果页
///
/// 点这张卡 → 把片名交给 `AppModel.pendingMoviePilotQuery` 并 `switchSection(.moviepilot)`，
/// MoviePilot 首页随即按该关键词调 `/media/search`、列出多源候选（截图那一页），
/// 用户**自己挑** TMDB / Douban 条目、点那一条的「查资源」进站点资源搜索。
///
/// 这条链与 Bangumi 详情页那颗「MoviePilot下载」**完全同源**（同一个
/// `pendingMoviePilotQuery` 通道、同一个消费点），也是 MoviePilot 分区里的原生动线。
///
/// ## 为什么不再在详情页里自己搜、自己拼
///
/// 资源搜索页下载时把 `MPMediaInfo.raw` **原样**回传成 `/download/` 的 `media_in`，
/// MoviePilot 服务端靠里面的 `media_source` / `media_id` / `tmdb_id` 去刮削、改名、
/// 入库。详情页曾经有两条近道——①带 `tmdbID` 时**本地拼**一个 `MPMediaInfo`
/// （海报 / 简介 / 评分全缺）；②没有 `tmdbID` 时按标题搜一次后
/// `first { 年份吻合 } ?? first` **自动挑第一个**（多源聚合里挑到 Douban 条目时
/// 对象里没有 `tmdb_id`）。两条都会让下载后的自动刮削缺编号。
///
/// 现在详情页**不产出任何媒体对象**：选中哪一条完全由用户在 MoviePilot 搜索结果页
/// 决定，那儿每一张卡就是服务端返回的完整对象。
///
/// - 未登录 MoviePilot 时整块不出现，详情页不弹引导。
struct MoviePilotResourceSection: View {
    @Environment(MoviePilotCoordinator.self) private var moviepilot
    @Environment(AppModel.self) private var app
    @Environment(\.contentLeading) private var contentLeading

    /// 集成开关（设置页「启用 MoviePilot」，默认开）：关闭时详情页不渲染本区块。
    @AppStorage(SettingsKeys.moviepilotEnabled) private var moviepilotEnabled = true

    let item: MediaItem

    /// 交给 MoviePilot 分区的搜索词（`/media/search` 的 `title`）。
    ///
    /// 用条目名而不是原名：MoviePilot 的搜索是多源聚合、对中文名匹配很好，而
    /// 原名列（`originalTitle`）常常是日文假名，反而搜不到条目。
    private var query: String {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return item.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var body: some View {
        if moviepilotEnabled, moviepilot.isAuthenticated, !query.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 26)
                    .padding(.bottom, 12)
                entryCard
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, contentLeading)
        }
    }

    // MARK: - 头

    private var header: some View {
        HStack(spacing: 10) {
            Text("MoviePilot")
                .font(.title3.weight(.bold))
            Spacer()
        }
    }

    // MARK: - 入口卡

    /// 标题 + 一行说明。
    ///
    /// 说明文案**沿用改造前那句**（`搜索站点资源并下载` 卡下方的原文），它讲的是
    /// 用户关心的结果：「按标题搜、可选站点；下载完成后 MoviePilot 自动整理入库，
    /// 稍后出现在媒体库」。
    ///
    /// 2026-10-31 两轮口径：先按「按钮下的那些描述可以去掉」删掉了我新加的两行
    /// 解释（「跳到 MoviePilot 搜「片名」…」「选中的条目会随下载一起回传…」），
    /// 随后用户指出「好像少了什么」——删多了，把**原有这一句**也带走了。现在只留
    /// 原句，我那两句解释不再回来：它们是流程说明，而这一步只需要告诉用户
    /// 「点下去会发生什么、结果落在哪」。
    private var entryCard: some View {
        Button {
            app.pendingMoviePilotQuery = query
            app.switchSection(.moviepilot)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("搜索站点资源并下载")
                        .font(.callout.weight(.medium))
                    Text("按标题搜、可选站点；下载完成后 MoviePilot 自动整理入库，稍后出现在媒体库")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            // 2026-10-22：与下载页同一套液态玻璃（原 `.fill.quaternary` 纯色底）。
            // 详情页整页的内容件（Bangumi 章节区、媒体信息）都是这一套，入口卡跟随。
            .liquidGlassCard()
        }
        .buttonStyle(.plain)
    }
}

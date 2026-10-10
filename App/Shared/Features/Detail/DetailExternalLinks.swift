import BangumiKit
import CoreModel
import MetadataKit
import SwiftUI

/// 详情页头部的一条外部站点链接。
struct ExternalMetadataLink: Identifiable, Equatable {
    /// 稳定 id（同一站点只出现一次）。
    let id: String
    /// 无障碍标签与悬停提示。
    let title: String
    let url: URL
    /// 资源目录里的品牌图标名。
    let assetName: String
    /// 图标显示尺寸（**宽高都给死**）。品牌标记的画幅是固定的，交给
    /// `.frame(height:)` 去推宽度会让排布依赖父级给多少提案；直接钉住宽高，
    /// 行内占位是常量、图标不会随可压缩的兄弟视图变形。
    let size: CGSize
}

/// 外部站点链接的解析。纯函数、不碰网络也不碰 UI，便于直接测。
enum ExternalMetadataLinks {

    /// Bangumi 标记（彩色版）：与单色模板图（`bangumi-logo`）**同一个官方 glyph**，
    /// 只是填了官方 App 图标的渐变（顶部 `#F70098` 洋红 → 底部 `#FF69A3` 品牌粉，
    /// 取自官方 256×256 图标逐行采样）。矢量、带透明通道，任意尺寸都清晰。
    /// 单独一份而不是复用模板图的理由见 `DetailExternalLinksView.body` 的渲染注释。
    private static let bangumiLogoSize = CGSize(width: 15, height: 15)
    /// TMDb 官方字标（`blue_square_1`）：viewBox 190.24×81.52，宽扁两行 TM/DB，
    /// 按原画幅等比。比 Bangumi 高一档是因为它与方形标记只对齐高度会显小 ——
    /// 实测两个官方方形变体里只有这个在图标尺寸仍可辨认，另一个
    /// （`blue_square_2` 的 "THE MOVIE DB" 三行走排）在 12pt 下糊成一团。
    private static let tmdbLogoSize = CGSize(width: 28, height: 12)

    /// TMDb 站点地址。**只在能拼出确定指向时才返回**：
    ///
    /// - 电影 → `/movie/{id}`、剧集 → `/tv/{id}`：条目自身的 ProviderIds 就是该粒度的 id。
    /// - 季 / 分集要拼 `/tv/{id}/season/{n}/episode/{m}`，需要的是**剧集级** id，
    ///   而分集条目 ProviderIds 里的是集级 id（`TheIntroDB` 那边也踩过同一个坑，
    ///   见 `AppModel.seriesTmdbID`）。手上没有剧集级 id 就**不给链接**——
    ///   宁可少一个图标，也不摆一个点进去是别的片子的地址。
    static func tmdbURL(for item: MediaItem) -> URL? {
        tmdbURL(for: item, linkedEntityKey: nil)
    }

    /// 同上，但优先用**已建立的对应**（手动匹配 / 自动匹配的结果）。
    ///
    /// 为什么需要：服务端没有 `ProviderIds["Tmdb"]` 的条目（正是需要手动匹配的那批）
    /// 光看 `item.tmdbID` 拼不出地址，于是「刚手动匹配完、图标还是不出现」——
    /// 用户会以为匹配没生效。
    static func tmdbURL(for item: MediaItem, linkedEntityKey: TMDbEntityKey?) -> URL? {
        if let linkedEntityKey, let url = url(for: linkedEntityKey) { return url }
        guard let id = positiveID(item.tmdbID) else { return nil }
        switch item.kind {
        case .movie: return URL(string: "https://www.themoviedb.org/movie/\(id)")
        case .series: return URL(string: "https://www.themoviedb.org/tv/\(id)")
        default: return nil
        }
    }

    /// TMDb 实体键 → 站点地址。
    static func url(for key: TMDbEntityKey) -> URL? {
        switch key {
        case .movie(let id):
            URL(string: "https://www.themoviedb.org/movie/\(id)")
        case .tv(let id):
            URL(string: "https://www.themoviedb.org/tv/\(id)")
        case .season(let tvID, let number):
            URL(string: "https://www.themoviedb.org/tv/\(tvID)/season/\(number)")
        case .collection(let id):
            URL(string: "https://www.themoviedb.org/collection/\(id)")
        }
    }

    /// Bangumi 条目地址（与 App 内 Bangumi 条目页的「在浏览器中打开」同源）。
    static func bangumiURL(subjectID: Int?) -> URL? {
        guard let subjectID, subjectID > 0 else { return nil }
        return URL(string: "https://bgm.tv/subject/\(subjectID)")
    }

    /// 详情页要展示的链接（Bangumi 在前，与页内区块顺序一致）。
    static func links(
        item: MediaItem,
        bangumiSubjectID: Int?,
        linkedEntityKey: TMDbEntityKey? = nil
    ) -> [ExternalMetadataLink] {
        var links: [ExternalMetadataLink] = []
        if let url = bangumiURL(subjectID: bangumiSubjectID) {
            links.append(ExternalMetadataLink(
                id: "bangumi",
                title: "在 Bangumi 打开",
                url: url,
                assetName: "bangumi-logo-color",
                size: bangumiLogoSize
            ))
        }
        if let url = tmdbURL(for: item, linkedEntityKey: linkedEntityKey) {
            links.append(ExternalMetadataLink(
                id: "tmdb",
                title: "在 TMDB 打开",
                url: url,
                assetName: "tmdb-logo",
                size: tmdbLogoSize
            ))
        }
        return links
    }

    /// ProviderIds 里取出来的是字符串，服务器脏数据（空串 / 非数字 / 0）一律当作没有。
    private static func positiveID(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int(raw), value > 0
        else { return nil }
        return value
    }
}

/// 详情页头部的「去原站看看」图标行：Bangumi / TMDB。
///
/// 自己解析数据面（TMDb 直读条目上的 ProviderIds，Bangumi 读本地关联映射），
/// 不往 `DetailView` 再塞一份状态、也不回调——它在头部两处布局里各出现一次，
/// 谁放它谁不用管数据。
struct DetailExternalLinksView: View {
    let item: MediaItem
    /// 当前选中的季。Bangumi 关联可能挂在季上（链路见 `BangumiMatcher`）。
    var selectedSeason: MediaItem? = nil

    @Environment(\.openURL) private var openURL
    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(AppModel.self) private var app
    /// 集成开关（设置页「启用 Bangumi」，默认开）。停用即整块不出现 —— 与
    /// README 的承诺一致：「不用可在设置里停用，入口会全部隐藏」。
    @AppStorage(SettingsKeys.bangumiEnabled) private var bangumiEnabled = true

    @State private var bangumiSubjectID: Int?
    /// 已建立的 TMDb 对应（手动匹配完图标要立刻跟上）。
    @State private var tmdbLink: TMDbLink?
    @State private var showingMatchSheet = false

    private var links: [ExternalMetadataLink] {
        ExternalMetadataLinks.links(item: item, bangumiSubjectID: bangumiSubjectID,
                                    linkedEntityKey: tmdbLink?.entityKey)
    }

    /// 手动匹配入口：已配置 key 且该条目**有 movie/tv 端点**（季/集靠父剧推导）。
    private var showsMatchButton: Bool {
        app.tmdb.isReady && (item.kind == .movie || item.kind == .series)
    }

    /// 重解触发键：条目 / 季 / 登录态任一变化都要重来一次。
    private var resolveKey: String {
        "\(item.id)|\(item.tmdbID ?? "")|\(item.seriesID ?? "")|\(selectedSeason?.id ?? "")|\(bangumi.isAuthenticated)"
    }

    var body: some View {
        // ⚠️ `.task` 必须挂在**条件之外**的 Group 上：解析结果决定 `links` 有没有内容，
        // 而 `links` 又决定图标行画不画——挂在条件里面的话，「只有 Bangumi 关联、
        // 没有 Tmdb id」的条目首帧 `links` 为空 → 图标行不存在 → task 从未运行 →
        // 永远解析不出来（自锁）。Group 恒在视图树里，空内容不占位，任务照跑。
        Group {
            // 一个链接都没有、也没有匹配入口就什么都不画：空占位会在标题行里留下一段
            // 看不见的间距。
            //
            // 注意条件是「链接空 **且** 没有匹配入口」：服务端既没 Bangumi 关联又没
            // Tmdb id 的条目恰恰是最需要手动匹配的那批，不能因为「没有链接」就把入口
            // 一起藏掉。
            if !links.isEmpty || showsMatchButton {
                HStack(spacing: 10) {
                    ForEach(links) { link in
                        Button {
                            openURL(link.url)
                        } label: {
                            // **原色渲染**：两个图标都是品牌彩色图（Bangumi 官方 glyph +
                            // 官方渐变、TMDb 官方字标），改色等于改品牌标识。顶栏药丸 /
                            // iOS Tab 用的是另一份单色模板图（`bangumi-logo`）——那里
                            // 图标要跟标签文字一起随选中态变亮变暗。
                            Image(link.assetName)
                                .renderingMode(.original)
                                .resizable()
                                .scaledToFit()
                                .frame(width: link.size.width, height: link.size.height)
                                // 图标本身只有十几点高，撑开一点可点区域（HIG 的最小点击区）。
                                .padding(4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(link.title)
                        .accessibilityLabel(link.title)
                    }
                    if showsMatchButton {
                        matchButton
                    }
                }
            }
        }
        .task(id: resolveKey) { await resolve() }
        // 页内区块刚自动匹配 / 用户刚手动关联完，头部图标要立刻跟上，
        // 不能等到下次进页面才出现。
        .onReceive(NotificationCenter.default.publisher(for: .bangumiLinkDidChange)) { _ in
            resolve()
        }
        .sheet(isPresented: $showingMatchSheet) {
            TMDbMatchSheet(item: item)
                // 面板里绑定完，图标要立刻从「无」变成「有」。
                .onDisappear { Task { await resolveTMDbLink() } }
        }
    }

    /// 手动匹配入口。用系统符号而不是品牌图：它不是一个外部站点链接，
    /// 混在品牌图标里会让人以为点下去是「打开 TMDb 网站」。
    private var matchButton: some View {
        Button {
            showingMatchSheet = true
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("手动匹配 TMDb 条目")
        .accessibilityLabel("手动匹配 TMDb 条目")
    }

    /// 解析 Bangumi 关联。
    ///
    /// 与页内 Bangumi 区块共用同一条门槛（设置停用 / 未登录就整块不出现），
    /// 否则会出现「区块提示未登录、头部却挂着 Bangumi 图标」这种自相矛盾。
    ///
    /// 读的是 `BangumiStore`（UserDefaults + 锁）：**不在 body 里读**——body 求值
    /// 与后台写构成互等的场景在 MoviePilot 上实测过一次，只在 task / 通知里解。
    private func resolve() {
        guard bangumiEnabled, bangumi.isAuthenticated else {
            bangumiSubjectID = nil
            Task { await resolveTMDbLink() }
            return
        }
        bangumiSubjectID = BangumiMatcher.linkedSubjectID(for: item, selectedSeason: selectedSeason)
        Task { await resolveTMDbLink() }
    }

    /// 取该条目已建立的 TMDb 对应（**不发网络**）。
    ///
    /// 与 Bangumi 那边不同，这里**不受 Bangumi 开关影响**：TMDb 图标与手动匹配入口
    /// 是独立功能，停用 Bangumi 不该把它们一起藏掉。
    private func resolveTMDbLink() async {
        guard app.tmdb.isReady else {
            tmdbLink = nil
            return
        }
        tmdbLink = await app.tmdbLink(for: item)
    }
}

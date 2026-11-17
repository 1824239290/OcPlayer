/// 设置 hub 的**分段表**（唯一事实源）。
///
/// 为什么数据化：这些行原先是散在 `SettingsView` 里四个手写的 `Section {}` 里的，
/// 「新增一个子页忘了挂到 hub」没有任何东西拦得住——而 hub 是**唯一的入口**，
/// 漏挂等于那个子页从界面上消失（子页自己不会报错，`SettingsSubpage.allCases`
/// 也只是多一个没人访问的 case）。现在分组是一份数据，`SettingsHubGroupingTests`
/// 可以遍历 `allCases` 断言「每页恰好出现一次」，漏挂当场变红。
///
/// ## 三段结构（2026-10-13，对照 Rex 的设置页）
///
/// 改前是四段：服务 / 播放与界面 / 网络与元数据 /（**最后一段没有标题**，装维护与关于）。
/// 对照产品的口径是三段、段段有标题，逐像素量下来我们的问题也在这里：
/// 无标题段只靠留白与前一段分隔，读起来是「两张卡而非一个分组」。
///
/// 重排的两条理由：
/// * **TMDB 归「服务」**：它是第三方服务集成，与 Jellyfin / Bangumi / MoviePilot 同类；
///   而「网络」（自定义 User-Agent）同样服务整条服务端链路——对照产品 Rex 也把
///   「反向代理」放在「服务」下。
/// * 原「网络与元数据」段只为两行而存在，段标题比内容还长。
enum SettingsHub {
    struct Group: Identifiable {
        let title: String
        let subpages: [SettingsSubpage]

        var id: String { title }
    }

    /// 段序即展示序：**服务**（外部依赖，最先配）→ **播放与界面**（本机体验）
    /// → **应用**（维护与元信息）。与原四段的相对顺序一致，只是把 TMDB 与网络
    /// 并进了「服务」、把最后一段补了标题。
    static let groups: [Group] = [
        Group(
            title: "服务",
            subpages: [.jellyfin, .bangumi, .moviepilot, .tmdb, .network]
        ),
        Group(
            title: "播放与界面",
            subpages: [.playback, .danmaku, .homeSections]
        ),
        Group(
            title: "应用",
            subpages: [.maintenance, .about]
        ),
    ]
}

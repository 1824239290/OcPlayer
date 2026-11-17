import AppDesignKit

/// 设置 hub 的子页清单（`AppModel.Route.settingsSubpage` 的载荷）。
///
/// 子页刻意走 **path 路由**而不是 `navigationDestination(isPresented:)`：
/// hub 的直接子页还会再推自己的叶子页（Jellyfin 页推「管理服务器」、关于页推
/// 「开源许可证」），isPresented 页面不在 path 上，祖先页要靠
/// `coveredByPresented` **逐层登记**才不会透过半透页面漏底；path 驱动的页面
/// 由根级 `opacity(app.path.isEmpty)` 与 `coveredPageHidden` 按深度自动隐藏
/// 整条链，谁都不用登记谁。
/// `CaseIterable` 有三个用处：① 自动化深链的合法键校验（`init?(routeKey:)`）；
/// ② 覆盖契约测试可以遍历全部子页断言「都有氛围底」，而不是靠人记得加；
/// ③ hub 分组测试遍历全部子页断言「每页都挂在 `SettingsHub.groups` 里、
/// 且只挂一次」——漏挂 hub 的子页在界面上根本进不去，此前无人拦得住。
enum SettingsSubpage: Hashable, CaseIterable {
    case playback
    case homeSections
    case danmaku
    case network
    case jellyfin
    case bangumi
    case moviepilot
    case tmdb
    case maintenance
    case about

    /// 子页标题。appShellBackChrome 的自绘标题（常规布局）与 navigationTitle
    /// （compact 布局的系统标题）共用这一个字符串。
    ///
    /// `.jellyfin` 显示成**「媒体服务器」**而不是「Jellyfin」（2026-10-13 用户口径）：
    /// 本 App 同时支持 Jellyfin 与 Emby，拿其中一家的名字当整类功能的入口名，
    /// 对 Emby 用户是误导。深层含义不变——`routeKey` 仍是 `jellyfin`
    /// （自动化通道 / `verify-ambience.sh` 的 PAGES 表依赖它，不许跟着改）。
    var title: String {
        switch self {
        case .playback: "播放"
        case .homeSections: "首页栏目"
        case .danmaku: "弹幕"
        case .network: "网络"
        case .jellyfin: "媒体服务器"
        case .bangumi: "Bangumi"
        case .moviepilot: "MoviePilot"
        case .tmdb: "TMDB 元数据补全"
        case .maintenance: "维护"
        case .about: "关于"
        }
    }

    /// hub 行的图标。
    ///
    /// 与 `routeKey` 刻意分开：`routeKey` 是写进脚本与 `PAGES` 表的**稳定 ASCII 标识**，
    /// 这个是**给人看的呈现**，换图标不该动自动化通道（同一条口径见 `routeKey` 的注释）。
    /// 与 `title` 放在一起：两者都是呈现层，改一个时另一个就在眼皮底下。
    ///
    /// 图标选择口径：
    /// * **有品牌资产的用品牌图**（Bangumi / MoviePilot / TMDB）——用户 2026-10-13 的口径是
    ///   「bangumi 的图标改成和 tabview 一样用 SVG、moviepilot 也一样、tmdb 也是」。
    ///   Bangumi / MoviePilot 走的是**和 Tab 栏同一份资产**（`-logo` 那套带 template
    ///   渲染意图的），所以和 Tab 上看到的、以及 macOS 顶栏药丸上的完全一致；
    ///   TMDB 只有官方彩色字标（`tmdb-logo`，无 template 意图 → 保持品牌配色）。
    /// * 其余用 SF Symbol，**语义直白优先**，且避免两个子页用同一个符号
    ///   （`SettingsHubGroupingTests` 会断言互不重复）。
    var icon: SettingsRowIconSource {
        switch self {
        case .playback: .symbol("play.circle")
        case .homeSections: .symbol("square.grid.2x2")
        case .danmaku: .symbol("text.bubble")
        case .network: .symbol("globe")
        case .jellyfin: .symbol("server.rack")
        // 23.5° / 0.94：两个方形 logo 的内容包围盒实测值（见 SettingsHubIconTests）。
        case .bangumi: .brand(name: "bangumi-logo", aspect: 0.94)
        case .moviepilot: .brand(name: "moviepilot-logo", aspect: 0.86)
        // 2.33:1 的官方 wordmark——图标框里按**宽**约束（见 fittedSize）。
        case .tmdb: .brand(name: "tmdb-logo", aspect: 2.33)
        case .maintenance: .symbol("wrench.and.screwdriver")
        case .about: .symbol("info.circle")
        }
    }
}

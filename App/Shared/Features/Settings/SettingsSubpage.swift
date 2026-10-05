/// 设置 hub 的子页清单（`AppModel.Route.settingsSubpage` 的载荷）。
///
/// 子页刻意走 **path 路由**而不是 `navigationDestination(isPresented:)`：
/// hub 的直接子页还会再推自己的叶子页（Jellyfin 页推「管理服务器」、关于页推
/// 「开源许可证」），isPresented 页面不在 path 上，祖先页要靠
/// `coveredByPresented` **逐层登记**才不会透过半透页面漏底；path 驱动的页面
/// 由根级 `opacity(app.path.isEmpty)` 与 `coveredPageHidden` 按深度自动隐藏
/// 整条链，谁都不用登记谁。
enum SettingsSubpage: Hashable {
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
    var title: String {
        switch self {
        case .playback: "播放"
        case .homeSections: "首页栏目"
        case .danmaku: "弹幕"
        case .network: "网络"
        case .jellyfin: "Jellyfin"
        case .bangumi: "Bangumi"
        case .moviepilot: "MoviePilot"
        case .tmdb: "TMDb 元数据补全"
        case .maintenance: "维护"
        case .about: "关于"
        }
    }
}

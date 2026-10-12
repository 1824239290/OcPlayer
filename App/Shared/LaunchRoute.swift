import Foundation

/// `OCPLAYER_START_ROUTE` 的目标页（Debug-only 自动化通道）。
///
/// **为什么需要它**：模拟器在本机只能无头跑（没有 `Simulator.app`，点按导航不可用），
/// 而 iOS 上「push 进来的页面 / 设置子页 / 呈现式叶子页」的观感验收必须有办法进场。
/// `OCPLAYER_START_SECTION` 只能到达分区根页，够不到它们。这个通道把「进场即到某页」
/// 补齐，验收台（`Scripts/verify-ambience.sh`，`gate=route` 的条目）据此逐页截图。
///
/// 纯值 + 纯解析：`parse(_:)` 不碰任何环境，用例可以直接铺表。
enum LaunchRoute: Equatable {
    /// 第一个媒体库的网格页（push）。
    case library
    /// 第一个带 backdrop 的首页条目详情页（push）——氛围图正是从条目 backdrop 来的。
    case detail
    /// Bangumi 个人页（push）。
    case bangumiProfile
    /// 每日放送（push）。
    case bangumiCalendar
    /// Bangumi 条目详情（push；`bangumi.subject.<id>`）。
    case bangumiSubject(id: Int)
    /// 设置子页（path 路由）。
    case settings(SettingsSubpage, leaf: SettingsLeaf?)
    /// iOS 放大镜 Tab（切分区，不是 push）。
    case search

    /// 设置子页里再下一层的**呈现式**叶子页（`navigationDestination(isPresented:)`）：
    /// 它们不在 `path` 上，没法用路由直接 push，只能由宿主页自己消费一个待开标记。
    enum SettingsLeaf: String, Equatable {
        /// Jellyfin 子页 → 管理服务器。
        case servers
        /// 关于子页 → 开源许可证。
        case licenses
    }

    /// 解析环境变量取值。语法（`.` 分段，逐段大小写不敏感）：
    ///
    ///     library                                    第一个媒体库网格页
    ///     detail                                     第一个带 backdrop 的首页条目详情
    ///     bangumi.profile                            我的
    ///     bangumi.calendar                           每日放送
    ///     bangumi.subject.<id>                       Bangumi 条目详情
    ///     settings.<子页键>                           设置子页（键见 SettingsSubpage.routeKey）
    ///     settings.jellyfin.servers                  设置 → Jellyfin → 管理服务器
    ///     settings.about.licenses                    设置 → 关于 → 开源许可证
    ///     search                                     搜索 Tab（iOS）
    ///
    /// 认不出的取值返回 nil（调用方记一条日志并照常启动，不拿它当致命错误）。
    static func parse(_ text: String) -> LaunchRoute? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ".").map { $0.lowercased() }
        guard let head = parts.first else { return nil }

        switch head {
        case "library" where parts.count == 1:
            return .library
        case "detail" where parts.count == 1:
            return .detail
        case "search" where parts.count == 1:
            return .search
        case "bangumi":
            return parseBangumi(Array(parts.dropFirst()))
        case "settings":
            return parseSettings(Array(parts.dropFirst()))
        default:
            return nil
        }
    }

    private static func parseBangumi(_ rest: [String]) -> LaunchRoute? {
        guard let kind = rest.first else { return nil }
        switch (kind, rest.count) {
        case ("profile", 1): return .bangumiProfile
        case ("calendar", 1): return .bangumiCalendar
        case ("subject", 2):
            guard let id = Int(rest[1]), id > 0 else { return nil }
            return .bangumiSubject(id: id)
        default: return nil
        }
    }

    private static func parseSettings(_ rest: [String]) -> LaunchRoute? {
        guard let key = rest.first, let subpage = SettingsSubpage(routeKey: key) else { return nil }
        switch rest.count {
        case 1:
            return .settings(subpage, leaf: nil)
        case 2:
            // 叶子页必须真的挂在那个子页下：写错了就是「点了没反应」的配置，
            // 不如直接判非法（调用方记日志，比静默无操作好排查）。
            guard let leaf = SettingsLeaf(rawValue: rest[1]), leaf.parentSubpage == subpage else {
                return nil
            }
            return .settings(subpage, leaf: leaf)
        default:
            return nil
        }
    }
}

extension LaunchRoute.SettingsLeaf {
    /// 叶子页的宿主子页。注册表在解析层强制，宿主页只按自己的身份消费标记。
    var parentSubpage: SettingsSubpage {
        switch self {
        case .servers: .jellyfin
        case .licenses: .about
        }
    }
}

extension SettingsSubpage {
    /// 自动化通道用的稳定键。**不复用 `title`**：标题是给人看的（会随文案改），
    /// 而这个键要写进脚本与 `PAGES` 表，必须是稳定的 ASCII 标识。
    var routeKey: String {
        switch self {
        case .playback: "playback"
        case .homeSections: "homesections"
        case .danmaku: "danmaku"
        case .network: "network"
        case .jellyfin: "jellyfin"
        case .bangumi: "bangumi"
        case .moviepilot: "moviepilot"
        case .tmdb: "tmdb"
        case .maintenance: "maintenance"
        case .about: "about"
        }
    }

    init?(routeKey: String) {
        let normalized = routeKey.lowercased()
        guard let match = SettingsSubpage.allCases.first(where: { $0.routeKey == normalized }) else {
            return nil
        }
        self = match
    }
}

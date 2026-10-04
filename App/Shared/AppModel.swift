import AppDesignKit
import BangumiKit
import CoreModel
import DanmakuKit
import DiagnosticsKit
import Foundation
import JellyfinKit
import MoviePilotKit
import Observation
import SwiftUI

/// 播放准备态：点击播放后、引擎真正 open 之前的阶段。单一真相——
/// loading 覆盖层、重试/取消入口都读它，替代散落的标志位。
enum PlaybackPreparation: Equatable {
    /// 正在解析播放地址（剧集叶子 / PlaybackInfo / streamURL）
    case loading(title: String)
    /// 解析失败，loading 层显示错误 + 重试
    case failed(title: String, error: String)
}

/// 应用的中枢状态机：登录 → 浏览 → 播放串联。
///
/// UI 只读这个类的属性、调它的方法；服务器细节被挡在 `MediaServer` 后面，
/// 内核细节被挡在 `PlaybackController` 后面。
///
/// 实现按职责拆到 `AppModel+Session` / `+Browser` / `+Playback`；
/// 存储属性集中在本文件，跨文件 extension 以模块内可见访问。
@MainActor
@Observable
final class AppModel {

    // MARK: - 登录态

    enum Phase {
        /// 刚启动，正在从磁盘恢复会话
        case boot
        /// 没有可用会话，进登录流程
        case onboarding
        case ready
    }

    var phase: Phase = .boot

    let store: ServerStore
    var server: (any MediaServer)?

    /// 当前生效的服务器地址（地址决议器探活择优的结果）。
    ///
    /// 一台服务器可以有多个入口（局域网 / Tailscale / 反代域名），决议器选中的
    /// 那条就是它；既是状态页展示的「现在走哪条」，也是界面重算图片 / 播放流地址
    /// 的触发点（换地址后视图必须重渲染，否则还举着老地址的图）。
    var serverEndpointURL: URL?

    /// 网络路径监听（Wi-Fi ↔ 蜂窝 / Tailscale 起停 → 地址结论作废重探）。
    let endpointMonitor = ServerEndpointMonitor()

    /// Every authenticated session gets a new generation. Async responses keep
    /// their generation and may only mutate state while it is still current.
    var sessionGeneration = 0
    var initialDataTask: Task<Void, Never>?

    // MARK: - Onboarding 中间态

    /// `startLogin` 成功后非 nil（已探明这是台 Jellyfin，等用户选登录方式）。
    var loginSession: (any ServerLoginSession)?
    var isProbingServer = false
    var isAuthenticating = false
    /// Quick Connect 轮询期间展示的配对码。
    var quickConnectCode: String?
    /// Quick Connect 不可用的原因（服务器没开、超时、请求失败）。
    ///
    /// 和 `onboardingError` 分开：QC 不可用**不是**登录失败，账号密码那条路还好好的。
    /// 混在一起的话，服务器关掉 QC 时用户会同时看到「正在申请配对码…」在转圈
    /// 和一条红色报错，而两句说的其实是同一件事。
    var quickConnectError: String?
    var onboardingError: String?

    var quickConnectTask: Task<Void, Never>?
    var loginAttemptGeneration = 0

    // MARK: - 浏览

    var libraries: [MediaLibrary] = []
    /// 「媒体库」选择面板加载失败时展示；成功加载后清空。
    var librariesError: String?

    /// Bangumi 详情页「MoviePilot下载」待消费的搜索词。详情页只放词 + 切分区，
    /// MoviePilot 首页出现后取走并清空（视图不重建就不会丢）。
    var pendingMoviePilotQuery: String?

    /// 媒体库网格分页缓存的键：**库 + 搜索词**（空串 = 浏览页）。
    ///
    /// 库内搜索是把结果**原地**写进该库分页缓存的，所以键上必须带搜索词。曾经只
    /// 用 libraryID：浏览页与搜索页共用一格——库内搜「败犬女主」→ 点进详情 → 回
    /// 首页 → 再点该库，缓存里还是那几条搜索结果，而 `LibraryView.searchText` 是
    /// `@State`、视图重建后已空 → **搜索框空着、网格却只剩当初那几条**，且没有
    /// 任何入口能切回浏览页（只能重新搜一次再清空）。带词分键后浏览页与当前搜索词
    /// 各占一格，切走再回来各自还原。
    struct LibraryPageKey: Hashable {
        var libraryID: MediaLibrary.ID
        var searchTerm: String = ""
    }

    /// 媒体库网格的分页缓存，按 `LibraryPageKey` 存。
    ///
    /// 原来 items / totalCount 是 `LibraryView` 的 `@State`：侧栏切走再切回来，
    /// `.task(id:)` 重跑一次就从 startIndex 0 重新拉——深翻过十几页的大库回来时
    /// 整份都丢了。详情页的 `episodesBySeason` 早就解决了同一个问题，这里补上。
    /// 换会话（`activate` / `signOut`）时清空。
    struct LibraryPage: Equatable {
        var items: [MediaItem] = []
        var totalCount: Int?
        var nextStartIndex = 0
        var lastPageWasFull = false
    }

    var libraryPages: [LibraryPageKey: LibraryPage] = [:]

    /// 分页缓存条目总量上限：超大服务器深翻多个库时无上限增长会吃掉几百 MB
    /// （每条 MediaItem 带长 overview）。超限就整份清空、只回填当前正在浏览的
    /// 这一库——分页缓存只是「回库不重拉」的加速器，清空代价是下次进库重新翻页，
    /// 不值得为它维护 LRU 结构。
    static let libraryPagesItemLimit = 20_000

    func cacheLibraryPage(_ page: LibraryPage, for libraryID: MediaLibrary.ID, searchTerm: String = "") {
        let key = LibraryPageKey(libraryID: libraryID, searchTerm: searchTerm)
        libraryPages[key] = page
        // 搜索页同时可达的只有一个：搜索框一次只装一个词，切库还会把它清空
        // （见 LibraryView 的 lastLibraryID）。旧搜索词的格子再也读不到，直接丢，
        // 免得它们在字典里无界累积；浏览页（空词）是切走再回来的落脚点，全部保留。
        if !searchTerm.isEmpty {
            libraryPages = libraryPages.filter { $0.key.searchTerm.isEmpty || $0.key == key }
        }
        let totalItems = libraryPages.values.reduce(0) { $0 + $1.items.count }
        if totalItems > Self.libraryPagesItemLimit {
            libraryPages = [key: page]
        }
    }

    /// 作废某库某搜索词的分页缓存。换排序时旧页在新顺序下是错序数据，直接清掉重取；
    /// 分页缓存只是「回库不重拉」的加速器，清空的代价是下次进库从第一页翻。
    func clearLibraryPage(for libraryID: MediaLibrary.ID, searchTerm: String = "") {
        libraryPages[LibraryPageKey(libraryID: libraryID, searchTerm: searchTerm)] = nil
    }

    // MARK: - 详情页快照缓存（stale-while-revalidate）

    /// 详情页跨进入的内容快照：再次进入同一详情先用快照即时渲染（不闪骨架屏），
    /// 同时后台重拉并原位覆盖。快照都是小结构体，正常会话远到不了上限；
    /// 超限整份清空（下次进入回到首拉行为，代价可忽略）。
    struct DetailSnapshot {
        var detail: MediaItem
        var seasons: [MediaItem]
        var similar: [MediaItem]
        var selectedSeasonID: String?
        var episodesBySeason: [String: [MediaItem]]
    }

    static let detailSnapshotLimit = 40
    var detailSnapshots: [MediaItem.ID: DetailSnapshot] = [:]
    /// 快照的最近使用顺序（末尾最新）。淘汰时按它丢**最旧**的，而不是整份清空。
    private var detailSnapshotRecency: [MediaItem.ID] = []

    func storeDetailSnapshot(_ snapshot: DetailSnapshot, for id: MediaItem.ID) {
        detailSnapshots[id] = snapshot
        noteSnapshotUse(id)
        // 超限只淘汰最旧的那些，**必须保留刚写入的这条**：整份 `removeAll()` 会把
        // 为了提高"再次进入即时有内容"而刚存下的快照一起丢掉，于是第 41 次进入
        // 详情页立刻退回冷骨架屏——SWR 的收益变成随机的。删到限额为止即可。
        while detailSnapshots.count > Self.detailSnapshotLimit {
            guard let oldest = detailSnapshotRecency.first else { break }
            detailSnapshotRecency.removeFirst()
            if oldest != id { detailSnapshots[oldest] = nil }
        }
    }

    /// 读快照顺手刷新使用顺序：不刷新的话"最近看过的页"会被后续新页挤掉，
    /// 与我们想要的 LRU 语义相反。
    func detailSnapshot(for id: MediaItem.ID) -> DetailSnapshot? {
        guard let snapshot = detailSnapshots[id] else { return nil }
        noteSnapshotUse(id)
        return snapshot
    }

    /// 顺序表的自愈：`detailSnapshots` 可能在别处被整体清掉（换会话），此时把
    /// 悬空 id 一并剔除，避免淘汰时对着不存在的键空转。
    private func noteSnapshotUse(_ id: MediaItem.ID) {
        detailSnapshotRecency.removeAll { $0 == id || detailSnapshots[$0] == nil }
        detailSnapshotRecency.append(id)
    }

    /// 会话边界用：快照与它的顺序表必须一起清，否则顺序表会留下悬空 id。
    func clearDetailSnapshots() {
        detailSnapshots = [:]
        detailSnapshotRecency = []
    }

    struct HomeData: Equatable {
        var resume: [MediaItem] = []
        var nextUp: [MediaItem] = []
        var latest: [MediaItem] = []
        var isLoading = false
        var error: String?
        /// 上一次成功加载时哪几条 Rail 有内容（跨启动保留，见 `HomeRailPresence`）。
        /// 骨架屏据此决定铺几条：写死三条的话，没有「继续观看」的服务器上
        /// 骨架撤掉的瞬间会塌掉几百 pt——那正好是骨架屏本该消掉的跳动。
        ///
        /// 初值在 `AppModel.init` 里按注入的 `preferences` 重设（这里给的是
        /// `.standard` 兜底，保证 `HomeData()` 单独构造时也可用）。
        var railPresence = HomeRailPresence.restored()
        /// 当前展示的内容来自磁盘缓存时的写入时间（nil = 内容来自本次会话的网络请求）。
        /// 与 `home.error` 不同：error 表示「什么都没拿到」，这个表示「有内容但没刷新成功」。
        var cachedFetchedAt: Date?
        /// 这次刷新失败是否由「连不上」导致（决定提示说不说「离线」）。
        var refreshFailureWasConnectivity = false
    }

    var home = HomeData()

    /// 首页当前该渲染哪一态。
    ///
    /// 抽到模型上而不是留在 `HomeView` 的 `if` 链里，是因为**这条判定错过一次**：
    /// 原来用 `home.latest.isEmpty` 单独一条 rail 当「有没有内容」的判据，而服务器
    /// 完全可以没有「最近添加」（`railPresence` 就是为这种情况存在的）——那种服务器
    /// 上 `latest` 恒为空，于是**哪怕缓存里已经有内容，加载期间也一直显示骨架屏**
    /// （实测离线冷启动：磁盘已读出 3+6 条，界面仍只转骨架）。判定留在视图里就
    /// 没法为它写回归用例。
    enum HomePresentation: Equatable {
        /// 首次加载、且手上没有任何可显示的内容。
        case loading
        /// 全局失败、且没有任何可显示的内容（有内容时永远优先显示内容）。
        case error(String)
        case content
    }

    /// 三条 rail 的并集是否至少有一条内容。
    var hasAnyHomeContent: Bool {
        !home.resume.isEmpty || !home.nextUp.isEmpty || !home.latest.isEmpty
    }

    var homePresentation: HomePresentation {
        // **有内容就先显示内容**，无论是否还在加载、是否有某条 rail 失败：
        // 这正是「先读磁盘」的目的——离线 / 慢网时用户立刻看到上次的样子，而不是
        // 对着骨架屏等重试跑完（实测一台不可达服务器要重试 3 次 × 2 个地址，
        // 73 秒才落地）。
        if hasAnyHomeContent { return .content }
        if home.isLoading { return .loading }
        if let error = home.error { return .error(error) }
        // 三条 rail 都成功但都是空的（空库 / 新服务器）：走内容分支，由它的
        // 「暂无可展示内容」空态承接，而不是错误页。
        return .content
    }

    /// 首页当前是否在展示「没刷新成功的缓存内容」。
    ///
    /// 判定只看**有没有内容**与**这次刷新有没有失败**，刻意**不看 `home.error`**：
    /// `home.error` 在三条 rail 全挂时置位，而「断网冷启动」正是这个形态——磁盘上
    /// 有内容、网络全挂、error 被置位。若在这里 guard `error == nil`，离线冷启动就会
    /// 显示着缓存内容却**一个提示都没有**，用户完全不知道这是旧数据。
    ///
    /// 「该不该显示整页错误」是另一回事，由 `homePresentation` 决定：有内容时它
    /// 总是 `.content`（此时本提示生效），没内容时才轮到错误页。
    var homeStaleNotice: StaleContentNotice? {
        // 首次加载中不提示（内容还没落地，提示会闪一下）。
        guard !home.isLoading else { return nil }
        // 有内容才有可标的对象。
        guard !home.resume.isEmpty || !home.nextUp.isEmpty || !home.latest.isEmpty else { return nil }
        // 这次刷新确实失败过（全部成功时下面两个标记都会被清掉）。
        guard home.cachedFetchedAt != nil || home.refreshFailureWasConnectivity else { return nil }
        return StaleContentNotice(
            fetchedAt: home.cachedFetchedAt,
            causedByConnectivity: home.refreshFailureWasConnectivity)
    }
    /// 同一会话内可能同时发生下拉刷新和设置切换；只有最新一次首页请求可以写回。
    var homeLoadGeneration: UInt64 = 0

    // MARK: - 弹幕设置（弹弹play 网关）

    /// 弹幕域模型（协调器 + 网关设置），独立环境注入：播放器 / 设置页里只看弹幕的视图
    /// 不再被 AppModel 的全量观察拖着重绘。AppSecret 永远不进客户端，只留在网关。
    var danmakuModel: DanmakuModel

    // MARK: - Bangumi（登录 / 进度 / 收藏）

    let bangumi: BangumiCoordinator

    // MARK: - MoviePilot（搜索 / 下载）

    let moviepilot: MoviePilotCoordinator

    // MARK: - 媒体元数据缓存（SQLite）

    /// 元数据落盘 + 写穿缓存。测试下不建库（见 `bootstrap`），此时它的 `wrap`
    /// 原样返回服务器，行为与引入缓存之前一致。
    let metadata: MetadataCoordinator

    /// TMDb 元数据补全（可选增强，用户配置 key 后生效）。
    ///
    /// 与 `metadata` 分开两个协调器，但**共用同一个 `Media.sqlite`**（TMDb 的表
    /// 就在那个库里）：缓存层与补全层的生命周期、失败模式都不一样，混成一个类
    /// 会让「没配 key」与「建库失败」两种降级纠缠在一起。
    let tmdb: TMDbCoordinator

    /// App 级偏好的落盘域（见 `init` 的说明）。
    @ObservationIgnored let preferences: UserDefaults

    // MARK: - 导航

    enum Section: Hashable {
        case home
        case settings
        case bangumi
        case moviepilot
        /// iOS 放大镜 Tab（`Tab(role: .search)`）；常规布局（macOS 顶栏）不会到达。
        case search
    }

    enum Route: Hashable {
        case detail(MediaItem)
        /// 首页「媒体库」栏 → 单库网格页的 push 路由。
        case library(MediaLibrary)
        case bangumiProfile
        case bangumiCollectionList(BangumiSubjectType)
        case bangumiSubject(subjectID: Int, initialSubject: BangumiSlimSubjectDTO? = nil)
        case bangumiCalendar
    }

    /// iOS 各 Tab 的独立导航栈。每 Tab 一个路径数组，互不串。
    struct NavigationPaths {
        var home: [Route] = []
        var bangumi: [Route] = []
        var moviepilot: [Route] = []
        var settings: [Route] = []
        var search: [Route] = []
    }

    var selectedSection: Section = .home {
        didSet {
            // 常规布局（Mac/iPad）切 Section 时清空共享栈；紧凑布局各 Tab 有独立栈，无需清。
            if selectedSection != oldValue, !isCompact { path = [] }
        }
    }

    /// Mac / iPad 的共享 push 栈。**外部只读**：写入口只有 `push` / `back` /
    /// `handleStackPathChange` 三个。
    ///
    /// 这里踩过坑：`path` 与 `navPaths` 是两个真源（常规布局用前者、compact 各 Tab
    /// 用后者），而 `push()` 会按 `isCompact` 分派到正确的那个。视图一旦绕过
    /// `push()` 直接 `app.path.append(...)`，在 iOS 上就是**点了没反应**——`path`
    /// 在 compact 布局下只被写、从不被读（Bangumi 的「每日放送 / 个人主页 / 收藏
    /// 列表」三个入口就是这么坏的）。`private(set)` 把这类错误从"运行时静默失效"
    /// 变成"编译期报错"。
    private(set) var path: [Route] = []

    /// iPhone 各 Tab 独立的导航路径——每个 Tab 一个栈，互不串。
    /// 之前 iPhone 走 `.sheet` 弹详情是因为多 Tab 共享一个 `path` 会互相踩；
    /// 现在分栈后详情页走 push，播放器覆盖层不再被 sheet 遮住。
    /// 同样 **外部只读**，视图经 `navPath(for:)` 取 binding。
    private(set) var navPaths = NavigationPaths()

    /// 某个 Tab 的独立栈（compact 布局的 `NavigationStack` 绑定读取侧）。
    func navPath(for section: Section) -> [Route] {
        switch section {
        case .home: navPaths.home
        case .bangumi: navPaths.bangumi
        case .moviepilot: navPaths.moviepilot
        case .settings: navPaths.settings
        case .search: navPaths.search
        }
    }

    /// 某个 Tab 的独立栈（系统 push / pop 写回 binding 的入口）。
    func setNavPath(_ newValue: [Route], for section: Section) {
        switch section {
        case .home: navPaths.home = newValue
        case .bangumi: navPaths.bangumi = newValue
        case .moviepilot: navPaths.moviepilot = newValue
        case .settings: navPaths.settings = newValue
        case .search: navPaths.search = newValue
        }
    }

    /// 常规布局共享栈的写回入口：系统返回键 / 边缘滑动手势都会把**变短的** path
    /// 写回 binding。这里统一拦成与 push 对称的两段式（淡出 → 弹栈 → 落点淡入），
    /// 变长（程序化 push）直接落地。
    ///
    /// 收进模型而不是留在视图的 Binding setter 里：栈的写入口只要多于一个，
    /// 就一定会漂（见 `path` 的注释）。
    func handleStackPathChange(_ newValue: [Route]) {
        guard newValue.count < path.count else {
            path = newValue
            return
        }
        beginRouteExit { [weak self] in self?.path = newValue }
    }

    /// 播放覆盖层：非 nil 时播放器盖住整个 App（双端同一套，见 RootView）。
    var presentedPlayer: PlaybackRequest? {
        didSet {
            guard oldValue?.id != presentedPlayer?.id else { return }
            #if os(iOS)
            // ⚠️ 不能用「外部装配闭包」回调方向切换（issue #5 排查实录）：SwiftUI
            // 会多次创建 App 值，App.init / body 闭包经 @State 访问到的 appModel 实例和
            // SwiftUI 实际存储/注入的是**不同对象**（ObjectIdentifier 实测
            // 0x8000 vs 0xb200），闭包装配静默丢失、横屏锁整个失效。
            // 改为广播通知：AppDelegate 在自身 init（最早时机）监听，无装配时序问题。
            NotificationCenter.default.post(
                name: Self.playerPresentationDidChangeNotification,
                object: nil,
                userInfo: ["active": presentedPlayer != nil])
            #endif
        }
    }

    #if os(iOS)
    /// presentedPlayer 开合广播（AppModel → IOSApplicationDelegate 切方向锁）。
    static let playerPresentationDidChangeNotification =
        Notification.Name("OcPlayer.playerPresentationDidChange")
    #endif

    /// 「打开本地视频文件」请求标志：首页工具栏菜单 / macOS 文件菜单（Cmd+O）
    /// 置 true，RootView 的 fileImporter 以它为 isPresented，选择完成或取消自动复位。
    var isLocalFileImporterPresented = false
    /// 「打开直连链接」请求标志：同样由 RootView 承载 URLEntrySheet。
    var isDirectLinkSheetPresented = false

    /// 播放结束/退出后自增，驱动打开中的详情页拉取最新 playState。
    var detailRefreshGeneration: UInt64 = 0

    var isCompact = false

    /// 两段式换页进行中：当前页淡出、落地（push 或 pop）未发生。期间新的
    /// 换页请求被忽略（防连点）；AppShell 的 `RouteExitFader` 读它画淡出，
    /// 落地后的回弹淡入就是落点页的入场。
    var routeExiting = false

    /// 换页落地代次。会话重置时自增，使在飞的「淡出 → 落地」闭包作废
    /// （见 `beginRouteExit` 与 `invalidatePendingRouteExit`）。
    private(set) var routeExitGeneration: UInt64 = 0

    /// 清空全部导航栈（`path` 与 `navPaths` 是 `private(set)`，写入口集中在本文件）。
    /// 会话边界（登出 / 换服 / 401）用。
    func clearNavigationStacks() {
        path = []
        navPaths = NavigationPaths()
    }

    /// 作废在飞的「淡出 → 落地」闭包：换页意图属于旧会话，不能再落到新会话的栈上。
    /// 顺带复位 `routeExiting`，否则新会话的第一下点击会被防连点守卫吞掉。
    func invalidatePendingRouteExit() {
        routeExitGeneration &+= 1
        routeExiting = false
    }

    /// `accessibilityReduceMotion` 的副本（AppShell 注入）：开启时换页直切，
    /// 不做淡出等待。
    var reduceMotion = false

    /// 整窗氛围底声明（常规布局 Mac/iPad）：有氛围图的页面经 `windowAmbience(_:)`
    /// 出现时声明、离屏时撤回，AppShell 据此在导航栈之外垫同一张模糊图——
    /// macOS 26 只有栈根宿主是全窗的，pushed 页自己够不到侧栏底下。
    ///
    /// **是栈不是单值**：页面嵌套时后声明者覆盖前者（详情页 → 呈现的资源搜索页），
    /// 单值在覆盖者离屏时只能清成 nil，宿主的声明就丢了（「返回详情页背景丢失」
    /// 的另一扇门）。栈顶即当前生效值；条目 nil ＝ 该页声明「无氛围」，照样占一层。
    private var windowAmbienceStack: [WindowAmbienceEntry] = []

    /// 当前生效的整窗氛围底（声明栈栈顶；空栈＝无人声明，整窗层回落到首页轮播）。
    var windowAmbience: WindowAmbience? {
        windowAmbienceStack.last?.value ?? nil
    }

    /// 页面出现时压入自己的整窗氛围声明（`WindowAmbienceSetter.onAppear`）。
    /// 条目带 id，页面存续期间的声明变化原位更新、离屏时按 id 摘除——
    /// 天然不会清掉别页刚压入的条目（含 onDisappear 晚于新页 onAppear 的乱序）。
    func pushWindowAmbience(id: UUID, _ value: WindowAmbience?) {
        windowAmbienceStack.append(WindowAmbienceEntry(id: id, value: value))
    }

    /// 页面存续期间声明晚到 / 变化（详情页数据加载后才有 backdrop 图）：原位换新。
    /// 条目不在栈里（会话重置清过栈的残留页面）就忽略——重置连导航栈一起清了，
    /// 这种页面马上会销毁，不能再把旧服务器的声明压回新会话。
    func updateWindowAmbience(id: UUID, _ value: WindowAmbience?) {
        guard let index = windowAmbienceStack.firstIndex(where: { $0.id == id }) else { return }
        windowAmbienceStack[index].value = value
    }

    /// 页面离屏时摘掉自己的声明条目（`WindowAmbienceSetter.onDisappear`）。
    func removeWindowAmbience(id: UUID) {
        windowAmbienceStack.removeAll { $0.id == id }
    }

    /// 会话边界清空整个声明栈（`resetBrowseState`）：条目里的 URL 都带着
    /// 旧服务器的 authHeader，不能带进新会话。
    func resetWindowAmbienceStack() {
        windowAmbienceStack.removeAll()
    }

    /// 首页氛围轮播当前那张图，由 `AmbientBackdropCarousel` 声明。iOS 的详情页在
    /// 自身底图就绪前拿它顶底：导航栈宿主不透明、栈后垫层到不了屏幕（实测），
    /// 「背景从首页延续进详情页」只能在页面内做——先画这张（与首页同 URL、同档
    /// 解码，内存缓存直接命中），自己的底图到位后再淡入替换。
    var homeAmbience: WindowAmbience?

    /// 播放器控制引用（RootView 装配时注入）：进度上报 / 连播要读实时位置。
    weak var playback: PlaybackController? {
        didSet {
            guard playback !== oldValue else { return }
            let precedingStop = playbackReporting?.stop() ?? pendingPlaybackReportingHandoff
            clearPlaybackSessionState()
            pendingPlaybackReportingHandoff = precedingStop
            if let playback {
                playbackReporting = PlaybackReportingCoordinator(
                    stateSource: playback,
                    precedingStoppedReport: pendingPlaybackReportingHandoff
                )
                pendingPlaybackReportingHandoff = nil
            } else {
                playbackReporting = nil
            }
        }
    }
    var playbackReporting: PlaybackReportingCoordinator?
    var pendingPlaybackReportingHandoff: Task<Void, Never>?

    // MARK: - 播放会话附属状态

    /// 当前正在解析播放地址的请求。旧请求不能在新请求之后返回并覆盖播放器。
    var playbackOpenTask: Task<Void, Never>?
    var playbackOpenGeneration: UInt64 = 0
    /// loading 层延后撤除的观察任务（等内核出帧）。
    var preparationDismissTask: Task<Void, Never>?
    // dismissPlayer 的收尾刷新任务（等 Stopped 落库后刷首页/详情）：可取消。
    var dismissFollowUpTask: Task<Void, Never>?
    /// 播放准备态：nil = 不在准备（空闲，或已呈现给 PlayerScreen）。
    var playbackPreparation: PlaybackPreparation?
    /// 保留 Jellyfin 条目，重试请求期间 finishReporting 清掉 nowPlayingItem 后仍可安全重试。
    var retryPlaybackItem: MediaItem?
    struct ActivePlaybackIdentity: Equatable {
        let sessionGeneration: Int
        let itemID: MediaItem.ID
        let requestID: PlaybackRequest.ID
    }
    var activePlaybackIdentity: ActivePlaybackIdentity?
    /// 覆盖层正在播放的条目（HUD 标题 / 继续观看用）；退出 / 换片时随上报一起清。
    var nowPlayingItem: MediaItem?
    /// 连播解析出的「下一集」；HUD「Continue Watching」复用它，nil = 没有下一集。
    var nextEpisode: MediaItem?
    var nextEpisodeTask: Task<Void, Never>?
    var externalSubtitleTask: Task<Void, Never>?

    /// iOS 前后台往返：离开前台时正在播（回前台要接着播的意图）。
    /// 内核侧的暂停/恢复在 `PlaybackController.beginSystemSuspension`，
    /// 这里只记「该不该接回去」——要不要重建内核得 App 层来判（它才知道是哪条会话）。
    var backgroundResumeIntent = false
    /// 回前台后的观察窗任务：挂起把内核弄坏时，报错未必在 `play()` 当场落地，
    /// 可能迟一步（见 `AppModel.watchPlaybackAfterSystemResume`）。
    var backgroundRecoveryWatch: Task<Void, Never>?

    // MARK: - 初始化

    /// 域模型全部经 init 注入（默认值保持生产装配不变）；测试可换入隔离实例，
    /// 不再被「init 里默认构造 + bangumi.setup() 副作用」绑死。
    /// - Parameter preferences: App 级偏好的落盘域（首屏骨架条数等）。
    ///   与 `ServerStore(defaults:)` / `MoviePilotStore(defaults:)` 同款注入点：
    ///   测试必须能换成隔离 suite——`xcodebuild` 默认**并行多进程**跑用例，而
    ///   这些用例共用同一个 bundle id 的 `UserDefaults.standard`，两个类同时写
    ///   同一个键就会互相污染（实测：新增的集成用例与本文件里的
    ///   `HomeRailLoadingTests` 抢 `home.railPresence`，后者当场挂）。
    init(
        store: ServerStore = ServerStore(),
        bangumi: BangumiCoordinator = BangumiCoordinator(),
        moviepilot: MoviePilotCoordinator = MoviePilotCoordinator(),
        danmakuModel: DanmakuModel = DanmakuModel(),
        metadata: MetadataCoordinator = MetadataCoordinator(),
        tmdb: TMDbCoordinator? = nil,
        preferences: UserDefaults = .standard
    ) {
        self.store = store
        self.bangumi = bangumi
        self.moviepilot = moviepilot
        self.danmakuModel = danmakuModel
        self.metadata = metadata
        // 默认用注入的那个 `preferences` 域构造：测试传独立 suite 时，
        // TMDb 的设置项不该落到 `.standard`（否则会与其他测试进程互相污染）。
        self.tmdb = tmdb ?? TMDbCoordinator(defaults: preferences)
        self.preferences = preferences
        // 首屏骨架的条数来自注入域（不是 `HomeData` 默认值里的 `.standard`）。
        home.railPresence = HomeRailPresence.restored(from: preferences)
        // TheIntroDB 需要**剧集级** TMDB ID（集条目 ProviderIds 里的 Tmdb 是集级
        // 的,不能直接用）——按 seriesID 现场换一份。
        danmakuModel.danmaku.seriesTmdbIDProvider = { [weak self] seriesID in
            await self?.seriesTmdbID(for: seriesID)
        }
        if let section = LaunchOptions.initialSection {
            if let delay = LaunchOptions.sectionSwitchSeconds {
                // 先留首页让轮播跑起来（homeAmbience 就位），到点再切目标分区。
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    selectedSection = section
                }
            } else {
                selectedSection = section
            }
        }
    }

    /// 处理 Bangumi OAuth 回调（macOS 浏览器 / iOS ASWebAuthenticationSession 都汇到这里）。
    /// 返回错误文案（nil = 成功）。
    @discardableResult
    func handleBangumiOAuthURL(_ url: URL) async -> String? {
        await bangumi.handleOAuthCallback(url: url)
    }

    /// 由外壳在布局定型时告知（iPhone → compact），详情导航方式随之切换。
    func setCompact(_ compact: Bool) {
        isCompact = compact
    }

    func openDetail(_ item: MediaItem) {
        push(.detail(item))
    }

    /// 首页「媒体库」栏入口：push 到当前栈（`.library` 路由已在 `appRoutes()` 注册）。
    func openLibrary(_ library: MediaLibrary) {
        push(.library(library))
    }

    func openBangumiSubject(id: Int, initialSubject: BangumiSlimSubjectDTO? = nil) {
        push(.bangumiSubject(subjectID: id, initialSubject: initialSubject))
    }

    /// Bangumi 个人主页。**必须走 push**（不能由视图直接改栈）：compact 布局下
    /// 栈是 `navPaths.<tab>`，写 `path` 等于点了没反应。
    func openBangumiProfile() {
        push(.bangumiProfile)
    }

    /// Bangumi 每日放送日历。同上。
    func openBangumiCalendar() {
        push(.bangumiCalendar)
    }

    /// Bangumi 某个收藏类型的完整列表。同上。
    func openBangumiCollectionList(_ subjectType: BangumiSubjectType) {
        push(.bangumiCollectionList(subjectType))
    }

    /// 程序化呈现（`navigationDestination(isPresented:)` / view-destination 页面）
    /// 与 push 共用同一套两段式。
    func pushPresented(_ present: @escaping @MainActor () -> Void) {
        beginRouteExit(land: present)
    }

    /// 关闭呈现式页面：`pushPresented` 的对称出口。
    ///
    /// 这类页面不在 `path` 上（`isPresented` 是另一套呈现机制，栈里看不见它），
    /// 走 `back()` 会被 `guard !path.isEmpty` 挡掉——自绘返回键点下去毫无反应
    /// （下载管理 / 资源搜索 / 管理服务器 / 开源许可证都踩过）。所以呈现式页面
    /// 的返回键必须显式把自己的落地开关交进来（见
    /// `appShellBackChrome(title:presented:)`），不能走 `back()`。
    ///
    /// `restoreDelay` 与 `back()` 同理：系统关闭动画期间离场页还挂在树里，
    /// 立即复位 `routeExiting` 会让它边滑边显形。
    func popPresented(_ dismiss: @escaping @MainActor () -> Void) {
        beginRouteExit(land: dismiss, restoreDelay: Motion.exitSeconds)
    }

    /// 分区切换（顶栏药丸）：常规布局走与 push 相同的两段式——当前页淡出后
    /// 再换分区；compact（iPhone Tab）系统自带切换动画，直切。
    func switchSection(_ section: Section) {
        if isCompact || reduceMotion || section == selectedSection {
            selectedSection = section
            return
        }
        beginRouteExit { [weak self] in
            self?.selectedSection = section
        }
    }

    private func push(_ route: Route) {
        beginRouteExit { [weak self] in
            guard let self else { return }
            if isCompact {
                compactPath.append(route)
            } else {
                path.append(route)
            }
        }
    }

    /// 返回上一层（自绘返回键）：与 push 对称的两段式——当前页淡出后再弹栈。
    /// 系统返回键的 pop 是系统级滑出、不经 binding 拦不住，所以常规布局的
    /// 返回键自绘（见 AppShellBackButton）；弹栈用禁动画 transaction 落地。
    ///
    /// **只管栈上的路由页**：呈现式页面（`navigationDestination(isPresented:)`）
    /// 不在 `path` 里，`path` 为空时的返回是空操作——那种页面走 `popPresented`。
    func back() {
        guard !path.isEmpty else { return }
        // 弹栈的过渡期间离场页还挂在树里，立即恢复 routeExiting 会让它
        // 边滑边显形——等过渡走完（离场页真正移除）再恢复，落点页独自淡入。
        beginRouteExit(land: { [weak self] in
            guard let self else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { self.path.removeLast() }
        }, restoreDelay: Motion.exitSeconds)
    }

    /// 两段式换页（push / pop / 分区切换共用）：点击后当前页先淡出
    /// （`Motion.exit`），淡出完成再执行 `land` 落地，落点/新页由淡出层回弹
    /// 淡入（push 页另有 `pageEntrance` 接力）。compact（iPhone）系统动画
    /// 本来就在，reduceMotion 直切，都不等待。pop 侧由自绘返回键调用。
    func beginRouteExit(land: @escaping @MainActor () -> Void, restoreDelay: Double = 0) {
        if isCompact || reduceMotion {
            land()
            return
        }
        guard !routeExiting else { return }
        routeExiting = true
        // 会话代次快照：淡出期间若发生登出/换服/401（`resetBrowseState` 会自增），
        // 这次换页的意图属于**旧会话**，落地必须作废——否则旧服务器的
        // `.detail(item)` 会被 append 进新会话的空栈，表现为"刚登录就弹出一个
        // 不存在于这台服务器的详情页"。`routeExiting` 由重置清掉，不会卡住。
        let generation = routeExitGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(Motion.exitSeconds))
            guard generation == routeExitGeneration else { return }
            land()
            // 恢复前留出前置拍：新页（push 落地新建的视图）必须先以隐藏态
            // 提交一帧，routeExiting 复位的淡入才有 from-state；pop 侧还要
            // 加上 restoreDelay 等系统弹栈过渡走完（离场页真正移除）。
            try? await Task.sleep(for: .seconds(Motion.restoreDelay))
            if restoreDelay > 0 {
                try? await Task.sleep(for: .seconds(restoreDelay))
            }
            routeExiting = false
        }
    }

    /// iOS 端当前选中 Tab 对应的导航路径数组。
    private var compactPath: [Route] {
        get { navPath(for: selectedSection) }
        set { setNavPath(newValue, for: selectedSection) }
    }

    /// 首页的续播条目通常是 Episode；详情入口应落到所属电视剧，而不是单集。
    /// 先复用首页已有的 Series 数据（最近添加 → 继续观看/接下来看里能带上的图），
    /// 没有缓存时用父级 ID 构造轻量占位，DetailView 随后会按该 ID 拉取完整详情、季和分集。
    func openSeriesDetail(for item: MediaItem) {
        guard let seriesID = item.seriesID else {
            openDetail(item)
            return
        }

        let cachedSeries = home.latest.first {
            $0.id == seriesID && $0.kind == .series
        }
        if let cachedSeries {
            openDetail(cachedSeries)
            return
        }

        // resume / nextUp 多半是 Episode：用条目上的 series 名 + 尽量带上已有图 tag，
        // 减少详情页首帧海报空窗（完整字段仍由 DetailView 再拉）。
        let related = (home.resume + home.nextUp).first { $0.seriesID == seriesID }
        let series = MediaItem(
            id: seriesID,
            name: related?.seriesName ?? item.seriesName ?? item.name,
            kind: .series,
            primaryImageTag: related?.primaryImageTag ?? item.primaryImageTag,
            thumbImageTag: related?.thumbImageTag ?? item.thumbImageTag,
            backdropImageTag: related?.backdropImageTag ?? item.backdropImageTag
        )
        openDetail(series)
    }

    // MARK: - 派生

    var currentUserLabel: String {
        guard let server else { return "" }
        let profile = server.profile
        return profile.userName ?? profile.userID
    }

    var serverLabel: String {
        guard let profile = server?.profile else { return "" }
        let version = profile.serverVersion.map { " \($0)" } ?? ""
        return "\(profile.serverName) · \(profile.kind.displayName)\(version)"
    }
}

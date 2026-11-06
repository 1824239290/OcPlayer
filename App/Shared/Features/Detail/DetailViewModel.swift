import AppDesignKit
import CoreModel
import JellyfinKit
import MetadataKit
import SwiftUI

/// 详情页的数据面视图模型：详情/季/集/类似的加载、缓存与选中态。
///
/// 从 `DetailView` 抽出（原 19 个 @State + 5 个加载方法摊在视图里）。
/// 视图只留布局与交互编排；所有「拉什么、怎么缓存、默认选哪季哪集」都在这里，
/// 可脱离 SwiftUI 直接测。
///
/// `attach(_:)` 而不是 init 注入 AppModel：SwiftUI 视图的 init 拿不到 @Environment，
/// VM 在 `.task` 里补挂；所有加载方法以 `app?.server` 为守卫，未挂载 = 不请求。
@MainActor
@Observable
final class DetailViewModel {
    let item: MediaItem
    private weak var app: AppModel?
    @ObservationIgnored private var attachedSessionGeneration: Int?

    // MARK: - 数据状态

    var detail: MediaItem? {
        didSet {
            // 详情落地是「迟到补锁」的一个正式时点：列表带来的条目常常不带 backdrop
            // tag，解析那一刻因此算不出图、什么都没锁。详情一落地 tag 就有了，这里补锁。
            // 见 `lockBackdropTargetsIfNeeded()`。
            lockBackdropTargetsIfNeeded()
        }
    }
    var seasons: [MediaItem] = []
    /// 库内分集（服务端事实）。**占位永远不进这个数组**——它会流进播放、已看标记、
    /// 连播与详情快照，混进假条目就等于每一处都要再加一道「这是不是真的」判断。
    var episodes: [MediaItem] = [] {
        didSet { rebuildEpisodeSlots() }
    }
    /// 选集轨道（库内条目 + 库里没有的集的占位）。视图只渲染这个。
    ///
    /// 存成派生状态而不是计算属性：一千集的季每次 body 求值都重排一次是白费。
    private(set) var episodeSlots: [EpisodeSlot] = []
    /// 选集轨道的分区（默认每 30 集一段，见 `EpisodeChunker`）。
    ///
    /// 视图渲染分区条与当前段，而不是自己在 body 里切：与 `episodeSlots` 同一个理由——
    /// 一千集的季每次 body 求值都重切一遍是白费。它与 `episodeSlots` 恒由同一个出口
    /// （`rebuildEpisodeSlots`）一起重算，两者永远对同一份 slots 成立。
    private(set) var episodeChunks: [EpisodeChunk] = []
    /// 本次停留期间已经拉过的季 → 集列表。来回切季不重拉、不闪 loading。
    /// `load()`（换条目）时整体清空。
    var episodesBySeason: [String: [MediaItem]] = [:]
    /// 每季各自记住用户选中的那一集：切走再切回来选中项还在。
    var selectedEpisodeBySeason: [String: MediaItem.ID] = [:]
    var similar: [MediaItem] = []
    /// 合集成员（`/Items?parentId=<合集id>&recursive=false`）。只有合集才会去拉。
    ///
    /// 服务端本来就有这条能力（实测 Jellyfin 12.1.0：`parentId=<合集id>&recursive=false`
    /// 返回全部成员电影），此前 App **一次都没调用过** —— 于是「合集」在详情页里
    /// 只是一个空壳：没有成员列表，主按钮还会把合集自己的 id 送去协商播放。
    var collectionMembers: [MediaItem] = [] {
        didSet { lockBackdropTargetsIfNeeded() }
    }
    /// 服务端报的成员总数（合集可能大于一页）；nil = 还没拉到 / 服务端没给。
    private(set) var collectionMembersTotalCount: Int?
    var isLoadingMembers = false
    var membersLoadError: String?
    private var membersNextStartIndex = 0

    var selectedSeasonID: String?
    var selectedEpisodeID: MediaItem.ID?
    /// 横向选集箭头滚动的锚点（可与选中集不同：只滚列表不改选中）。
    var episodeScrollFocusID: MediaItem.ID?
    var isLoading = false
    var loadError: String?
    var isLoadingEpisodes = false
    var episodeLoadError: String?
    /// 播放退出后的静默刷新任务：离页时由视图取消。
    var reloadAfterPlaybackTask: Task<Void, Never>?
    /// 集列表取消后的静默补拉任务（见 `scheduleEpisodeReloadAfterCancellation`）。
    /// 真离页时由视图撤掉；被盖页不发 onDisappear（macOS 26 实测），被盖场景
    /// 补拉照跑——正是要救的场景。
    var episodeReloadTask: Task<Void, Never>?
    /// 补拉防风暴计数：同一轮访问最多补拉 2 次（成功 / 换季 / 重进页复位）。
    private(set) var episodeReloadAttemptCount = 0

    /// 正在展示的内容**没能**被网络确认（离线 / 服务端出错）。
    ///
    /// nil = 显示的是刚拉到的或本会话内的数据；非 nil = 刷新失败、页面内容是缓存。
    /// 详情页据此在简介下方摆一行「离线 · 数据更新于 X 前」。
    private(set) var staleNotice: StaleContentNotice?

    /// 当前展示内容的写入时间（仓储快照时间，用于「更新于 X 前」）。
    private var cachedContentFetchedAt: Date?
    /// 详情快照的会话内新鲜度。与仓储内存快照配合：磁盘来源一律视为需要网络确认。
    static let detailFreshness: TimeInterval = 5 * 60
    /// 合集成员上一页是否满页（总数未知时判断还能不能翻）。
    private var membersLastPageWasFull = false

    /// 本次访问的进页快照与已就绪条目图；视图只消费已解码像素。
    let backdropArtwork: DetailBackdropArtwork

    var shown: MediaItem { detail ?? item }

    /// 当前选中的季。视图与 TMDB 取数都用它（原先只在视图里算，两处需要同一份判断）。
    var selectedSeason: MediaItem? {
        seasons.first { $0.id == selectedSeasonID }
    }

    // MARK: - TMDB 补全

    /// 当前展示的 TMDB 叠加数据。nil = 没有（未配置 / 没匹配上 / 还没拉到）。
    ///
    /// 是**独立存储**而不是把 TMDB 字段写进 `detail`：服务端数据是「当前事实」，
    /// TMDB 是可选增强，混在一起后「关掉 TMDB」就得把改过的字段改回去——而那时
    /// 已经不知道原值了（见 `TMDbOverlay` 的类型注释）。
    private(set) var tmdbOverlay: TMDbOverlay? {
        didSet {
            // 后台补齐到 TMDB 图时的「迟到补锁」时点：解析那一刻本机没有 TMDB 缓存
            // 的话，这是唯一还能拿到最终那张的机会。同样是首次非空即锁、之后不改口。
            lockBackdropTargetsIfNeeded()
        }
    }

    /// 首帧背景图用的 overlay 是否已经读过（真/假决定 `backdropTarget` 能不能锁定）。
    ///
    /// 为什么需要这个标志：锁定必须发生在**解析完成之后**，否则详情还没落地时
    /// `shown` 是列表条目、`resolveBackdropTarget` 可能给出 nil 或服务端图，
    /// 早早锁死就永远看不到 TMDB 那张了。见 `backdropTarget(width:)`。
    var isBackdropSourceResolved: Bool { backdropLatch.isResolved }

    /// 「先解析、再上屏、之后锁定」的状态机（语义与实测来历见 `BackdropSourceLatch`）。
    ///
    /// `@ObservationIgnored`：它是**内部解析状态**，不是视图要观察的东西（视图要的是最终
    /// URL）。不标的话，任何写入都会被 `@Observable` 记成对象变更 —— 这正是 2026-11-03
    /// 详情页死循环的成因之一，见 `backdropTarget(width:)` 的说明。
    @ObservationIgnored
    private var backdropLatch = BackdropSourceLatch()

    /// 解析完成后首个非空来源；只由解析及数据落地时的锁定函数写入。
    /// `backdropTarget(width:)` 只读，不能在 SwiftUI body 求值时改状态。
    @ObservationIgnored
    private var lockedBackdropTargets: [Int: BackdropSourceLatch.Target] = [:]

    /// `backdropTarget` 会被视图按这些宽度档取值；解析时一次性全部锁好。
    private static let backdropWidthBuckets: [Int] = {
        var buckets: Set<Int> = [800, 1600]
        buckets.insert(DetailAmbienceImage.urlWidth)
        return buckets.sorted()
    }()

    /// 观测钩子：详情内容**落地上屏那一刻**（`applyDetailContent` 第一行）回调一次。
    ///
    /// 存在的唯一理由是给「先解析、再上屏」那条顺序断言一个观测点：`applyDetailContent`
    /// 是详情内容进入各展示状态的唯一入口（内存命中、磁盘命中、网络刷新三条分支都经过），
    /// 因此「它被调用的那一刻 `isBackdropSourceResolved` 已经是 true」才是顺序本身，
    /// 而不是「`resolveBackdropSource()` 被调用过」那种名不副实的断言（2026-11-03 review）。
    ///
    /// **默认 nil = 生产等价、零行为**。`@ObservationIgnored`：与 `backdropLatch` 同理，
    /// 挂观测钩子不该让视图因为「测试脚手架字段变了」而重算。
    @ObservationIgnored
    var onApplyDetailContent: (@MainActor () -> Void)?

    /// 当前**选中那一季**的 TMDB 叠加数据（含该季每一集的标题/简介）。
    ///
    /// 与 `tmdbOverlay`（剧集级）分开：两者来源不同（剧集级靠剧的对应、季靠
    /// `tv/{剧id}/season/{季号}`），生命周期也不同——切季就要换，而剧集级不动。
    private(set) var tmdbSeasonOverlay: TMDbOverlay? {
        didSet { rebuildEpisodeSlots() }
    }

    /// Bangumi 兜底候选（由 `BangumiChapterSection` 递上来，见 `acceptBangumiCandidates`）。
    ///
    /// **按季失效**：换季 / 重进页时清空（见 `selectSeason` 与 `load`），否则旧季的章节
    /// 会跟新季的季号拼在一起，算出错号的占位卡。
    private var bangumiCandidates: [EpisodeCandidate] = [] {
        didSet { rebuildEpisodeSlots() }
    }

    /// 叠加后的展示值。视图一律走这几个，不直接读 `shown`。
    ///
    /// 之所以全部收在 VM 里而不是视图各处自算：策略（文本优先 / 图片只补缺）是
    /// **可测逻辑**，摊进视图就没法用件测它了。
    var displayName: String {
        guard let tmdbOverlay else { return shown.name }
        // 合集的**名字是用户自己的标签**（他在 Jellyfin 里建合集时起的），不是作品的
        // 正式标题，所以不给 TMDB 顶替、只在服务端名为空时用 TMDB 补上。
        // 实测两者会不一样：Jellyfin「新世纪福音战士新剧场版（系列）」
        // vs TMDB「福音战士新剧场版（系列）」，顶替会让页面标题与侧栏/合集库对不上。
        let preferTMDb = shown.kind == .boxSet ? false : (app?.tmdb.preferText ?? true)
        return tmdbOverlay.displayTitle(serverValue: shown.name, preferTMDb: preferTMDb)
    }

    /// 页面简介。
    ///
    /// **选中某季时优先显示该季简介**（取不到再回落剧集简介）。用户实测指出：
    /// 切季之后简介一动不动，而 TMDB 的季简介就在手上。回落是必须的——
    /// 不少季在 TMDB 上没有简介，若直接替换会让整段文字凭空消失。
    var displayOverview: String? {
        let preferTMDb = app?.tmdb.preferText ?? true
        if let seasonOverview = seasonOverviewText(preferTMDb: preferTMDb) {
            return seasonOverview
        }
        guard let tmdbOverlay else { return shown.overview }
        return tmdbOverlay.displayOverview(serverValue: shown.overview, preferTMDb: preferTMDb)
    }

    /// 选中季的简介（TMDB 优先 / 服务端补缺）。nil = 该季没有任何简介可用。
    private func seasonOverviewText(preferTMDb: Bool) -> String? {
        guard let season = selectedSeason else { return nil }
        let server = season.overview
        if let overlay = tmdbSeasonOverlay {
            return overlay.displayOverview(serverValue: server, preferTMDb: preferTMDb)
        }
        guard let server, !server.isEmpty else { return nil }
        return server
    }

    // MARK: - 分集展示值（TMDB 优先）

    /// 分集标题。服务端那种「第 9 集」的占位名会被 TMDB 的真标题顶掉。
    func displayEpisodeTitle(_ episode: MediaItem) -> String {
        guard let overlay = tmdbSeasonOverlay, let number = episode.episodeNumber else {
            return episode.name
        }
        return overlay.displayEpisodeTitle(number: number, serverValue: episode.name,
                                           preferTMDb: app?.tmdb.preferText ?? true)
    }

    /// 分集简介（分集卡片拿它做 tooltip）。
    func displayEpisodeOverview(_ episode: MediaItem) -> String? {
        guard let overlay = tmdbSeasonOverlay, let number = episode.episodeNumber else {
            return episode.overview
        }
        return overlay.displayEpisodeOverview(number: number, serverValue: episode.overview,
                                              preferTMDb: app?.tmdb.preferText ?? true)
    }

    var displayGenres: [String] {
        guard let tmdbOverlay else { return shown.genres }
        return tmdbOverlay.displayGenres(serverValue: shown.genres,
                                         preferTMDb: app?.tmdb.preferText ?? true)
    }

    var displayRating: Double? {
        guard let tmdbOverlay else { return shown.communityRating }
        return tmdbOverlay.displayRating(serverValue: shown.communityRating,
                                         preferTMDb: app?.tmdb.preferText ?? true)
    }

    var displayCast: [MediaItem.Person] {
        guard let tmdbOverlay else { return shown.cast }
        return tmdbOverlay.displayCast(serverValue: shown.cast,
                                       preferTMDb: app?.tmdb.preferText ?? true)
    }

    /// 海报取图目标：服务端缺图（或用户允许顶替）时回落到 TMDB。
    ///
    /// 走 `MediaItem.imageTarget`（App 层既有的取图链）而不是自己拼 URL：
    /// 那条链已经处理了「哪张图、带不带 tag」这些 Jellyfin 侧的细节。
    func posterTarget(width: Int) -> (url: URL?, authHeader: String?) {
        let policy = app?.tmdbImagePolicy ?? TMDbImagePolicy()
        let serverTarget = shown.imageTarget(app?.server, kind: .primary, width: width)
        let url = DisplayMetadata.posterURL(serverURL: serverTarget.url, overlay: tmdbOverlay,
                                           requestedWidth: width, policy: policy)
        // TMDB 的图**免鉴权**：给它带服务端凭证既无意义、也把凭证多送一处。
        return (url, DisplayMetadata.isTMDbImage(url) ? nil : serverTarget.authHeader)
    }

    /// 演员头像取图目标。
    ///
    /// TMDB 补的演员**不能**用它的 `Person.id` 去问服务端要图：那个 id 在服务端不存在，
    /// 实测返回 400，于是每个演员一张破图 + 一次白打的请求（一页最多 20 个）。
    /// 这里优先走 TMDB CDN（免鉴权），取不到才回落到服务端的演员图。
    func castImageTarget(for person: MediaItem.Person, width: Int) -> (url: URL?, authHeader: String?) {
        if let path = tmdbOverlay?.profilePath(forPersonID: person.id),
           let url = TMDbImageSize.url(path: path, requestedWidth: width) {
            return (url, nil)
        }
        // 回落：服务端的演员图（服务端确实有这个演员 id 时才有效）。
        guard let server = app?.server,
              let url = try? server.imageURL(itemID: person.id, type: .primary,
                                             maxWidth: width, tag: nil)
        else { return (nil, nil) }
        return (url, server.authorizationHeader)
    }

    /// 分集剧照取图目标：**能用 TMDB 的 `still_path` 就用**。
    ///
    /// 服务端没有剧照时（新入库、刮削器没跑到）TMDB 能补上；而按当前默认策略
    /// （TMDB 优先）即便服务端有也以 TMDB 为准。回落链与服务端那条一致：
    /// 剧照 → 主图 → 占位（不用剧集海报，那会让人以为配错了集）。
    func episodeThumbTarget(for episode: MediaItem, width: Int) -> (url: URL?, authHeader: String?) {
        let serverTarget = episode.episodeThumbTarget(app?.server, width: width)
        let policy = app?.tmdbImagePolicy ?? TMDbImagePolicy()
        guard policy.replacesExisting || serverTarget.url == nil,
              let number = episode.episodeNumber,
              let path = tmdbSeasonOverlay?.episodeStillPath(number: number),
              let url = TMDbImageSize.url(path: path, requestedWidth: width)
        else { return serverTarget }
        // TMDB 的图**免鉴权**：给它带服务端凭证既无意义、也把凭证多送一处。
        return (url, nil)
    }

    /// 本次访问锁定的背景来源。先读本机 TMDB 缓存，再锁定第一张非空图；
    /// 后续详情、TMDB 或合集成员补齐可补锁空档，但不能替换已锁定来源。
    /// 此函数保持纯读取，图片加载和像素提交由 `backdropArtwork` 负责。
    func backdropTarget(width: Int) -> (url: URL?, authHeader: String?) {
        // 解析前不发出条目图；视图延续已冻结的入场快照。
        guard backdropLatch.isResolved else { return (nil, nil) }
        // 解析完成后读缓存；缓存未命中时**只算不写**。
        if let cached = lockedBackdropTargets[width] {
            return (cached.url, cached.authHeader)
        }
        return resolveBackdropTarget(width: width)
    }

    /// 真正的取图规则（未加锁定）。`backdropTarget` 是它的带锁定版本。
    private func resolveBackdropTarget(width: Int) -> (url: URL?, authHeader: String?) {
        let target = DetailBackdropSource.resolve(
            item: shown, server: app?.server, overlay: tmdbOverlay,
            policy: app?.tmdbImagePolicy ?? TMDbImagePolicy(), width: width
        )
        if target.url != nil { return (target.url, target.authHeader) }
        // 合集专用兜底：服务端与 TMDB 都没有背景图时，用**第一个成员的背景图**。
        // 合集本身在服务端就是没有图的容器（实测 `ImageTags: {}`），而它的成员是正常
        // 电影、海报背景一应俱全 —— jellyfin-web 对合集卡也是这么做的（拿子项的图顶上）。
        // 只在合集上生效：电影/剧集缺背景图时不该擅自拿别人的图。
        let fallback = collectionBackdropFallback(width: width)
        return (fallback.url, fallback.authHeader)
    }

    /// 在详情内容落地前读取本机 TMDB 缓存（无网络），随后开放来源锁定。
    /// 没有缓存时按图片策略使用服务端图；迟到的 TMDB 留给下次访问。
    /// 保持内部可见，供来源锁定与加载顺序测试直接驱动。
    func resolveBackdropSource() async {
        // 未 attach 也完成解析状态，避免来源永远悬而未决。
        if let app {
            tmdbOverlay = await app.tmdbOverlay(for: item)
        }
        backdropLatch.markResolved()
        lockBackdropTargetsIfNeeded()
    }

    /// 只在状态变更点补锁非空图，绝不放回视图求值路径。
    /// 已锁档位不覆盖；列表缺 tag、迟到详情和合集成员均遵守同一规则。
    private func lockBackdropTargetsIfNeeded() {
        guard backdropLatch.isResolved else { return }
        for width in Self.backdropWidthBuckets where lockedBackdropTargets[width] == nil {
            let resolved = resolveBackdropTarget(width: width)
            // 只锁非空：算不出图时留给下一个时点（详情落地 / TMDB 补齐）。
            guard resolved.url != nil else { continue }
            lockedBackdropTargets[width] = BackdropSourceLatch.Target(
                url: resolved.url, authHeader: resolved.authHeader, cacheScope: app?.server?.profile.imageCacheScope
            )
        }
    }

    /// 合集背景兜底：第一个**带背景图**的成员。非合集 / 没有这样的成员时返回 nil。
    private func collectionBackdropFallback(width: Int) -> (url: URL?, authHeader: String?) {
        guard shown.kind == .boxSet,
              let member = collectionMembers.first(where: { $0.backdropImageTag != nil })
        else { return (nil, nil) }
        return member.imageTarget(app?.server, kind: .backdrop, width: width)
    }

    /// 这个页面有没有可用的背景图（决定详情页走「氛围布局」还是「老横幅布局」）。
    ///
    /// 三个来源，任一成立即可：服务端背景图 tag、TMDB 叠加层的背景图、合集的成员兜底。
    /// **必须与 `backdropTarget` 判定一致**：早先视图只看 `shown.backdropImageTag`
    /// （服务端那个），于是「只有 TMDB 有背景图」的条目会走氛围布局却画不出图。
    var hasBackdrop: Bool {
        if shown.backdropImageTag != nil { return true }
        if let path = tmdbOverlay?.backdropPath, !path.isEmpty { return true }
        return collectionBackdropFallback(width: 800).url != nil
    }

    /// 占位卡的取图目标：TMDB 的 `still_path` 优先，没有时用**剧集自己的横版图**。
    ///
    /// 兜底刻意走 `homeStillImageTarget`（首页「继续观看」那条链：剧的 Thumb → Backdrop →
    /// Primary），而不是 `episodeThumbTarget` 那条「剧照 → 主图 → 占位」：后者对**真实分集**
    /// 是刻意的（拿父级图会像串了集），但占位卡本来就没有自己的图，用剧的横版图把格子填上
    /// 比一块灰底有用得多——这也是用户口径（「用他们自己的图片填坑，例如继续观看这里的图片」）。
    /// TMDB 的图免鉴权，所以 TMDB 分支不带服务端凭证；兜底分支要走服务端，凭证由它自己带。
    func placeholderThumbTarget(for placeholder: EpisodePlaceholder, width: Int)
        -> (url: URL?, authHeader: String?) {
        if let url = TMDbImageSize.url(path: placeholder.stillPath, requestedWidth: width) {
            return (url, nil)
        }
        return shown.homeStillImageTarget(app?.server, width: width)
    }

    init(item: MediaItem, backdropArtwork: DetailBackdropArtwork = DetailBackdropArtwork()) {
        self.item = item
        self.backdropArtwork = backdropArtwork
    }

    func attach(_ app: AppModel) {
        self.app = app
        attachedSessionGeneration = app.sessionGeneration
        let target = app.currentAmbienceTarget
        backdropArtwork.captureEntry(target: .init(url: target.url, authHeader: target.authHeader, cacheScope: app.server?.profile.imageCacheScope))
    }

    // MARK: - 选中

    /// 季选择器点选。
    ///
    /// 顺带把**按季**的两份数据清掉：季叠加层与 Bangumi 兜底候选都只对某一季成立。
    /// 不清的话，新季落地那一帧会拿旧季的候选去配新季号，闪出一批错号的占位卡。
    /// 清掉后轨道退回「只有本地集」（与换季前的观感一致），直到新季数据到位。
    func selectSeason(_ seasonID: String) {
        guard seasonID != selectedSeasonID else { return }
        selectedSeasonID = seasonID
        tmdbSeasonOverlay = nil
        bangumiCandidates = []
        // 换季 = 新一轮取数，补拉预算清零。
        episodeReloadAttemptCount = 0
    }

    /// 横向选集点选 / 点播共用：记下选中 + 滚动锚点 + 每季记忆。
    func selectEpisode(_ episode: MediaItem) {
        selectedEpisodeID = episode.id
        episodeScrollFocusID = episode.id
        if let seasonID = selectedSeasonID {
            selectedEpisodeBySeason[seasonID] = episode.id
        }
    }

    var selectedSeasonName: String {
        seasons.first(where: { $0.id == selectedSeasonID })?.name ?? "选择季"
    }

    // MARK: - 加载

    func load() async {
        guard let app, app.server != nil else { return }
        // 来源解析必须早于详情内容落地；后续数据变化仅补齐尚未锁定的来源。
        await resolveBackdropSource()
        // 来源解析完成后准备实际像素，内存命中时可直接提交。
        prepareBackdrop()

        // 重进页 = 新一轮访问，补拉预算清零。
        episodeReloadAttemptCount = 0
        // 兜底候选是**按季**的，且由 Bangumi 区块在出现时重新递上来。
        bangumiCandidates = []

        // stale-while-revalidate 的唯一缓存入口：仓储内存命中即渲染；磁盘来源
        // 也先渲染，但一律再走网络确认（`MediaSnapshot.isFresh` 对磁盘恒 false）。
        let cached = await app.metadata.cachedDetail(itemID: item.id)
        if let cached {
            applyDetailContent(cached.value)
            cachedContentFetchedAt = cached.fetchedAt
            if cached.isFresh(ttl: Self.detailFreshness) {
                isLoading = false
                loadError = nil
                staleNotice = nil
                await loadTMDbOverlay()
                await loadSeasonOverlay()
                return
            }
        } else {
            isLoading = true
            loadError = nil
            detail = nil
            seasons = []
            episodes = []
            episodesBySeason = [:]
            selectedEpisodeBySeason = [:]
            selectedSeasonID = nil
            selectedEpisodeID = nil
            episodeScrollFocusID = nil
            episodeLoadError = nil
            collectionMembers = []
            collectionMembersTotalCount = nil
            membersNextStartIndex = 0
            membersLoadError = nil
        }

        async let similarItems = (try? await app.metadata.similar(itemID: item.id, limit: 12)) ?? []
        var failure: (any Error)?
        do {
            let refreshed = try await app.metadata.refreshDetail(
                itemID: item.id, kindHint: item.kind)
            guard !Task.isCancelled, let refreshed else { return }
            applyDetailContent(refreshed.snapshot.value)
            cachedContentFetchedAt = refreshed.snapshot.fetchedAt
            if let seasonsFailure = refreshed.failures["seasons"] {
                failure = JellyfinError(.other(seasonsFailure.message))
                if cached == nil { loadError = seasonsFailure.message }
            }
            if let episodesFailure = refreshed.failures["episodes"], cached == nil {
                episodeLoadError = episodesFailure.message
            }
            if let membersFailure = refreshed.failures["members"] {
                membersLoadError = membersFailure.message
            }
            // 仓储默认准备第一季非特别篇；应用偏好可能选另一季，晚一步补上。
            if shown.kind == .series, let selectedSeasonID,
               selectedSeasonID != refreshed.snapshot.value.episodesSeasonID,
               episodesBySeason[selectedSeasonID] == nil {
                await loadEpisodes()
            }
            prepareBackdrop()
        } catch where JellyfinError.isCancellation(error) {
            // 取消不是错误，但加载态必须收尾（否则页面永远停在骨架屏）。
            isLoading = false
            return
        } catch let e as JellyfinError {
            failure = e
            if cached == nil { loadError = e.errorDescription }
        } catch {
            failure = error
            if cached == nil { loadError = "\(error)" }
        }
        isLoading = false
        similar = await similarItems
        if let failure, cached != nil {
            staleNotice = StaleContentNotice(
                fetchedAt: cachedContentFetchedAt,
                causedByConnectivity: (failure as? JellyfinError)?.isConnectivityFailure ?? false)
        } else {
            staleNotice = nil
        }

        await loadTMDbOverlay()
        await loadSeasonOverlay()
        await loadCollectionOverlay()
    }

    /// 仓储详情 → 各展示状态。内存与磁盘两条来源合流后的唯一落点。
    private func applyDetailContent(_ content: MediaDetailContent) {
        // 观测钩子必须在**第一行**：这一刻才是「内容即将上屏」，晚于任何状态写入都会
        // 让「上屏时已解析」这条顺序断言失去判别力（见 `onApplyDetailContent`）。
        if let onApplyDetailContent { onApplyDetailContent() }
        detail = content.item
        seasons = content.seasons
        collectionMembers = content.collectionMembers
        collectionMembersTotalCount = content.collectionMembersTotalCount
        membersNextStartIndex = content.collectionMembers.count
        prepareBackdrop()

        if let seasonID = content.episodesSeasonID, !content.episodes.isEmpty {
            episodesBySeason[seasonID] = content.episodes
        }
        let preferred = app?.preferredSeasonID(in: content.seasons, seriesID: content.item.id)
        if selectedSeasonID == nil || !(content.seasons.contains { $0.id == selectedSeasonID }) {
            selectedSeasonID = preferred ?? content.episodesSeasonID
        }
        guard let seasonID = selectedSeasonID else { return }
        if let cached = episodesBySeason[seasonID] {
            episodes = cached
            let restored = selectedEpisodeBySeason[seasonID]
                .flatMap { id in cached.contains { $0.id == id } ? id : nil }
                ?? app?.preferredEpisodeID(in: cached, seriesID: content.item.id)
            selectedEpisodeID = restored
            episodeScrollFocusID = restored
        } else {
            episodes = []
            selectedEpisodeID = nil
            episodeScrollFocusID = nil
        }
    }

    /// 「先读缓存立即渲染 → 后台补齐 → 真补到了再重读一次」：TMDB overlay 三条链共用。
    private func refreshOverlayThenReload<Overlay>(
        read: () async -> Overlay,
        refresh: () async -> Bool,
        apply: (Overlay) -> Void,
        onRefreshed: () -> Void = {}
    ) async {
        apply(await read())
        guard !Task.isCancelled else { return }
        let didFetch = await refresh()
        guard didFetch, !Task.isCancelled else { return }
        apply(await read())
        guard !Task.isCancelled else { return }
        onRefreshed()
    }

    /// 合集的 TMDB 数据：先读已有（立即渲染），再后台补，补到后重读一次。
    func loadCollectionOverlay() async {
        guard let app, shown.kind == .boxSet else { return }
        await refreshOverlayThenReload(
            read: { await app.tmdbOverlay(for: self.shown) },
            refresh: {
                await app.refreshTMDbCollection(for: self.shown, members: self.collectionMembers).didFetch
            },
            apply: { overlay in
                tmdbOverlay = overlay
                app.noteCollectionArtwork(itemID: shown.id, posterPath: overlay?.posterPath)
            },
            onRefreshed: { prepareBackdrop() }
        )
    }

    /// 合集成员：仓储恢复累计页，翻页只请求新窗口。
    func loadMembers(reset: Bool) async {
        guard let app, shown.kind == .boxSet else { return }
        if reset {
            isLoadingMembers = true
            membersLoadError = nil
        }
        defer { isLoadingMembers = false }

        if reset {
            // 详情刷新已经带回首屏成员：直接用仓储内存，不再重复请求。
            if let cached = await app.metadata.cachedCollectionMembers(itemID: shown.id),
               cached.source == .memory {
                applyMembersPage(cached.value)
                membersLoadError = nil
                return
            }
        }
        let startIndex = reset ? 0 : membersNextStartIndex
        do {
            let page = try await app.metadata.refreshCollectionMembers(
                itemID: shown.id, startIndex: startIndex)
            guard !Task.isCancelled else { return }
            if let page {
                applyMembersPage(page.value)
            }
            membersLoadError = nil
        } catch where JellyfinError.isCancellation(error) {
            return
        } catch let e as JellyfinError {
            membersLoadError = e.errorDescription
        } catch {
            membersLoadError = "\(error)"
        }
    }

    private func applyMembersPage(_ page: MediaPageContent) {
        collectionMembers = page.items
        collectionMembersTotalCount = page.totalCount
        membersNextStartIndex = page.nextStartIndex
        membersLastPageWasFull = page.lastPageWasFull
        prepareBackdrop()
    }

    /// 还有没拉完的成员：优先服务端总数；没有总数时按上一页是否满页判断。
    var hasMoreMembers: Bool {
        guard shown.kind == .boxSet else { return false }
        if let total = collectionMembersTotalCount {
            return collectionMembers.count < total
        }
        return membersLastPageWasFull
    }

    /// 读已有 TMDB 数据并触发后台补齐。失败/未配置一律静默。
    private func loadTMDbOverlay() async {
        guard let app else { return }
        await refreshOverlayThenReload(
            read: { await app.tmdbOverlay(for: self.shown) },
            refresh: { await app.refreshTMDb(for: self.shown) },
            apply: { self.tmdbOverlay = $0 },
            onRefreshed: { prepareBackdrop() }
        )
    }

    /// 单次加载后提交像素。来源锁定与像素就绪是两个阶段，不把 URL 当作图片已显示。
    private func prepareBackdrop() {
        let target = backdropTarget(width: DetailAmbienceImage.artURLWidth)
        let snapshot = lockedBackdropTargets[DetailAmbienceImage.artURLWidth]
            ?? .init(url: target.url, authHeader: target.authHeader, cacheScope: app?.server?.profile.imageCacheScope)
        backdropArtwork.prepare(target: snapshot)
    }

    /// 读当前选中季的 TMDB 数据（先读缓存立即渲染，再后台补）。
    ///
    /// 单独一个方法而不是塞进 `loadEpisodes()`：后者在「这一季已拉过」时会提前 return，
    /// 而季的 TMDB 数据那时同样需要——两件事的缓存粒度不同（集列表 vs 季元数据）。
    ///
    /// 失败/未配置一律静默：TMDB 是可选增强，任何问题都不该影响剧集页。
    func loadSeasonOverlay() async {
        guard let app, shown.kind == .series,
              let number = selectedSeason?.seasonNumber,
              let seriesLink = await app.tmdbSeriesLink(for: shown)
        else {
            tmdbSeasonOverlay = nil
            return
        }
        await refreshOverlayThenReload(
            read: { await app.tmdbSeasonOverlay(seriesLink: seriesLink, seasonNumber: number) },
            refresh: { await app.refreshTMDbSeason(seriesLink: seriesLink, seasonNumber: number) },
            apply: { self.tmdbSeasonOverlay = $0 }
        )
    }

    func loadEpisodes() async {
        guard let app, shown.kind == .series, let seasonID = selectedSeasonID else {
            episodes = []
            selectedEpisodeID = nil
            episodeScrollFocusID = nil
            isLoadingEpisodes = false
            episodeLoadError = nil
            return
        }
        // 这一季已经拉过：同步换上，不清空、不转圈、不发请求。
        if let cached = episodesBySeason[seasonID] {
            episodes = cached
            let restored = selectedEpisodeBySeason[seasonID]
                .flatMap { id in cached.contains { $0.id == id } ? id : nil }
                ?? app.preferredEpisodeID(in: cached, seriesID: shown.id)
            selectedEpisodeID = restored
            episodeScrollFocusID = restored
            isLoadingEpisodes = false
            episodeLoadError = nil
            episodeReloadAttemptCount = 0
            return
        }
        // 磁盘 / 内存投影先上屏；磁盘来源继续走网络确认。
        if let cached = await app.metadata.cachedEpisodes(seriesID: shown.id, seasonID: seasonID) {
            episodesBySeason[seasonID] = cached.value
            episodes = cached.value
            let restored = app.preferredEpisodeID(in: cached.value, seriesID: shown.id)
            selectedEpisodeID = restored
            episodeScrollFocusID = restored
            if cached.source == .memory {
                isLoadingEpisodes = false
                episodeLoadError = nil
                episodeReloadAttemptCount = 0
                return
            }
        } else {
            episodes = []
            selectedEpisodeID = nil
            episodeScrollFocusID = nil
        }
        isLoadingEpisodes = true
        episodeLoadError = nil
        defer {
            if selectedSeasonID == seasonID {
                isLoadingEpisodes = false
            }
        }
        do {
            guard let loaded = try await app.metadata.refreshEpisodes(
                seriesID: shown.id, seasonID: seasonID) else { return }
            guard !Task.isCancelled, selectedSeasonID == seasonID else { return }
            episodesBySeason[seasonID] = loaded
            episodes = loaded
            let preferred = app.preferredEpisodeID(in: loaded, seriesID: shown.id)
            selectedEpisodeID = preferred
            episodeScrollFocusID = preferred
            episodeLoadError = nil
            episodeReloadAttemptCount = 0
        } catch let e as JellyfinError {
            guard selectedSeasonID == seasonID else { return }
            episodeLoadError = e.errorDescription
        } catch where JellyfinError.isCancellation(error) {
            scheduleEpisodeReloadAfterCancellation(seasonID: seasonID)
        } catch {
            guard selectedSeasonID == seasonID else { return }
            episodeLoadError = "\(error)"
        }
    }

    /// 取消后的静默补拉：`.task` 被页面层取消后不会重启（macOS 26 实测，详情见
    /// 视图侧 `.task(id: selectedSeasonID)` 的注释），不补拉的话集列表那次访问
    /// 就永远空着。三道守卫——季没换、数据没到、没超上限；晚到的补拉也无害：
    /// `loadEpisodes` 读的是**当时**的选中季，已拉到则走缓存空转。
    private func scheduleEpisodeReloadAfterCancellation(seasonID: String) {
        guard selectedSeasonID == seasonID,
              episodesBySeason[seasonID] == nil,
              episodeReloadAttemptCount < 2 else { return }
        episodeReloadAttemptCount += 1
        episodeReloadTask?.cancel()
        episodeReloadTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await loadEpisodes()
        }
    }

    // MARK: - 占位（库里没有的集）

    /// 接收 Bangumi 章节兜底候选。
    ///
    /// 由 `BangumiChapterSection` 在读到本地章节后递上来（见那里的注释：区块今天已经在
    /// 读全量章节，复用它就不必在 VM 里再读一次库、也不必复刻 `bangumiEnabled` /
    /// 登录态 / 建库就绪三道闸门）。相同内容重复递上来时直接返回，避免白白触发一次
    /// 观察失效（区块在缓存与远端两条路径上都会递一次）。
    func acceptBangumiCandidates(_ candidates: [EpisodeCandidate]) {
        guard candidates != bangumiCandidates else { return }
        bangumiCandidates = candidates
    }

    /// 重算选集轨道与其分区。
    ///
    /// 三个输入各自 `didSet` 调用（本地集、季叠加层、兜底候选），所以「TMDB 数据晚到」
    /// 「切季」「播放后刷新」都不需要各自记得再算一次——少一处调用点就少一处漏算。
    /// 分区与轨道收在**同一个出口**重算：视图拿分区去切 `episodeSlots`，两者分开写
    /// 迟早会漂，漂一格就是「点了 31-60 却看到 1-30」。
    private func rebuildEpisodeSlots() {
        let slots: [EpisodeSlot]
        if app?.tmdb.showPlaceholders ?? true {
            slots = EpisodeSlotBuilder.build(
                seasonNumber: selectedSeason?.seasonNumber,
                local: episodes,
                primary: tmdbSeasonOverlay?.episodeCandidates ?? [],
                fallback: bangumiCandidates,
                now: Date())
        } else {
            // 关掉开关 = 退回加占位之前的行为（`episodes` 就是全部）。
            slots = episodes.map(EpisodeSlot.local)
        }
        episodeSlots = slots
        episodeChunks = EpisodeChunker.chunk(slots)
    }

    /// 播放退出/结束回传落库后静默刷新详情与选集（不重置骨架屏、不打断页面浏览）。
    func reloadAfterPlayback() async {
        guard let app else { return }
        if let loaded = try? await app.metadata.refreshItem(itemID: item.id) {
            detail = loaded
        }
        if shown.kind == .series, let seasonID = selectedSeasonID {
            if let loaded = try? await app.metadata.refreshEpisodes(
                seriesID: shown.id, seasonID: seasonID) {
                episodesBySeason[seasonID] = loaded
                episodes = loaded
                if let currentID = selectedEpisodeID,
                   loaded.contains(where: { $0.id == currentID }) {
                    // 保持选中集，其 playState 已由仓储写回最新值。
                } else {
                    let preferred = app.preferredEpisodeID(in: loaded, seriesID: shown.id)
                    selectedEpisodeID = preferred
                    episodeScrollFocusID = preferred
                }
            }
        }
    }

    /// 已看状态写回：先更新仓储（内存全部投影 + SQLite），再同步本页展示值。
    func applyPlayState(_ state: MediaItem.PlayState, toItemID id: MediaItem.ID, persistToRepository: Bool = true) async {
        let generation = attachedSessionGeneration
        if let app {
            guard generation == app.sessionGeneration else { return }
            if persistToRepository {
                let repository = await app.metadata.currentRepository()
                guard generation == app.sessionGeneration, generation == attachedSessionGeneration else { return }
                await repository?.applyPlayState(state, forItemID: id, persistToStore: true)
            }
            guard generation == app.sessionGeneration, generation == attachedSessionGeneration else { return }
        }
        if var current = detail, current.id == id {
            current.playState = state
            detail = current
        }
        if let index = episodes.firstIndex(where: { $0.id == id }) {
            episodes[index].playState = state
        }
        for (seasonID, cached) in episodesBySeason {
            guard let index = cached.firstIndex(where: { $0.id == id }) else { continue }
            episodesBySeason[seasonID]?[index].playState = state
        }
    }

}

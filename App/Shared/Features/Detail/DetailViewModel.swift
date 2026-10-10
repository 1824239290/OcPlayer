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

    // MARK: - 数据状态

    var detail: MediaItem?
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
    var collectionMembers: [MediaItem] = []
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

    /// 正在展示的内容**没能**被网络确认（离线 / 服务端出错）。
    ///
    /// nil = 显示的是刚拉到的或本会话内的数据；非 nil = 刷新失败、页面内容是缓存。
    /// 详情页据此在简介下方摆一行「离线 · 数据更新于 X 前」。
    private(set) var staleNotice: StaleContentNotice?

    /// 磁盘快照的写入时间（仅用于文案里的「更新于 X 前」）。
    private var cachedContentFetchedAt: Date?

    /// 哪些季的集来自磁盘（网络恢复后要重新拉，见 `loadFromDisk`）。
    private var diskHydratedSeasons: Set<String> = []

    /// 氛围底图（800 宽 backdrop + 512 解码）是否已进 pipeline 缓存。
    /// 视图只在就绪后才声明整窗/页内氛围——氛围层不再以灰占位淡入、
    /// 图片到位时也无需可见地补加载。取图失败保持 false（回退纯色底）。
    private(set) var isAmbienceReady = false
    private var ambiencePrewarmTask: Task<Void, Never>?
    private var prewarmedAmbienceURL: URL?

    var shown: MediaItem { detail ?? item }

    /// 当前选中的季。视图与 TMDb 取数都用它（原先只在视图里算，两处需要同一份判断）。
    var selectedSeason: MediaItem? {
        seasons.first { $0.id == selectedSeasonID }
    }

    // MARK: - TMDb 补全

    /// 当前展示的 TMDb 叠加数据。nil = 没有（未配置 / 没匹配上 / 还没拉到）。
    ///
    /// 是**独立存储**而不是把 TMDb 字段写进 `detail`：服务端数据是「当前事实」，
    /// TMDb 是可选增强，混在一起后「关掉 TMDb」就得把改过的字段改回去——而那时
    /// 已经不知道原值了（见 `TMDbOverlay` 的类型注释）。
    private(set) var tmdbOverlay: TMDbOverlay?

    /// 当前**选中那一季**的 TMDb 叠加数据（含该季每一集的标题/简介）。
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
        // 正式标题，所以不给 TMDb 顶替、只在服务端名为空时用 TMDb 补上。
        // 实测两者会不一样：Jellyfin「新世纪福音战士新剧场版（系列）」
        // vs TMDb「福音战士新剧场版（系列）」，顶替会让页面标题与侧栏/合集库对不上。
        let preferTMDb = shown.kind == .boxSet ? false : (app?.tmdb.preferText ?? true)
        return tmdbOverlay.displayTitle(serverValue: shown.name, preferTMDb: preferTMDb)
    }

    /// 页面简介。
    ///
    /// **选中某季时优先显示该季简介**（取不到再回落剧集简介）。用户实测指出：
    /// 切季之后简介一动不动，而 TMDb 的季简介就在手上。回落是必须的——
    /// 不少季在 TMDb 上没有简介，若直接替换会让整段文字凭空消失。
    var displayOverview: String? {
        let preferTMDb = app?.tmdb.preferText ?? true
        if let seasonOverview = seasonOverviewText(preferTMDb: preferTMDb) {
            return seasonOverview
        }
        guard let tmdbOverlay else { return shown.overview }
        return tmdbOverlay.displayOverview(serverValue: shown.overview, preferTMDb: preferTMDb)
    }

    /// 选中季的简介（TMDb 优先 / 服务端补缺）。nil = 该季没有任何简介可用。
    private func seasonOverviewText(preferTMDb: Bool) -> String? {
        guard let season = selectedSeason else { return nil }
        let server = season.overview
        if let overlay = tmdbSeasonOverlay {
            return overlay.displayOverview(serverValue: server, preferTMDb: preferTMDb)
        }
        guard let server, !server.isEmpty else { return nil }
        return server
    }

    // MARK: - 分集展示值（TMDb 优先）

    /// 分集标题。服务端那种「第 9 集」的占位名会被 TMDb 的真标题顶掉。
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

    /// 海报取图目标：服务端缺图（或用户允许顶替）时回落到 TMDb。
    ///
    /// 走 `MediaItem.imageTarget`（App 层既有的取图链）而不是自己拼 URL：
    /// 那条链已经处理了「哪张图、带不带 tag」这些 Jellyfin 侧的细节。
    func posterTarget(width: Int) -> (url: URL?, authHeader: String?) {
        let policy = app?.tmdbImagePolicy ?? TMDbImagePolicy()
        let serverTarget = shown.imageTarget(app?.server, kind: .primary, width: width)
        let url = DisplayMetadata.posterURL(serverURL: serverTarget.url, overlay: tmdbOverlay,
                                           requestedWidth: width, policy: policy)
        // TMDb 的图**免鉴权**：给它带服务端凭证既无意义、也把凭证多送一处。
        return (url, DisplayMetadata.isTMDbImage(url) ? nil : serverTarget.authHeader)
    }

    /// 演员头像取图目标。
    ///
    /// TMDb 补的演员**不能**用它的 `Person.id` 去问服务端要图：那个 id 在服务端不存在，
    /// 实测返回 400，于是每个演员一张破图 + 一次白打的请求（一页最多 20 个）。
    /// 这里优先走 TMDb CDN（免鉴权），取不到才回落到服务端的演员图。
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

    /// 分集剧照取图目标：**能用 TMDb 的 `still_path` 就用**。
    ///
    /// 服务端没有剧照时（新入库、刮削器没跑到）TMDb 能补上；而按当前默认策略
    /// （TMDb 优先）即便服务端有也以 TMDb 为准。回落链与服务端那条一致：
    /// 剧照 → 主图 → 占位（不用剧集海报，那会让人以为配错了集）。
    func episodeThumbTarget(for episode: MediaItem, width: Int) -> (url: URL?, authHeader: String?) {
        let serverTarget = episode.episodeThumbTarget(app?.server, width: width)
        let policy = app?.tmdbImagePolicy ?? TMDbImagePolicy()
        guard policy.replacesExisting || serverTarget.url == nil,
              let number = episode.episodeNumber,
              let path = tmdbSeasonOverlay?.episodeStillPath(number: number),
              let url = TMDbImageSize.url(path: path, requestedWidth: width)
        else { return serverTarget }
        // TMDb 的图**免鉴权**：给它带服务端凭证既无意义、也把凭证多送一处。
        return (url, nil)
    }

    /// 背景（氛围）取图目标，规则同上。
    func backdropTarget(width: Int) -> (url: URL?, authHeader: String?) {
        let policy = app?.tmdbImagePolicy ?? TMDbImagePolicy()
        let serverTarget = shown.imageTarget(app?.server, kind: .backdrop, width: width)
        let url = DisplayMetadata.backdropURL(serverURL: serverTarget.url, overlay: tmdbOverlay,
                                             requestedWidth: width, policy: policy)
        if let url {
            return (url, DisplayMetadata.isTMDbImage(url) ? nil : serverTarget.authHeader)
        }
        // 合集专用兜底：服务端与 TMDb 都没有背景图时，用**第一个成员的背景图**。
        // 合集本身在服务端就是没有图的容器（实测 `ImageTags: {}`），而它的成员是正常
        // 电影、海报背景一应俱全 —— jellyfin-web 对合集卡也是这么做的（拿子项的图顶上）。
        // 只在合集上生效：电影/剧集缺背景图时不该擅自拿别人的图。
        let fallback = collectionBackdropFallback(width: width)
        return (fallback.url, fallback.authHeader)
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
    /// 三个来源，任一成立即可：服务端背景图 tag、TMDb 叠加层的背景图、合集的成员兜底。
    /// **必须与 `backdropTarget` 判定一致**：早先视图只看 `shown.backdropImageTag`
    /// （服务端那个），于是「只有 TMDb 有背景图」的条目会走氛围布局却画不出图。
    var hasBackdrop: Bool {
        if shown.backdropImageTag != nil { return true }
        if let path = tmdbOverlay?.backdropPath, !path.isEmpty { return true }
        return collectionBackdropFallback(width: 800).url != nil
    }

    /// 占位卡的取图目标：TMDb 的 `still_path` 优先，没有时用**剧集自己的横版图**。
    ///
    /// 兜底刻意走 `homeStillImageTarget`（首页「继续观看」那条链：剧的 Thumb → Backdrop →
    /// Primary），而不是 `episodeThumbTarget` 那条「剧照 → 主图 → 占位」：后者对**真实分集**
    /// 是刻意的（拿父级图会像串了集），但占位卡本来就没有自己的图，用剧的横版图把格子填上
    /// 比一块灰底有用得多——这也是用户口径（「用他们自己的图片填坑，例如继续观看这里的图片」）。
    /// TMDb 的图免鉴权，所以 TMDb 分支不带服务端凭证；兜底分支要走服务端，凭证由它自己带。
    func placeholderThumbTarget(for placeholder: EpisodePlaceholder, width: Int)
        -> (url: URL?, authHeader: String?) {
        if let url = TMDbImageSize.url(path: placeholder.stillPath, requestedWidth: width) {
            return (url, nil)
        }
        return shown.homeStillImageTarget(app?.server, width: width)
    }

    init(item: MediaItem) {
        self.item = item
    }

    func attach(_ app: AppModel) {
        self.app = app
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
        guard let app, let server = app.server else { return }
        prewarmAmbience()
        // 兜底候选是**按季**的，且由 Bangumi 区块在出现时重新递上来。这里先清空，
        // 免得重新进页时用上一轮（可能是另一季）的章节算出错号的占位卡。
        bangumiCandidates = []
        // stale-while-revalidate：有快照先原位渲染（不置 nil、不闪骨架屏），
        // 重拉成功后原位覆盖；失败则静默保留快照内容（SWR 语义，错误条只服务首拉）。
        var snapshot = app.detailSnapshot(for: item.id)
        // 内存里没有（冷启动 / 首次进这条）就下探磁盘：离线时这是唯一的内容来源。
        // 放在内存快照之后、网络之前——顺序即优先级：内存最新 → 磁盘次之 → 网络。
        if snapshot == nil, let cached = await loadFromDisk(server: server) {
            snapshot = cached
        }
        if let snapshot {
            detail = snapshot.detail
            seasons = snapshot.seasons
            similar = snapshot.similar
            selectedSeasonID = snapshot.selectedSeasonID
            episodesBySeason = snapshot.episodesBySeason
            // 合集成员也走快照：再次进入同一合集先出内容，网络回来原位覆盖。
            collectionMembers = snapshot.collectionMembers
            if let seasonID = snapshot.selectedSeasonID,
               let cached = snapshot.episodesBySeason[seasonID] {
                episodes = cached
                let restored = selectedEpisodeBySeason[seasonID]
                    .flatMap { id in cached.contains { $0.id == id } ? id : nil }
                    ?? preferredEpisodeID(in: cached, seriesID: snapshot.detail.id)
                selectedEpisodeID = restored
                episodeScrollFocusID = restored
            }
        }

        isLoading = snapshot == nil
        if snapshot == nil {
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

        // Similar recommendations are optional and may be unavailable on
        // servers with that endpoint disabled. Keep the required detail path
        // independent so a recommendation failure cannot blank the page.
        async let similarItems = server.similar(itemID: item.id, limit: 12)
        var failure: (any Error)?
        do {
            let loadedDetail = try await server.item(item.id)
            guard !Task.isCancelled else { return }
            detail = loadedDetail
            // 完整详情的图 tag 可能与列表页快照不同：换图重预热（同 URL 时直接命中短路）。
            prewarmAmbience()

            if loadedDetail.kind == .series {
                do {
                    let loadedSeasons = try await server.seasons(seriesID: item.id)
                    guard !Task.isCancelled else { return }
                    seasons = loadedSeasons
                    selectedSeasonID = preferredSeasonID(in: loadedSeasons, seriesID: loadedDetail.id)
                    // 元数据已确认是新的：把来自磁盘的季集缓存作废，让 `loadEpisodes`
                    // 重新拉一次。不清的话，几天前拉的集列表会一直显示到用户手动切季。
                    for seasonID in diskHydratedSeasons {
                        episodesBySeason[seasonID] = nil
                    }
                    diskHydratedSeasons = []
                } catch let e as JellyfinError {
                    failure = e
                    if snapshot == nil { loadError = e.errorDescription }
                } catch {
                    failure = error
                    if snapshot == nil { loadError = "\(error)" }
                }
            }
        } catch let e as JellyfinError {
            failure = e
            if snapshot == nil { loadError = e.errorDescription }
        } catch {
            failure = error
            if snapshot == nil { loadError = "\(error)" }
        }
        isLoading = false
        similar = (try? await similarItems) ?? similar
        // 合集成员：与详情/季同一条「网络为准」的路径，失败**不**影响整页
        // （合集照样能展示标题与成员以外的信息，成员区自己出错误条 + 重试）。
        // 放在 `storeSnapshot()` 之前，快照才带得上第一页成员。
        if shown.kind == .boxSet {
            await loadMembers(reset: true)
        }
        // 有内容 + 刷新失败 = 正在展示缓存。没内容时（snapshot == nil）走的是既有的
        // 整页错误态，不该再叠一条提示。
        if let failure, snapshot != nil {
            staleNotice = StaleContentNotice(
                fetchedAt: cachedContentFetchedAt,
                causedByConnectivity: (failure as? JellyfinError)?.isConnectivityFailure ?? false)
        } else {
            staleNotice = nil
        }
        storeSnapshot()

        // TMDb 补全：**放在所有服务端路径之后**，且不 await 网络——
        // 它在后台补齐，补到后只更新 overlay、不动服务端数据。
        //
        // 顺序讲究：先读已有 overlay（立即渲染），再触发 refresh。若先 refresh
        // 再读，离线或慢网络下详情页会白等一次网络才有 TMDb 数据。
        await loadTMDbOverlay()
        // 季数据**必须在这里触发**，不能只靠视图上的 `.task(id: selectedSeasonID)`：
        // 实测那个 task 只在页面初现时跑了一次，而那一刻 `seasons` 还是空的
        // （诊断日志：与 `/Seasons` 请求同一秒，`selectedSeason` 为 nil），
        // 之后 id 变化并没有再触发它。放在这里则 `seasons` 与 `selectedSeasonID`
        // 都已就位，且**晚于 `loadTMDbOverlay`**——季数据要靠父剧的对应来定位，
        // 而那条对应正是上一步刚建起来的。
        await loadSeasonOverlay()
        // 合集：**必须晚于 `loadMembers`**（成员是它定位 TMDb 合集的输入，
        // 见 `TMDbEnricher.refreshCollection`），也晚于 `loadTMDbOverlay`（先读后补）。
        await loadCollectionOverlay()
    }

    /// 合集的 TMDb 数据：先读已有（立即渲染），再后台补，补到后重读一次。
    ///
    /// 与 `loadSeasonOverlay` 同构，区别是定位靠**成员**：合集在服务端没有可用的
    /// `ProviderIds["Tmdb"]`，TMDb 合集 id 是从成员电影的 `belongs_to_collection`
    /// 反查出来的。所以成员还没加载出来时（离线首进、成员请求失败）本方法什么都不做，
    /// 页面退回「服务端图 + 成员背景兜底」，不会卡在任何等待上。
    func loadCollectionOverlay() async {
        guard let app, shown.kind == .boxSet else { return }
        // ① 立即用已有数据渲染（缓存命中时同步就绪）。
        tmdbOverlay = await app.tmdbOverlay(for: shown)
        // 顺手把海报路径递给网格卡：这样「先点开详情、再回合集库」这一趟是零请求的，
        // 卡片不用自己再解析一遍（见 `AppModel.collectionArtwork`）。
        app.noteCollectionArtwork(itemID: shown.id, posterPath: tmdbOverlay?.posterPath)
        guard !Task.isCancelled else { return }

        // ② 缺数据或已过期时后台补，补到再刷新一次。
        // 用 `.didFetch`（只有真的落库了新数据才重读）——`RefreshOutcome` 的其余三种
        // 结局（命中缓存 / TMDb 上没有 / 请求失败）都不需要再读一次库。
        let outcome = await app.refreshTMDbCollection(for: shown, members: collectionMembers)
        guard outcome.didFetch, !Task.isCancelled else { return }
        let refreshed = await app.tmdbOverlay(for: shown)
        guard !Task.isCancelled else { return }
        tmdbOverlay = refreshed
        app.noteCollectionArtwork(itemID: shown.id, posterPath: refreshed?.posterPath)
        // 背景图可能刚从「无」变成 TMDb 那张：重预热（同 URL 时直接命中短路）。
        prewarmAmbience()
    }

    /// 合集成员。
    ///
    /// 查询形态用 `MediaServer.collectionMembers(of:)`——**三条硬约束（`recursive: false`、
    /// 不传 `includeItemTypes`、年份升序）与它们的服务端依据都收在那一个方法里**，
    /// 库网格卡的封面解析走的是同一个方法；这里再写一份就是下一个漂移点。
    /// 本方法只额外负责**分页**（一页 200 条，`totalRecordCount` 大于已加载数才给
    /// 「加载更多」）。结果会被 `CachedMediaServer` 写进条目表与页缓存，不需要另加缓存路径。
    func loadMembers(reset: Bool) async {
        guard let server = app?.server, shown.kind == .boxSet else { return }
        if reset {
            isLoadingMembers = true
            membersLoadError = nil
        }
        defer { isLoadingMembers = false }

        let startIndex = reset ? 0 : membersNextStartIndex
        do {
            let page = try await server.collectionMembers(of: shown.id, startIndex: startIndex)
            guard !Task.isCancelled else { return }
            if reset {
                collectionMembers = page.items
            } else {
                // 防御服务端重复页：按 id 去重追加（与库页翻页同一口径）。
                var existing = Set(collectionMembers.map(\.id))
                collectionMembers += page.items.filter { existing.insert($0.id).inserted }
            }
            collectionMembersTotalCount = page.totalRecordCount
            membersNextStartIndex = startIndex + page.items.count
            membersLoadError = nil
            storeSnapshot()
            // 成员到位可能**第一次**让合集有背景图（TMDb 没对应时用第一个成员的图，
            // 见 `collectionBackdropFallback`）。`load()` 里那两次预热都排在成员加载之前，
            // 赶不上这一档，所以这里补一次（同 URL 会直接短路，不会重复解码）。
            if reset { prewarmAmbience() }
        } catch is CancellationError {
            return
        } catch let e as JellyfinError {
            membersLoadError = e.errorDescription
        } catch {
            membersLoadError = "\(error)"
        }
    }

    /// 还有没拉完的成员（服务端给了总数且大于已加载数）。
    var hasMoreMembers: Bool {
        guard shown.kind == .boxSet else { return false }
        guard let total = collectionMembersTotalCount else { return false }
        return collectionMembers.count < total
    }

    /// 读已有 TMDb 数据并触发后台补齐。
    ///
    /// 失败/未配置一律静默：TMDb 是可选增强，任何问题都不该影响详情页。
    private func loadTMDbOverlay() async {
        guard let app else { return }
        // 立即用已有数据渲染（缓存命中时这里是同步就绪的）。
        let existing = await app.tmdbOverlay(for: shown)
        guard !Task.isCancelled else { return }
        tmdbOverlay = existing

        // 再补：缺数据或已过期时发网络。等它完成后刷新一次 overlay。
        let didFetch = await app.refreshTMDb(for: shown)
        guard didFetch, !Task.isCancelled else { return }
        let refreshed = await app.tmdbOverlay(for: shown)
        guard !Task.isCancelled else { return }
        tmdbOverlay = refreshed
        // overlay 变了 → 背景图可能从「服务端没有 → 用 TMDb」变成另一个 URL，
        // 重新预热一次氛围层（URL 未变时 `prewarmedAmbienceURL` 会直接短路）。
        prewarmAmbience()
    }

    /// 从磁盘缓存装载详情（冷启动 / 离线时的内容来源）。
    ///
    /// 返回 `AppModel.DetailSnapshot` 而不是包里的类型：后面的渲染路径只认这一种
    /// 快照，内存与磁盘两条来源在 `load()` 里就合流了，调用方不必区分。
    ///
    /// 同时记下**哪些季的集来自磁盘**（`diskHydratedSeasons`）：那些集可能是几天前
    /// 拉的，网络恢复后要重新拉一次。不记的话，`loadEpisodes` 会因为
    /// `episodesBySeason` 已有内容而永远不刷新它们。
    private func loadFromDisk(server: any MediaServer) async -> AppModel.DetailSnapshot? {
        guard let hydrator = app?.metadata.hydrator(for: server) else { return nil }
        guard let cached = await hydrator.detail(itemID: item.id) else { return nil }

        diskHydratedSeasons = Set([cached.seasons.first?.id].compactMap { $0 })
        let preferred = cached.seasons.first { $0.seasonNumber != 0 }?.id ?? cached.seasons.first?.id
        var episodesBySeason: [String: [MediaItem]] = [:]
        if let preferred {
            episodesBySeason[preferred] = cached.episodes
        }
        // 离线标识：这是磁盘内容，网络还没确认过。真正决定「显示离线提示」的
        // 是**网络刷新失败**（见下方 catch），这里只记下它的时间供文案用。
        cachedContentFetchedAt = cached.fetchedAt

        return AppModel.DetailSnapshot(
            detail: cached.item,
            seasons: cached.seasons,
            // 推荐不缓存（每次不同、价值低），保持内存里的旧值。
            similar: similar,
            selectedSeasonID: preferred,
            episodesBySeason: episodesBySeason)
    }

    /// 预热当前条目的氛围底图：与 `BackdropAmbienceView` / 整窗层完全同参
    /// （800 宽 URL + 512 解码），保证视图层的 `RemoteImage` 首帧命中缓存。
    /// 同一 URL 只预热一次；换条目 / 详情落地换 tag 时重跑。
    private func prewarmAmbience() {
        guard app?.server != nil else { return }
        // 走 `backdropTarget` 而不是裸 `imageTarget`：前者在服务端缺背景图时会回落到
        // TMDb（TMDb 只补缺）。否则「服务端没有背景图」的条目永远没有氛围层。
        let target = backdropTarget(width: 800)
        guard let url = target.url else { return }
        guard url != prewarmedAmbienceURL else { return }
        prewarmedAmbienceURL = url
        let authHeader = target.authHeader
        ambiencePrewarmTask?.cancel()
        ambiencePrewarmTask = Task {
            if ImagePipeline.shared.memoryCachedImage(url: url, authHeader: authHeader, maxPixelSize: 512) != nil {
                isAmbienceReady = true
                return
            }
            let loaded = try? await ImagePipeline.shared.load(url, authHeader: authHeader, maxPixelSize: 512)
            guard !Task.isCancelled else { return }
            isAmbienceReady = (loaded != nil)
        }
    }

    /// 读当前选中季的 TMDb 数据（先读缓存立即渲染，再后台补）。
    ///
    /// 单独一个方法而不是塞进 `loadEpisodes()`：后者在「这一季已拉过」时会提前 return，
    /// 而季的 TMDb 数据那时同样需要——两件事的缓存粒度不同（集列表 vs 季元数据）。
    ///
    /// 失败/未配置一律静默：TMDb 是可选增强，任何问题都不该影响剧集页。
    func loadSeasonOverlay() async {
        guard let app, shown.kind == .series,
              let number = selectedSeason?.seasonNumber,
              let seriesLink = await app.tmdbSeriesLink(for: shown)
        else {
            tmdbSeasonOverlay = nil
            return
        }
        // ① 立即用已有数据渲染（缓存命中时同步就绪）。
        tmdbSeasonOverlay = await app.tmdbSeasonOverlay(seriesLink: seriesLink,
                                                       seasonNumber: number)
        guard !Task.isCancelled else { return }

        // ② 缺数据或已过期时后台补，补到再刷新一次。
        let didFetch = await app.refreshTMDbSeason(seriesLink: seriesLink, seasonNumber: number)
        guard didFetch, !Task.isCancelled else { return }
        let refreshed = await app.tmdbSeasonOverlay(seriesLink: seriesLink, seasonNumber: number)
        guard !Task.isCancelled else { return }
        tmdbSeasonOverlay = refreshed
    }

    func loadEpisodes() async {
        guard let server = app?.server, shown.kind == .series, let seasonID = selectedSeasonID else {
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
                ?? preferredEpisodeID(in: cached, seriesID: shown.id)
            selectedEpisodeID = restored
            episodeScrollFocusID = restored
            isLoadingEpisodes = false
            episodeLoadError = nil
            return
        }
        episodes = []
        selectedEpisodeID = nil
        episodeScrollFocusID = nil
        isLoadingEpisodes = true
        episodeLoadError = nil
        defer {
            if selectedSeasonID == seasonID {
                isLoadingEpisodes = false
            }
        }
        do {
            let loaded = try await server.episodes(seriesID: shown.id, seasonID: seasonID)
            guard !Task.isCancelled, selectedSeasonID == seasonID else { return }
            episodesBySeason[seasonID] = loaded
            episodes = loaded
            let preferred = preferredEpisodeID(in: loaded, seriesID: shown.id)
            selectedEpisodeID = preferred
            episodeScrollFocusID = preferred
            storeSnapshot()
        } catch let e as JellyfinError {
            guard selectedSeasonID == seasonID else { return }
            episodeLoadError = e.errorDescription
        } catch is CancellationError {
            // 切季/离页的取消不是错误，别闪错误条。
            return
        } catch {
            guard selectedSeasonID == seasonID else { return }
            episodeLoadError = "\(error)"
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

    /// 重算选集轨道。
    ///
    /// 三个输入各自 `didSet` 调用（本地集、季叠加层、兜底候选），所以「TMDb 数据晚到」
    /// 「切季」「播放后刷新」都不需要各自记得再算一次——少一处调用点就少一处漏算。
    private func rebuildEpisodeSlots() {
        // 关掉开关 = 退回加占位之前的行为（`episodes` 就是全部）。
        guard app?.tmdb.showPlaceholders ?? true else {
            episodeSlots = episodes.map(EpisodeSlot.local)
            return
        }
        episodeSlots = EpisodeSlotBuilder.build(
            seasonNumber: selectedSeason?.seasonNumber,
            local: episodes,
            primary: tmdbSeasonOverlay?.episodeCandidates ?? [],
            fallback: bangumiCandidates,
            now: Date())
    }

    /// 播放退出/结束回传落库后静默刷新详情与选集（不重置骨架屏、不打断页面浏览）。
    func reloadAfterPlayback() async {
        guard let server = app?.server else { return }
        if let loaded = try? await server.item(item.id) {
            detail = loaded
        }
        if shown.kind == .series {
            // 只回填当前季：其他季的缓存不包含本次播放的那一集，清空整份
            // episodesBySeason 只会让切季时白拉一遍、闪一下 loading。
            if let seasonID = selectedSeasonID {
                if let loaded = try? await server.episodes(seriesID: shown.id, seasonID: seasonID) {
                    episodesBySeason[seasonID] = loaded
                    episodes = loaded
                    if let currentID = selectedEpisodeID, loaded.contains(where: { $0.id == currentID }) {
                        // 保持选中集，其 playState 已经更新为最新的
                    } else {
                        let preferred = preferredEpisodeID(in: loaded, seriesID: shown.id)
                        selectedEpisodeID = preferred
                        episodeScrollFocusID = preferred
                    }
                }
            }
        }
        storeSnapshot()
    }

    /// 写回某条的已看状态：详情 + 当前选集 + 每季缓存三处同步，
    /// 缓存不改的话切走再切回来「已看过」的勾又变回去。
    func applyPlayState(_ state: MediaItem.PlayState, toItemID id: MediaItem.ID) {
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
        storeSnapshot()
    }

    /// 把当前内容写进跨进入快照（SWR 的「stale」来源）。
    private func storeSnapshot() {
        guard let app, let detail else { return }
        app.storeDetailSnapshot(
            .init(detail: detail, seasons: seasons, similar: similar,
                  selectedSeasonID: selectedSeasonID, episodesBySeason: episodesBySeason,
                  collectionMembers: collectionMembers),
            for: item.id)
    }

    // MARK: - 智能默认季 / 集

    /// 首页续播 / 下一集线索：用于默认季与默认选中集。
    private func preferredEpisodeHint(seriesID: MediaItem.ID) -> MediaItem? {
        guard let app else { return nil }
        if let resume = app.home.resume.first(where: {
            $0.seriesID == seriesID
                && !($0.playState?.played ?? false)
                && ($0.playState?.positionSeconds ?? 0) >= 30
        }) {
            return resume
        }
        return app.home.nextUp.first(where: { $0.seriesID == seriesID })
    }

    /// 默认季：有续播/下一集进度的季优先；否则第一部有未看完的常规季（跳过 SP/特典）；
    /// 再否则第一部常规季；最后才落到任意季（含仅有 SP 的片）。
    private func preferredSeasonID(in seasons: [MediaItem], seriesID: MediaItem.ID) -> String? {
        guard !seasons.isEmpty else { return nil }

        if let hint = preferredEpisodeHint(seriesID: seriesID) {
            if let sn = hint.seasonNumber,
               let byNumber = seasons.first(where: { $0.seasonNumber == sn }) {
                return byNumber.id
            }
        }

        let regular = seasons.filter { !isSpecialsSeason($0) }
        let pool = regular.isEmpty ? seasons : regular

        if let unwatched = pool.first(where: { ($0.playState?.unplayedCount ?? 0) > 0 }) {
            return unwatched.id
        }
        return pool.first?.id ?? seasons.first?.id
    }

    /// 特典/SP 季：季号 0，或名称像 Specials / 特别篇 / SP（避免默认一进详情就停在 SP）。
    private func isSpecialsSeason(_ season: MediaItem) -> Bool {
        if let number = season.seasonNumber, number == 0 { return true }
        let name = season.name.lowercased()
        if name.contains("special") { return true }
        if name.contains("特别") || name.contains("特典") || name.contains("番外") { return true }
        let compact = name.filter { !$0.isWhitespace }
        if compact == "sp" || compact.hasPrefix("sp") && compact.count <= 4 { return true }
        return false
    }

    /// 当前季列表内的默认选中集：续播 → nextUp → 第一集未看完 → 第一集。
    private func preferredEpisodeID(in episodes: [MediaItem], seriesID: MediaItem.ID) -> MediaItem.ID? {
        guard !episodes.isEmpty else { return nil }

        if let hint = preferredEpisodeHint(seriesID: seriesID),
           episodes.contains(where: { $0.id == hint.id }) {
            return hint.id
        }

        return episodes.first(where: { !($0.playState?.played ?? false) })?.id
            ?? episodes.first?.id
    }
}

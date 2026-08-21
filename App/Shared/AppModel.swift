import BangumiKit
import CoreModel
import DanmakuKit
import DiagnosticsKit
import Foundation
import JellyfinKit
import Observation

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
/// UI 只读这个类的属性、调它的方法；Jellyfin 细节被挡在 `JellyfinServer` 后面，
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
    var server: JellyfinServer?

    /// Every authenticated session gets a new generation. Async responses keep
    /// their generation and may only mutate state while it is still current.
    var sessionGeneration = 0
    var initialDataTask: Task<Void, Never>?

    // MARK: - Onboarding 中间态

    /// `startLogin` 成功后非 nil（已探明这是台 Jellyfin，等用户选登录方式）。
    var loginSession: LoginSession?
    var isProbingServer = false
    var isAuthenticating = false
    /// Quick Connect 轮询期间展示的配对码。
    var quickConnectCode: String?
    var onboardingError: String?

    var quickConnectTask: Task<Void, Never>?
    var loginAttemptGeneration = 0

    // MARK: - 浏览

    var libraries: [MediaLibrary] = []
    /// 侧栏媒体库列表加载失败时展示；成功加载后清空。
    var librariesError: String?

    struct HomeData {
        var resume: [MediaItem] = []
        var nextUp: [MediaItem] = []
        var latest: [MediaItem] = []
        var isLoading = false
        var error: String?
    }

    var home = HomeData()
    /// 同一会话内可能同时发生下拉刷新和设置切换；只有最新一次首页请求可以写回。
    var homeLoadGeneration: UInt64 = 0

    // MARK: - 弹幕设置（弹弹play 网关）

    /// 弹幕网关设置：地址 + API Key。AppSecret 永远不进客户端，只留在网关。
    /// API Key 存 UserDefaults（发行包统一 ad-hoc 签名，见 DanmakuKit）。
    var dandanplayStore = DandanplaySettingsStore()
    let danmaku = DanmakuCoordinator()

    var dandanplayGatewayURL: URL { dandanplayStore.gatewayURL }

    var dandanplayGatewayURLString: String {
        dandanplayStore.gatewayURLString ?? DandanplaySettingsStore.defaultGatewayURL.absoluteString
    }

    var dandanplayAPIKey: String {
        dandanplayStore.apiKey
    }

    /// 是否已配置就绪（地址有效 + API Key 非空）。播放匹配前据此降级到无弹幕。
    var dandanplayIsConfigured: Bool { dandanplayStore.isConfigured }
    var dandanplayHasAPIKey: Bool { !dandanplayStore.apiKey.isEmpty }

    // MARK: - Bangumi（登录 / 进度 / 收藏）

    let bangumi = BangumiCoordinator()

    // MARK: - 导航

    enum Section: Hashable {
        case home
        case settings
        case bangumi
        case library(MediaLibrary.ID)
    }

    enum Route: Hashable {
        case detail(MediaItem)
    }

    var selectedSection: Section = .home {
        didSet { if selectedSection != oldValue { path = [] } }
    }

    /// Mac / iPad 的 push 栈。iPhone 不用它（多 Tab 多栈会串），走下面的模态。
    var path: [Route] = []

    /// iPhone：详情页 sheet。
    var presentedDetail: MediaItem?

    /// 播放覆盖层：非 nil 时播放器盖住整个 App（双端同一套，见 RootView）。
    var presentedPlayer: PlaybackRequest?

    var isCompact = false

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

    // MARK: - 初始化

    init(store: ServerStore = ServerStore()) {
        self.store = store
        // Bangumi 数据库异步建库 + 恢复登录态（不阻塞 Jellyfin 会话恢复）。
        bangumi.setup()
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
        if isCompact {
            presentedDetail = item
        } else {
            path.append(.detail(item))
        }
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
        return "\(profile.serverName) · Jellyfin \(profile.serverVersion ?? "")"
    }
}

import CoreModel
import Foundation

/// 连接服务器时用户显式选择的网络协议。
/// 存到 `baseURL` 里作为唯一事实源：两家的 API、图片、播放流全部从这里派生。
public enum ServerScheme: String, Sendable {
    case http
    case https

    /// 落进绝对 URL 的 scheme 文本。
    public var schemeString: String { rawValue }

    public init?(schemeString value: String) {
        self.init(rawValue: value.lowercased())
    }
}

/// 鉴权失效通知：已登录会话的请求收到 401 时发出，object = `ServerProfile.id`。
/// 登录 / Quick Connect 接口自身的 401 是密码错误，**不**经过此通知。
/// 接收方（App 根视图）按 profileID + 当前会话状态去重，引导用户重新登录。
///
/// 两家实现都发这条：Jellyfin 在 `send` 的出错包装里，Emby 在裸传输层里。
public enum MediaServerAuthentication {
    public static let authenticationRequired = Notification.Name(
        "dev.jumusu.OcPlayer.server.authenticationRequired")
}

/// 媒体库单页结果。`totalRecordCount` 来自服务端；未知时为 nil。
public struct MediaItemsPage: Sendable, Equatable {
    public var items: [MediaItem]
    public var startIndex: Int
    public var totalRecordCount: Int?

    public init(items: [MediaItem], startIndex: Int, totalRecordCount: Int?) {
        self.items = items
        self.startIndex = startIndex
        self.totalRecordCount = totalRecordCount
    }

    /// 是否还能向后翻页（总数未知时以本页是否满页为准）。
    public var hasMore: Bool {
        if let totalRecordCount {
            return startIndex + items.count < totalRecordCount
        }
        return !items.isEmpty
    }
}

/// 播放进度上报。
///
/// 单独成一个协议而不是直接挂在 `MediaServer` 上：它只有 3 条方法，而消费方
/// （播放上报协调器）只需要这 3 条 —— 依赖最窄的契约，测试替身就不必实现
/// `MediaServer` 的另外 20 多条。生产侧两个实现都经 `MediaServer` 满足它。
public protocol PlaybackReporting: Sendable {
    func reportPlaybackStart(context: PlaybackSessionContext, positionSeconds: Double) async
    func reportPlaybackProgress(
        context: PlaybackSessionContext,
        positionSeconds: Double,
        isPaused: Bool
    ) async
    func reportPlaybackStopped(context: PlaybackSessionContext, positionSeconds: Double) async
}

/// 一台已登录媒体服务器的能力面：浏览、详情、图片、播放协商与进度上报。
///
/// Jellyfin 与 Emby 是同一血脉的两个产品，路由和值域都分叉，但**契约是同一条**。
/// 两个实现刻意走不同的解码策略：
///
/// - `JellyfinServer` 用官方 `jellyfin-sdk-swift` 的强类型 DTO —— 它的值域就是
///   Jellyfin 的值域，强解不会失败，也拿得到 SDK 的路由表与 Quick Connect。
/// - `EmbyServer` 自己发裸 HTTP、解到本包自己的宽松 DTO —— Emby 的 `VideoRange`
///   会报 "DolbyVision"、`MediaStreams[].Type` 会报 "Attachment"、`LockedFields`
///   会报 "SortName"，这些都超出 Jellyfin SDK 的枚举值域，强解会整包炸。
///   Emby 侧因此不接收类型，脏值在映射层落到 `.unknown` 而不是抛错。
///
/// 这不是为了整洁而分家：两侧需要的是**互不兼容的解码契约**。把它们塞进一个
/// 强类型实现，代价是给 Jellyfin 的每个响应都套一层洗白，或者把两边都降成
/// 无类型。
///
/// 注意协议里**不提供默认参数**：Swift 的协议要求不能带默认值，而用 extension
/// 转发会和协议要求互相遮蔽（可能递归）。需要默认值的调用点显式传满。
public protocol MediaServer: PlaybackReporting {
    /// 该服务器的持久化档案（含 kind / baseURL / userID）。
    var profile: ServerProfile { get }

    /// 给内核（`open_with_headers`）和图片加载共用的认证头。
    /// Jellyfin 用 `MediaBrowser` scheme，Emby 用 `Emby` scheme。
    var authorizationHeader: String { get }

    // MARK: - 浏览

    /// 用户的媒体库列表（电影 / 剧集 / 音乐…）。
    func userViews() async throws -> [MediaLibrary]
    /// 首页「最近添加」。
    func latestItems(limit: Int) async throws -> [MediaItem]
    /// 用户收藏的电影 / 剧集。
    func favoriteItems(limit: Int) async throws -> [MediaItem]
    /// 首页「继续观看」。
    func resumeItems() async throws -> [MediaItem]
    /// 「接下来看」：追剧下一集。
    func nextUp() async throws -> [MediaItem]
    /// 首页氛围背景取材：全库随机一批带 backdrop 的电影 / 剧集。
    func randomBackdropItems(limit: Int) async throws -> [MediaItem]

    /// 标记条目已看完，返回服务端最新的播放状态快照。
    @discardableResult
    func markPlayed(itemID: String) async throws -> MediaItem.PlayState
    /// 取消已看标记，返回服务端最新的播放状态快照。
    @discardableResult
    func markUnplayed(itemID: String) async throws -> MediaItem.PlayState

    // MARK: - 详情

    /// 条目详情（含演员表 / 简介 / 流派）。
    func item(_ id: String) async throws -> MediaItem
    /// 条目的章节列表。
    func chapters(itemID: String) async throws -> [JellyfinChapter]
    /// 媒体库单页浏览。`searchTerm` 非空时为服务端标题搜索（Emby/Jellyfin 的
    /// `/Items?searchTerm=`），结果仍受父库 / 类型 / 排序 / 观看状态约束。
    func itemsPage(
        parentID: String?,
        kinds: [MediaItem.Kind]?,
        recursive: Bool,
        startIndex: Int,
        limit: Int,
        sort: MediaItemsSort?,
        watchState: MediaItemsWatchState?,
        searchTerm: String?
    ) async throws -> MediaItemsPage
    /// 媒体库网格浏览（拉全部分页）。
    func items(
        parentID: String?,
        kinds: [MediaItem.Kind]?,
        recursive: Bool,
        limit: Int
    ) async throws -> [MediaItem]
    /// 剧集 → 季列表。
    func seasons(seriesID: String) async throws -> [MediaItem]
    /// 剧集 → 集列表（`seasonID` 为 nil 时返回全部）。
    func episodes(seriesID: String, seasonID: String?) async throws -> [MediaItem]
    /// 连播用：从 `startItemID` 起按服务端顺序取 `limit` 条（含它自己）。
    func episodes(seriesID: String, startingAt startItemID: String, limit: Int) async throws -> [MediaItem]
    /// 「类似推荐」。
    func similar(itemID: String, limit: Int) async throws -> [MediaItem]

    // MARK: - 媒体资源

    /// 条目图片地址（不含 token，认证走请求头）。
    func imageURL(itemID: String, type: ItemImageType, maxWidth: Int?, tag: String?) throws -> URL
    /// 直连播放地址（认证走请求头，URL 里没有 token）。
    func streamURL(itemID: String, mediaSourceID: String?, playSessionID: String?) throws -> String
    /// 可跳过的片头 / 片尾片段。
    func mediaSegments(itemID: String) async throws -> [JellyfinMediaSegment]
    /// 条目的外挂字幕列表。
    func externalSubtitles(itemID: String) async throws -> [ExternalSubtitle]
    /// 下载外挂字幕到本地缓存，返回文件路径。
    func downloadSubtitle(_ subtitle: ExternalSubtitle) async throws -> URL
    /// 条目的文件级媒体信息；没有媒体源时 nil。
    func mediaFileInfo(itemID: String) async throws -> MediaFileInfo?
    /// 开播协商：拿可用的 MediaSource 列表与会话 id。
    func playbackInfo(itemID: String) async throws -> PlaybackInfo
}

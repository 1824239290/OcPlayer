import CoreModel
import DiagnosticsKit
import Foundation
import JellyfinKit
import MetadataKit
import Observation

/// App 层的 TMDb 补全协调器：持有客户端与补全服务、暴露设置页要的状态。
///
/// 与 `MetadataCoordinator` 同款职责划分：域包（`MetadataKit`）只懂「怎么匹配、
/// 怎么落库、怎么叠加」，路径与生命周期留在 App 层。
///
/// **它自己不建库**：复用 `MetadataCoordinator` 已经建好的那个 `MetadataStore`
/// （TMDb 的表就在同一个 `Media.sqlite` 里）。两个协调器共用一个库，所以设置页
/// 「清空媒体元数据缓存」与「清除 TMDb 补全数据」是同一个库上的两种粒度。
@MainActor
@Observable
final class TMDbCoordinator {

    /// 用户是否配置了 key。未配置 = 整个功能禁用（不请求、不落库、不叠加）。
    private(set) var isConfigured = false
    /// 当前语言（设置页改它 → 重建客户端无关，语言是每次请求现读的）。
    private(set) var language = "zh-CN"
    /// 文本是否 TMDb 优先。
    private(set) var preferText = true
    /// 图片是否允许顶替服务端已有的图（默认只补缺）。
    private(set) var replaceImages = false
    /// 缓存天数。
    private(set) var cacheDays = TMDbPreferences.defaultCacheDays
    /// 当前租户已建立多少条对应（设置页显示「已补全 N 部」）。
    private(set) var linkedCount = 0
    /// 最近一次拉取失败的可读原因（设置页展示）。nil = 最近一次正常。
    ///
    /// 由 `refreshLastFailure()` 从补全服务取。**不缓存历史**：它是提示，不是账本。
    private(set) var lastError: String?

    @ObservationIgnored private let preferences: TMDbPreferences
    @ObservationIgnored private var enricher: TMDbEnricher?
    @ObservationIgnored private var credentials: TMDbCredentialStore

    init(defaults: UserDefaults = .standard) {
        // 包一层自己的 store 实例，让设置页的读写与 `TMDbPreferences` 走同一个 defaults
        // （测试可注入独立 suite，避免污染 `.standard`）。
        self.credentials = TMDbCredentialStore(defaults: defaults)
        self.preferences = TMDbPreferences(defaults: defaults)
        self.language = preferences.language
        self.preferText = preferences.preferTMDbText
        self.replaceImages = preferences.replaceExistingImages
        self.cacheDays = preferences.cacheDays
        self.isConfigured = credentials.apiKey() != nil
    }

    // MARK: - 装配

    /// 用 `MetadataCoordinator` 的库装配补全服务。未建库完成时是空操作，
    /// 之后 `storeDidBecomeReady(_:)` 会再补一次。
    ///
    /// 这样安排的原因：建库是异步的（不阻塞首屏），而 TMDb 只是可选增强——
    /// 让启动路径等它没有意义。
    func attach(store: MetadataStore?) {
        guard let store else { return }
        enricher = TMDbEnricher(client: makeClient(), store: store, preferences: preferences)
    }

    private func makeClient() -> TMDbClient {
        // 独立的 URLSession：TMDb 与媒体服务器的重试/超时语义不同，也不该共用连接池。
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        return TMDbClient(
            session: URLSession(configuration: configuration),
            credentials: credentials)
    }

    /// 当前是否可用（已配置 key 且补全服务已装配）。
    var isReady: Bool { enricher != nil && isConfigured }

    // MARK: - 设置读写

    func setAPIKey(_ value: String?) {
        credentials.setAPIKey(value)
        isConfigured = credentials.apiKey() != nil
        lastError = nil
    }

    /// 设置页回显用（不完整展示，只显示尾部几位，避免肩窥与截图泄露）。
    var apiKeyDisplay: String {
        guard let key = credentials.apiKey() else { return "未配置" }
        let tail = key.suffix(4)
        return "••••\(tail)"
    }

    func setLanguage(_ value: String) {
        preferences.language = value
        language = preferences.language
        // 换语言后旧语言的计数不再准确，且需要重新拉取才有新语言的数据——
        // 这里只清计数，实际拉取发生在下次打开详情页（不主动全网刷新，
        // 那会是一次几百个请求的突发）。
        linkedCount = 0
    }

    func setPreferText(_ value: Bool) {
        preferences.preferTMDbText = value
        preferText = value
    }

    func setReplaceImages(_ value: Bool) {
        preferences.replaceExistingImages = value
        replaceImages = value
    }

    func setCacheDays(_ value: Int) {
        preferences.cacheDays = value
        cacheDays = preferences.cacheDays
    }

    var cacheLifetimeDescription: String { "\(cacheDays) 天" }
    /// 条款上限（设置页提示用）。
    var maxCacheDays: Int { TMDbPreferences.maxCacheDays }

    // MARK: - 补全

    /// 确保该条目的 TMDb 数据可用（缺失则拉、过期则刷）。返回是否发起了网络。
    ///
    /// 调用方（详情页）在 `.task` 里调；**展示路径不应依赖它**——先渲染已有的
    /// overlay，再让这个方法在后台补齐。
    @discardableResult
    func refresh(item: MediaItem, tenant: TenantID, seriesLink: TMDbLink? = nil) async -> Bool {
        guard let enricher else { return false }
        return await enricher.refresh(item: item, tenant: tenant, seriesLink: seriesLink)
    }

    /// 取已有的叠加数据（不发网络）。
    func overlay(for item: MediaItem, tenant: TenantID) async -> TMDbOverlay? {
        guard let enricher else { return nil }
        return await enricher.overlay(for: item, tenant: tenant)
    }

    /// 取某一季的叠加数据（**不发网络**）。
    func seasonOverlay(seriesLink: TMDbLink, seasonNumber: Int) async -> TMDbOverlay? {
        guard let enricher else { return nil }
        return await enricher.seasonOverlay(seriesLink: seriesLink, seasonNumber: seasonNumber)
    }

    /// 确保某一季的数据可用（缺失则拉）。
    @discardableResult
    func refreshSeason(seriesLink: TMDbLink, seasonNumber: Int) async -> Bool {
        guard let enricher else { return false }
        return await enricher.refreshSeason(seriesLink: seriesLink, seasonNumber: seasonNumber)
    }

    /// 某条目的对应关系（集/季需要父剧的对应来推导）。
    func link(for item: MediaItem, tenant: TenantID, store: MetadataStore?) async -> TMDbLink? {
        guard let store else { return nil }
        return try? await store.linkedTMDbEntity(itemID: item.id, tenant: tenant)
    }

    /// 取最近一次失败并转成用户能看懂的文案（设置页出现时调）。
    ///
    /// `notFound` 刻意**不提示**：那是服务端 `ProviderIds` 里的脏数据（id 在 TMDb
    /// 不存在），不是用户配置或网络的问题——弹一个他无法处理的错误只会添乱。
    func refreshLastFailure() async {
        guard let enricher else {
            lastError = nil
            return
        }
        lastError = Self.message(for: await enricher.reportedFailure())
    }

    /// 把补全服务的失败翻成用户能看懂的文案。nil = 不提示。
    ///
    /// 抽成**静态纯函数**是为了能直接测：映射本身（哪个错误该说什么话）是这里唯一
    /// 有判断的部分，而 `refreshLastFailure` 只是把 enricher 的值搬过来。
    static func message(for failure: TMDbError?) -> String? {
        switch failure {
        case .none:
            nil
        case .unauthorized:
            "API Key 无效或已被 TMDb 拒绝"
        case .rateLimited:
            "TMDb 限流，请稍后再试"
        case .transport:
            "连不上 TMDb（检查网络或代理）"
        case .http(let status):
            "TMDb 返回 HTTP \(status)"
        case .decoding:
            "TMDb 返回了无法解析的数据"
        case .notConfigured, .notFound:
            // `notFound` 是服务端 ProviderIds 里的脏数据（id 在 TMDb 不存在），
            // 不是用户配置或网络的问题——弹一个他无法处理的错误只会添乱。
            nil
        }
    }

    /// 刷新已补全条目数（设置页出现时调）。
    func refreshLinkedCount(tenant: TenantID?) async {
        guard let enricher, let tenant else {
            linkedCount = 0
            return
        }
        linkedCount = await enricher.linkedCount(tenant: tenant)
    }

    /// 清掉当前租户的全部补全数据（设置页「清除」）。
    func clear(tenant: TenantID?) async {
        guard let enricher, let tenant else { return }
        await enricher.clear(tenant: tenant)
        linkedCount = 0
    }

    /// 清过期实体（挂在每日存储维护上；不是必须，只是把死数据还给用户）。
    func runMaintenance() async {
        guard let enricher else { return }
        let removed = await enricher.evictExpired()
        if removed > 0 {
            AppDiagnostics.logInfo("TMDb 过期数据清理", fields: ["removed": .integer(Int64(removed))])
        }
    }
}

/// 设置页可选的语言列表。
///
/// 只列 TMDb 支持得好的几种，而不是把它的全部 locale 铺出来（上百个，还有
/// 只翻译了部分字段的）：选一个没有翻译的语言，结果是「标题英文、简介空白」，
/// 用户会以为功能坏了。
enum TMDbLanguageOption: String, CaseIterable, Identifiable {
    case simplifiedChinese = "zh-CN"
    case traditionalChinese = "zh-TW"
    case english = "en-US"
    case japanese = "ja-JP"
    case korean = "ko-KR"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simplifiedChinese: "简体中文"
        case .traditionalChinese: "繁體中文"
        case .english: "English"
        case .japanese: "日本語"
        case .korean: "한국어"
        }
    }
}

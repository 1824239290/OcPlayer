import Foundation
import MetadataKit
import SwiftUI
import UniformTypeIdentifiers

/// OcPlayer 配置备份包顶层模型。
///
/// 用途：把「用户在这台设备上配过什么」导出成一个 JSON 文件，经 iCloud 云盘 /
/// 隔空投送搬到另一台设备上恢复（见 `ConfigBackupCoordinator`）。
///
/// ## 四条约定
///
/// 1. **全部子模块都是 Optional**：老文件缺某个模块时导入不能报错，新版本加了
///    模块时老版本也必须能读（多出来的键被忽略）。
/// 2. **只收「用户可搬走」的偏好，不收凭据**：服务器地址、账号密码、会话 token
///    一律不进备份——它们跟着服务器而不是跟着用户，且泄露面太大。
///    TMDB Key / 弹弹play Key 是用户自己申请、可随时重置的第三方凭据，属于例外。
/// 3. **取值形态必须与落盘形态一致**：这些字段最终都写回 `UserDefaults`，
///    类型选错（例如把 UInt32 的颜色存成 String）不会编译报错，只会静默失效。
///    每一项都在下方注明它对应的 key 与真实类型。
/// 4. **默认值一律引用事实源**：能引包内常量的就不写死数值
///    （如 `TMDbPreferences.defaultCacheDays`），否则默认值漂移时导出文件里
///    会静默带上一个「用户从没选过的档位」。
struct AppConfigBackup: Codable, Sendable, Equatable {
    /// 备份格式版本。当前为 1。
    ///
    /// 读取时 `> 1` 直接拒绝（见 `ConfigBackupCoordinator.decode`）：宁可不导入，
    /// 也不要按旧语义去误解新字段。
    var formatVersion: Int
    /// 导出时间。
    var exportedAt: Date
    /// 导出的 App 版本（如 "0.2.1"），用于排查「哪个版本导出的」。
    var appVersion: String
    /// 导出的设备名称（如 "MacBook Pro"），仅在确认弹窗里展示给人看。
    var deviceName: String?

    var tmdb: TMDbBackupConfig?
    var playback: PlaybackBackupConfig?
    var danmaku: DanmakuBackupConfig?
    var general: GeneralBackupConfig?

    init(
        formatVersion: Int = 1,
        exportedAt: Date = Date(),
        appVersion: String = AppVersion.currentShortVersion,
        deviceName: String? = nil,
        tmdb: TMDbBackupConfig? = nil,
        playback: PlaybackBackupConfig? = nil,
        danmaku: DanmakuBackupConfig? = nil,
        general: GeneralBackupConfig? = nil
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.deviceName = deviceName
        self.tmdb = tmdb
        self.playback = playback
        self.danmaku = danmaku
        self.general = general
    }
}

/// TMDB 配置（`MetadataKit.TMDbCredentialStore` / `TMDbPreferences` 的落盘键）。
struct TMDbBackupConfig: Codable, Sendable, Equatable {
    /// `dev.jumusu.ocplayer.tmdb.apiKey`。v3 API Key 或 v4 Read Access Token。
    var apiKey: String?
    /// `dev.jumusu.ocplayer.tmdb.language`。默认 `zh-CN`。
    var language: String
    /// `dev.jumusu.ocplayer.tmdb.preferText`。
    var preferText: Bool
    /// `dev.jumusu.ocplayer.tmdb.fillImages`。
    var replaceImages: Bool
    /// `dev.jumusu.ocplayer.tmdb.showPlaceholders`。
    var showPlaceholders: Bool
    /// `dev.jumusu.ocplayer.tmdb.cacheDays`。
    var cacheDays: Int

    init(
        apiKey: String? = nil,
        language: String = "zh-CN",
        preferText: Bool = true,
        replaceImages: Bool = false,
        showPlaceholders: Bool = true,
        cacheDays: Int = TMDbPreferences.defaultCacheDays
    ) {
        self.apiKey = apiKey
        self.language = language
        self.preferText = preferText
        self.replaceImages = replaceImages
        self.showPlaceholders = showPlaceholders
        self.cacheDays = cacheDays
    }
}

/// 播放器与字幕偏好（`PlaybackPreferences` 的落盘键）。
///
/// ⚠️ **可选字段是三态**：字幕外观那一组（对齐 / 边距 / 颜色 / 描边 / 加粗）
/// 在 App 里是「设过 / 没设过」三态，"没设过" 必须保持 nil，导入时**不写**。
/// 写成 0 或默认值等于替用户改了字幕样式（见 `PlaybackPreferences.subtitleStyle()`）。
struct PlaybackBackupConfig: Codable, Sendable, Equatable {
    /// `playback.skipIntro`，默认 true。
    var skipIntro: Bool
    /// `playback.skipOutro`，默认 true。
    var skipOutro: Bool
    /// `playback.outroRetentionSeconds`，默认 10。
    var outroRetentionSeconds: Int
    /// `playback.subtitleLanguage`，存 `SubtitleLanguagePreference.rawValue`
    /// （`zh-Hans` / `zh-Hant` / `followSource` / `off`），默认 `zh-Hans`。
    var subtitleLanguage: String
    /// `playback.lumaUpscaler`，存 `PlaybackUpscalerMode.rawValue`，默认 `off`。
    var lumaUpscaler: String
    /// `playback.subtitleStyleOverrides`，默认 false。
    var subtitleStyleOverrides: Bool?
    /// `playback.subtitleAlignment`，Int（1…9，0 = 不干预）。
    var subtitleAlignment: Int?
    /// `playback.subtitleMarginVertical`，**Int**（0 = 不干预）。
    var subtitleMarginVertical: Int?
    /// `playback.subtitlePrimaryColor`，**UInt32 RGBA**（不是字符串）。
    var subtitlePrimaryColor: UInt32?
    /// `playback.subtitleOutlineColor`，**UInt32 RGBA**（不是字符串）。
    var subtitleOutlineColor: UInt32?
    /// `playback.subtitleOutlineWidth`，Double（0 = 不干预）。
    var subtitleOutlineWidth: Double?
    /// `playback.subtitleBold`，三态。
    var subtitleBold: Bool?
    /// `playback.httpReadAheadMiB`（0 = 内核默认）。
    var httpReadAheadMiB: Int
    /// `playback.httpBackBufferMiB`（0 = 内核默认 16 MiB）。
    var httpBackBufferMiB: Int

    init(
        skipIntro: Bool = true,
        skipOutro: Bool = true,
        outroRetentionSeconds: Int = 10,
        subtitleLanguage: String = "zh-Hans",
        lumaUpscaler: String = "off",
        subtitleStyleOverrides: Bool? = nil,
        subtitleAlignment: Int? = nil,
        subtitleMarginVertical: Int? = nil,
        subtitlePrimaryColor: UInt32? = nil,
        subtitleOutlineColor: UInt32? = nil,
        subtitleOutlineWidth: Double? = nil,
        subtitleBold: Bool? = nil,
        httpReadAheadMiB: Int = 0,
        httpBackBufferMiB: Int = 0
    ) {
        self.skipIntro = skipIntro
        self.skipOutro = skipOutro
        self.outroRetentionSeconds = outroRetentionSeconds
        self.subtitleLanguage = subtitleLanguage
        self.lumaUpscaler = lumaUpscaler
        self.subtitleStyleOverrides = subtitleStyleOverrides
        self.subtitleAlignment = subtitleAlignment
        self.subtitleMarginVertical = subtitleMarginVertical
        self.subtitlePrimaryColor = subtitlePrimaryColor
        self.subtitleOutlineColor = subtitleOutlineColor
        self.subtitleOutlineWidth = subtitleOutlineWidth
        self.subtitleBold = subtitleBold
        self.httpReadAheadMiB = httpReadAheadMiB
        self.httpBackBufferMiB = httpBackBufferMiB
    }
}

/// 弹幕偏好（`PlaybackPreferences` 弹幕组 + `DandanplaySettingsStore`）。
struct DanmakuBackupConfig: Codable, Sendable, Equatable {
    /// `danmaku.enabled`，默认 true。
    var danmakuEnabled: Bool
    /// `danmaku.opacity`，默认 0.85，有效范围 0.25…1。
    var opacity: Double
    /// `danmaku.displayArea`，默认 **0.75**，有效范围 0.25…1。
    var displayArea: Double
    var blockTop: Bool
    var blockBottom: Bool
    var blockScroll: Bool
    /// `danmaku.fontSize`，默认 22（基准），有效范围 11…44。
    var fontSize: Double
    /// `danmaku.autoLoad`，默认 true。
    var autoLoad: Bool
    /// 弹弹play 网关地址：**只在用户显式设过时才非 nil**（`gatewayURLString` 的原始值）。
    ///
    /// 存的是"用户设过没有"，不是"当前生效的地址"——后者在未设置时会回落内置公共
    /// 网关，导出它等于把一个内置常量写进用户文件。
    var dandanplayGatewayURL: String?

    init(
        danmakuEnabled: Bool = true,
        opacity: Double = 0.85,
        displayArea: Double = 0.75,
        blockTop: Bool = false,
        blockBottom: Bool = false,
        blockScroll: Bool = false,
        fontSize: Double = 22,
        autoLoad: Bool = true,
        dandanplayGatewayURL: String? = nil
    ) {
        self.danmakuEnabled = danmakuEnabled
        self.opacity = opacity
        self.displayArea = displayArea
        self.blockTop = blockTop
        self.blockBottom = blockBottom
        self.blockScroll = blockScroll
        self.fontSize = fontSize
        self.autoLoad = autoLoad
        self.dandanplayGatewayURL = dandanplayGatewayURL
    }
}

/// 常规与界面偏好。
struct GeneralBackupConfig: Codable, Sendable, Equatable {
    /// `bangumi.enabled`，默认 true。
    var bangumiEnabled: Bool
    /// `moviepilot.enabled`，默认 true。
    var moviepilotEnabled: Bool
    /// `home.sections`，逗号分隔 token 串（含关闭项）。
    var homeSections: String?
    /// `detail.episodeSortAscending`，默认 true。
    var episodeSortAscending: Bool

    init(
        bangumiEnabled: Bool = true,
        moviepilotEnabled: Bool = true,
        homeSections: String? = nil,
        episodeSortAscending: Bool = true
    ) {
        self.bangumiEnabled = bangumiEnabled
        self.moviepilotEnabled = moviepilotEnabled
        self.homeSections = homeSections
        self.episodeSortAscending = episodeSortAscending
    }
}

/// `.fileExporter` / `.fileImporter` 用的 JSON 文档。
///
/// 与 `DiagnosticExportDocument`（纯文本）同款：macOS 存到用户选的位置，
/// iOS 进系统「存储到文件 / 共享」流程——**用户可在那里选 iCloud 云盘或隔空投送**，
/// 这正是本方案不需要付费开发者账号的原因。
struct ConfigBackupDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(backup: AppConfigBackup) throws {
        self.data = try ConfigBackupCoordinator.encode(backup)
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

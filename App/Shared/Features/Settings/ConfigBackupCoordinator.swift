import DanmakuKit
import Foundation
import PlaybackKit
#if canImport(UIKit)
import UIKit
#endif

/// 配置备份摘要，用于导入前的二次确认弹窗。
///
/// 存在的意义：导入是**覆盖**操作，用户必须先看清「这个文件里有什么」再决定。
/// 凭据只回显尾 4 位（与 `TMDbCoordinator.apiKeyDisplay` 同一取舍：避免肩窥与截图泄露）。
struct BackupSummary: Sendable, Equatable {
    var hasTMDb: Bool
    /// TMDB Key 尾 4 位（形如 `••••abcd`），未配置时为 nil。
    var tmdbKeyTail: String?
    var tmdbLanguage: String?
    var hasPlayback: Bool
    var hasDanmaku: Bool
    var hasGeneral: Bool
    var exportedAtFormatted: String
    var deviceName: String?
}

/// 配置备份的导出 / 解析 / 恢复。
///
/// ## 为什么不用 iCloud API
///
/// 原生 `NSUbiquitousKeyValueStore` / CloudKit 需要付费开发者账号 + iCloud
/// Entitlements + 正式签名，而本项目发行包是 ad-hoc / 侧载（见 README「下载」）。
/// 换一条路：导出成普通文件，交给系统文件选择器 —— 用户自己就能存进
/// **iCloud 云盘**或走**隔空投送**，零门槛、零账号要求，且数据始终在用户手里。
///
/// ## 与 UserDefaults 的关系
///
/// 所有偏好最终都写回 `UserDefaults`（key 见 `SettingsKeys` 与各域包的 store）。
/// 本类型**不持有** `AppModel`，也不依赖 `DanmakuModel`：导出只要一个网关字符串，
/// 写回只要一个 `DandanplaySettingsStore`（它自己就能注入 `UserDefaults`）。
/// 于是整条链路都能用独立 suite 测——`.standard` 在测试宿主里是**真实的用户域**，
/// 写进去会污染本机设置；而构造 `DanmakuModel` 还会真的建出 Application Support 目录。
@MainActor
enum ConfigBackupCoordinator {

    /// 当前格式版本。加字段不需要动它；**语义变了才 +1**（读的时候 `> 1` 拒绝）。
    nonisolated static let formatVersion = 1

    // MARK: - 导出

    /// 抽取当前配置生成备份包。
    ///
    /// 取值遵循一条原则：**「没设过」与「设成了默认值」在导出时必须分得开**
    /// （三态字段保持 nil，见 `PlaybackBackupConfig`），否则导入端会把默认值
    /// 当成用户显式选择写下去，等于替用户改了样式。
    ///
    /// - Parameters:
    ///   - tmdb: TMDB 协调器（提供 Key 与语言策略）。
    ///   - dandanplayGatewayURL: 用户自定义的弹弹play 网关（**原始值**，
    ///     传 `DandanplaySettingsStore.gatewayURLString`；nil = 从没设过）。
    ///   - defaults: 偏好域（测试注入独立 suite；生产传 `.standard`）。
    ///   - deviceName: 覆盖设备名（nil = 取系统设备名）。
    ///   - appVersion: 覆盖版本号（nil = `AppVersion.currentShortVersion`）。
    static func makeBackup(
        tmdb: TMDbCoordinator,
        dandanplayGatewayURL: String? = nil,
        defaults: UserDefaults = .standard,
        deviceName: String? = nil,
        appVersion: String? = nil
    ) -> AppConfigBackup {
        let tmdbConfig = TMDbBackupConfig(
            apiKey: tmdb.rawAPIKey,
            // 语言与抓取策略都从协调器取（它已经读过了同一份 defaults，
            // 并做过「键缺失 = 默认」的处理），不要在这里重读一遍。
            language: tmdb.language,
            preferText: tmdb.preferText,
            replaceImages: tmdb.replaceImages,
            showPlaceholders: tmdb.showPlaceholders,
            cacheDays: tmdb.cacheDays
        )

        let playbackConfig = PlaybackBackupConfig(
            skipIntro: defaults.bool(forKey: SettingsKeys.skipIntro, default: true),
            skipOutro: defaults.bool(forKey: SettingsKeys.skipOutro, default: true),
            outroRetentionSeconds: outroRetentionSeconds(in: defaults),
            subtitleLanguage: subtitleLanguage(in: defaults),
            lumaUpscaler: lumaUpscaler(in: defaults),
            subtitleStyleOverrides: defaults.object(forKey: SettingsKeys.subtitleStyleOverrides) as? Bool,
            subtitleAlignment: defaults.object(forKey: SettingsKeys.subtitleAlignment) as? Int,
            subtitleMarginVertical: defaults.object(forKey: SettingsKeys.subtitleMarginVertical) as? Int,
            subtitlePrimaryColor: storedColor(in: defaults, key: SettingsKeys.subtitlePrimaryColor),
            subtitleOutlineColor: storedColor(in: defaults, key: SettingsKeys.subtitleOutlineColor),
            subtitleOutlineWidth: defaults.object(forKey: SettingsKeys.subtitleOutlineWidth) as? Double,
            subtitleBold: defaults.object(forKey: SettingsKeys.subtitleBold) as? Bool,
            httpReadAheadMiB: defaults.integer(forKey: SettingsKeys.httpReadAheadMiB),
            httpBackBufferMiB: defaults.integer(forKey: SettingsKeys.httpBackBufferMiB)
        )

        let danmakuConfig = DanmakuBackupConfig(
            danmakuEnabled: defaults.bool(forKey: SettingsKeys.danmakuEnabled, default: true),
            opacity: storedDouble(in: defaults, key: SettingsKeys.danmakuOpacity, fallback: 0.85),
            displayArea: storedDouble(in: defaults, key: SettingsKeys.danmakuDisplayArea, fallback: 0.75),
            blockTop: defaults.bool(forKey: SettingsKeys.danmakuBlockTop, default: false),
            blockBottom: defaults.bool(forKey: SettingsKeys.danmakuBlockBottom, default: false),
            blockScroll: defaults.bool(forKey: SettingsKeys.danmakuBlockScroll, default: false),
            fontSize: storedDouble(
                in: defaults, key: SettingsKeys.danmakuFontSize,
                fallback: PlaybackPreferences.danmakuBaseFontSize),
            autoLoad: defaults.bool(forKey: SettingsKeys.danmakuAutoLoad, default: true),
            // 这里收的是**原始值**（nil = 从没设过），不是 `dandanplayGatewayURLString`
            // ——后者在未设置时会回落到内置公共网关，导出它等于把内置常量写进用户文件。
            dandanplayGatewayURL: dandanplayGatewayURL?.isEmpty == false ? dandanplayGatewayURL : nil
        )

        let generalConfig = GeneralBackupConfig(
            bangumiEnabled: defaults.bool(forKey: SettingsKeys.bangumiEnabled, default: true),
            moviepilotEnabled: defaults.bool(forKey: SettingsKeys.moviepilotEnabled, default: true),
            homeSections: defaults.string(forKey: SettingsKeys.homeSections),
            episodeSortAscending: defaults.bool(forKey: SettingsKeys.episodeSortAscending, default: true)
        )

        return AppConfigBackup(
            formatVersion: formatVersion,
            exportedAt: Date(),
            appVersion: appVersion ?? AppVersion.currentShortVersion,
            deviceName: deviceName ?? currentDeviceName(),
            tmdb: tmdbConfig,
            playback: playbackConfig,
            danmaku: danmakuConfig,
            general: generalConfig
        )
    }

    // MARK: - 恢复

    /// 把备份写回系统。
    ///
    /// **只写文件里有的模块**：缺哪块就保持现状（老版本导出的文件、或用户只想搬
    /// 一部分时都不会被清空）。三态字段为 nil 时**不写**——「不设置」是用户的选择。
    static func applyBackup(
        _ backup: AppConfigBackup,
        tmdb: TMDbCoordinator,
        dandanplayStore: DandanplaySettingsStore? = nil,
        defaults: UserDefaults = .standard
    ) {
        if let config = backup.tmdb {
            // 空 Key 不清除现有 Key：备份里没有凭据 ≠ 用户想登出。
            if let key = config.apiKey, !key.isEmpty {
                tmdb.setAPIKey(key)
            }
            tmdb.setLanguage(config.language)
            tmdb.setPreferText(config.preferText)
            tmdb.setReplaceImages(config.replaceImages)
            tmdb.setShowPlaceholders(config.showPlaceholders)
            tmdb.setCacheDays(config.cacheDays)
        }

        if let config = backup.playback {
            defaults.set(config.skipIntro, forKey: SettingsKeys.skipIntro)
            defaults.set(config.skipOutro, forKey: SettingsKeys.skipOutro)
            defaults.set(config.outroRetentionSeconds, forKey: SettingsKeys.outroRetentionSeconds)
            // 枚举档位先校验再写：坏值写进去虽然会被 getter 兜住，但界面上会出现
            // 「设置页显示的值」与「实际生效的值」不一致（设置页读的是同一 key）。
            if SubtitleLanguagePreference(rawValue: config.subtitleLanguage) != nil {
                defaults.set(config.subtitleLanguage, forKey: SettingsKeys.subtitleLanguagePreference)
            }
            if PlaybackUpscalerMode(rawValue: config.lumaUpscaler) != nil {
                defaults.set(config.lumaUpscaler, forKey: SettingsKeys.lumaUpscaler)
            }
            defaults.set(config.httpReadAheadMiB, forKey: SettingsKeys.httpReadAheadMiB)
            defaults.set(config.httpBackBufferMiB, forKey: SettingsKeys.httpBackBufferMiB)

            // 字幕外观：nil = 备份里没有 = 保持现状。
            writeIfPresent(config.subtitleStyleOverrides, key: SettingsKeys.subtitleStyleOverrides, into: defaults)
            writeIfPresent(config.subtitleAlignment, key: SettingsKeys.subtitleAlignment, into: defaults)
            writeIfPresent(config.subtitleMarginVertical, key: SettingsKeys.subtitleMarginVertical, into: defaults)
            writeIfPresent(config.subtitlePrimaryColor, key: SettingsKeys.subtitlePrimaryColor, into: defaults)
            writeIfPresent(config.subtitleOutlineColor, key: SettingsKeys.subtitleOutlineColor, into: defaults)
            writeIfPresent(config.subtitleOutlineWidth, key: SettingsKeys.subtitleOutlineWidth, into: defaults)
            writeIfPresent(config.subtitleBold, key: SettingsKeys.subtitleBold, into: defaults)
        }

        if let config = backup.danmaku {
            defaults.set(config.danmakuEnabled, forKey: SettingsKeys.danmakuEnabled)
            defaults.set(config.opacity, forKey: SettingsKeys.danmakuOpacity)
            defaults.set(config.displayArea, forKey: SettingsKeys.danmakuDisplayArea)
            defaults.set(config.blockTop, forKey: SettingsKeys.danmakuBlockTop)
            defaults.set(config.blockBottom, forKey: SettingsKeys.danmakuBlockBottom)
            defaults.set(config.blockScroll, forKey: SettingsKeys.danmakuBlockScroll)
            defaults.set(config.fontSize, forKey: SettingsKeys.danmakuFontSize)
            defaults.set(config.autoLoad, forKey: SettingsKeys.danmakuAutoLoad)

            // 只写网关地址，**不碰 API Key**：`apiKey` 的 getter 在未设置时回落到
            // 内置公共 Key，于是「读出来再写回去」会把内置常量变成用户显式设置
            // （将来换内置 Key 时这台设备就再也跟不上）；而 `updateGateway` 是整体
            // 赋值，备份里没有 Key 时会把目标设备上用户自有的 Key 抹掉。
            if let gateway = config.dandanplayGatewayURL, !gateway.isEmpty, let store = dandanplayStore {
                // 取一份 `var` 副本再写：`DandanplaySettingsStore` 是 struct，
                // 它的 setter 不是 `nonmutating`。写穿的是它内部持有的 `UserDefaults`
                // 引用，所以副本写下去就是真落盘（与设置页走同一个键）。
                var mutableStore = store
                mutableStore.gatewayURLString = gateway
            }
        }

        if let config = backup.general {
            defaults.set(config.bangumiEnabled, forKey: SettingsKeys.bangumiEnabled)
            defaults.set(config.moviepilotEnabled, forKey: SettingsKeys.moviepilotEnabled)
            defaults.set(config.episodeSortAscending, forKey: SettingsKeys.episodeSortAscending)
            if let sections = config.homeSections, !sections.isEmpty {
                defaults.set(sections, forKey: SettingsKeys.homeSections)
            }
        }
    }

    // MARK: - 序列化

    /// 编码为可读 JSON（prettyPrinted + sortedKeys：用户可能想自己看一眼甚至手改）。
    ///
    /// `nonisolated`：纯函数，不该要求调用方在主 actor 上（`ConfigBackupDocument`
    /// 的 init 就是非隔离的）。
    ///
    /// 时间用 `.iso8601`（秒精度）：跨设备 / 跨地区都不会歧义。
    /// 代价是 `exportedAt` 亚秒部分会丢——这不影响任何功能，但**测试不能拿整个
    /// 结构体做往返相等断言**（见 `ConfigBackupTests`）。
    nonisolated static func encode(_ backup: AppConfigBackup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(backup)
    }

    nonisolated static func decode(_ data: Data) throws -> AppConfigBackup {
        guard !data.isEmpty else { throw ConfigBackupError.emptyData }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let backup = try decoder.decode(AppConfigBackup.self, from: data)
            guard backup.formatVersion <= formatVersion else {
                throw ConfigBackupError.unsupportedVersion(backup.formatVersion)
            }
            return backup
        } catch let error as ConfigBackupError {
            throw error
        } catch {
            // 非 OcPlayer 文件 / 被截断 / 手改坏了都落到这里：**宁可什么都不做**，
            // 也不要带着半个对象去覆盖用户设置。
            throw ConfigBackupError.invalidFormat(error.localizedDescription)
        }
    }

    /// 从文件读备份（自动处理 iOS 的 Security-Scoped 授权）。
    ///
    /// `fileImporter` 给回来的是**沙盒外**的 URL，不调
    /// `startAccessingSecurityScopedResource()` 读会直接失败——这是 iOS 上
    /// 「选得到文件但导入报错」的典型原因。
    nonisolated static func readBackup(from url: URL) throws -> AppConfigBackup {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            return try decode(try Data(contentsOf: url))
        } catch let error as ConfigBackupError {
            throw error
        } catch {
            throw ConfigBackupError.unreadableFile(error.localizedDescription)
        }
    }

    // MARK: - 摘要

    nonisolated static func summary(of backup: AppConfigBackup) -> BackupSummary {
        let key = backup.tmdb?.apiKey ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        return BackupSummary(
            hasTMDb: !key.isEmpty,
            tmdbKeyTail: key.isEmpty ? nil : "••••\(key.suffix(4))",
            tmdbLanguage: backup.tmdb?.language,
            hasPlayback: backup.playback != nil,
            hasDanmaku: backup.danmaku != nil,
            hasGeneral: backup.general != nil,
            exportedAtFormatted: formatter.string(from: backup.exportedAt),
            deviceName: backup.deviceName
        )
    }

    /// 建议文件名（扩展名由 `fileExporter` 按 contentType 补，这里带上便于分享预览）。
    nonisolated static func suggestedFileName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        // 固定格式串必须配固定 locale，否则某些区域会用本地数字符号渲染时间。
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return "OcPlayer-配置备份-\(formatter.string(from: date)).json"
    }

    // MARK: - 取值辅助（与 PlaybackPreferences 的 getter 同语义）

    /// 三态字段：nil = 备份里没有这一项 = 不写（保持目标设备现状）。
    private static func writeIfPresent<T>(_ value: T?, key: String, into defaults: UserDefaults) {
        guard let value else { return }
        defaults.set(value, forKey: key)
    }

    /// 颜色按**整数**存（`UInt32` RGBA），不是字符串。
    /// 0 与越界值都表示「用户没设过」——与 `PlaybackPreferences.storedColor` 一致。
    private static func storedColor(in defaults: UserDefaults, key: String) -> UInt32? {
        guard defaults.object(forKey: key) != nil else { return nil }
        let value = defaults.integer(forKey: key)
        guard value > 0, value <= Int(UInt32.max) else { return nil }
        return UInt32(value)
    }

    /// 数值档位：键不存在才回 fallback（`double(forKey:)` 对缺失键返回 0，
    /// 而 0 在这里不是合法档位，直接用它会把「没设过」误报成 0）。
    private static func storedDouble(in defaults: UserDefaults, key: String, fallback: Double) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.double(forKey: key)
    }

    private static func outroRetentionSeconds(in defaults: UserDefaults) -> Int {
        // 0 在这里是合法档位（不保留），所以必须先探存在性。
        guard defaults.object(forKey: SettingsKeys.outroRetentionSeconds) != nil else { return 10 }
        let stored = defaults.integer(forKey: SettingsKeys.outroRetentionSeconds)
        return PlaybackPreferences.outroRetentionOptionsSeconds.contains(stored) ? stored : 10
    }

    private static func subtitleLanguage(in defaults: UserDefaults) -> String {
        let fallback = SubtitleLanguagePreference.chineseSimplified.rawValue
        guard let raw = defaults.string(forKey: SettingsKeys.subtitleLanguagePreference),
              SubtitleLanguagePreference(rawValue: raw) != nil
        else { return fallback }
        return raw
    }

    private static func lumaUpscaler(in defaults: UserDefaults) -> String {
        let fallback = PlaybackUpscalerMode.off.rawValue
        guard let raw = defaults.string(forKey: SettingsKeys.lumaUpscaler),
              PlaybackUpscalerMode(rawValue: raw) != nil
        else { return fallback }
        return raw
    }

    private static func currentDeviceName() -> String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #elseif os(iOS)
        return UIDevice.current.name
        #else
        return "Apple Device"
        #endif
    }
}

/// 备份文件读取失败的原因。
///
/// 每种都给**用户能看懂**的话术：设置页直接把 `errorDescription` 显示出来，
/// 所以不要在这里暴露 `DecodingError` 的英文技术细节（它已经被包进 details）。
enum ConfigBackupError: LocalizedError, Equatable {
    case emptyData
    case invalidFormat(String)
    case unsupportedVersion(Int)
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .emptyData:
            return "备份文件为空"
        case .invalidFormat:
            return "不是有效的 OcPlayer 配置文件（或文件已损坏）"
        case .unsupportedVersion(let version):
            return "备份版本 v\(version) 来自更新的 OcPlayer，请先升级本机 App 再导入"
        case .unreadableFile:
            return "无法读取该文件，请确认它还在原位置（iCloud 云盘里的文件可能需要先下载）"
        }
    }
}

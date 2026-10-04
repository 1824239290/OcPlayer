import DanmakuKit
import DiagnosticsKit
import Foundation

/// Storage owned by OcPlayer. Maintenance must never walk parent user folders.
///
/// 路径一律经 `OcPlayerStorage` 取（单一事实源），**并在这里登记**——
/// 维护只看这张清单，没登记的目录等于不存在：不会被清理、体积也不可见。
/// `Bangumi.sqlite` 就是这么漏掉的（自引入起从未纳入，见 S0 修复）；
/// 新增落盘时请同时做「取路径 + 登记」两件事。
enum AppStorageDirectories {
    /// 根目录（`Application Support/OcPlayer`）。
    static let root = OcPlayerStorage.defaultRoot
    static let importedSubtitles = OcPlayerStorage.directory("Subtitles")
    static let screenshots = URL.picturesDirectory
        .appending(path: OcPlayerStorage.directoryName, directoryHint: .isDirectory)
    static let danmaku = OcPlayerStorage.directory("Danmaku")
    /// 图片字节缓存（`ImagePipeline` 的 URLCache 落盘位置）。
    static let imageCache = OcPlayerStorage.directory("ImageCache")
    /// 本地数据库。**不是普通缓存**：进度/关联/元数据都不能随手删，
    /// 所以它们只参与「体积上报」，不进 `ManagedDirectoryPruner` 的删除路径。
    static let databaseFileNames = ["Bangumi.sqlite", "Media.sqlite"]

    /// 数据库及其 WAL 附属文件（`-wal` / `-shm`）的总字节数。
    ///
    /// WAL 会随写入增长，体积上报必须把它算进去，否则「数据库占了多少」
    /// 会长期少报一大截（实测 `Bangumi.sqlite-wal` 曾达 0.7 MB）。
    static func databaseTotalBytes() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for name in databaseFileNames {
            for suffix in ["", "-wal", "-shm"] {
                let url = root.appending(path: name + suffix)
                guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                      let size = attributes[.size] as? NSNumber
                else { continue }
                total += size.int64Value
            }
        }
        return total
    }
}

/// Keeps app-managed copies bounded without blocking the main actor.
///
/// Screenshot PNGs are user-visible output, so they have no age expiry. Only the
/// oldest files in OcPlayer's dedicated directory are removed after a hard count
/// or byte limit is exceeded.
final class AppStorageMaintenance: @unchecked Sendable {
    static let shared = AppStorageMaintenance()

    private let queue = DispatchQueue(label: "dev.jumusu.OcPlayer.storage-maintenance", qos: .utility)
    private var timer: DispatchSourceTimer?

    private init() {}

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            performMaintenance()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + .seconds(86_400),
                repeating: .seconds(86_400),
                leeway: .seconds(600)
            )
            timer.setEventHandler { [weak self] in self?.performMaintenance() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Coalesced by the serial utility queue; called after a managed file is added.
    func requestMaintenance() {
        queue.async { [weak self] in self?.performMaintenance() }
    }

    // MARK: - 数据库维护注入点

    /// 数据库淘汰任务的注入点。
    ///
    /// 本类是单例、拿不到 `AppModel`（也不该拿：它只懂文件系统），所以由装配处
    /// 注入一个闭包。**没注入就跳过**——测试与未建库时都走这条。
    private var databaseMaintenance: (@Sendable () async -> Void)?

    func setDatabaseMaintenance(_ work: @escaping @Sendable () async -> Void) {
        queue.async { [self] in databaseMaintenance = work }
    }

    private func performMaintenance() {
        AppDiagnostics.logger.performMaintenance()
        // 本方法**只在 queue 上跑**，所以这里读 `databaseMaintenance` 是安全的；
        // 闭包捕获出去之后不再碰这个属性（把读取与调用点收在同一个串行域里）。
        runDatabaseMaintenance()

        let subtitleResult = ManagedDirectoryPruner.prune(
            directory: AppStorageDirectories.importedSubtitles,
            allowedExtensions: ["ass", "ssa", "srt", "vtt"],
            maxFileCount: 100,
            maxTotalBytes: 512 * 1024 * 1024
        )
        let screenshotResult = ManagedDirectoryPruner.prune(
            directory: AppStorageDirectories.screenshots,
            allowedExtensions: ["png"],
            maxFileCount: 500,
            maxTotalBytes: 5 * 1024 * 1024 * 1024
        )
        let danmakuResult = ManagedDirectoryPruner.prune(
            directory: AppStorageDirectories.danmaku,
            allowedExtensions: ["json"],
            maxFileCount: 300,
            maxTotalBytes: 256 * 1024 * 1024,
            // 第二道保险，并把「哪些是永久的」这份清单留在数据归属方（DanmakuKit）。
            preservedFileNames: DanmakuCache.permanentFileNames,
            // 白名单：本目录里**只有弹幕正文**是可重下的缓存，其余（映射 / 片头提示 /
            // 别名 / AniSkip 的 MAL ID）都是永久数据。用白名单而不是逐个排除，是因为
            // 淘汰按 mtime **最旧优先**，而永久文件恰恰最少被写 —— 原实现只排除了
            // mapping.json，另外三个一直在被优先删除（表现为别名与 AniSkip 反复回源、
            // 离线「跳过片头」失效）。白名单 fail-safe：将来新增永久文件天然安全。
            prunableFileNamePrefixes: [DanmakuCache.commentsFilePrefix]
        )

        let removedCount = subtitleResult.removedCount + screenshotResult.removedCount + danmakuResult.removedCount
        let failedCount = subtitleResult.failedRemovalCount + screenshotResult.failedRemovalCount + danmakuResult.failedRemovalCount
        let skippedUnsafeRoot = subtitleResult.skippedUnsafeRoot || screenshotResult.skippedUnsafeRoot || danmakuResult.skippedUnsafeRoot
        // 数据库体积一并上报：它不参与删除（不是缓存），但「占了多少」必须可见 ——
        // 之前 Bangumi.sqlite 从未进过维护视野，体积在 App 内完全查不到。
        // 只在本来就要写日志时带上它，避免给每日无操作的空跑加一条 info 噪声。
        let databaseBytes = AppStorageDirectories.databaseTotalBytes()
        guard removedCount > 0 || failedCount > 0 || skippedUnsafeRoot else { return }
        let fields: [String: DiagnosticValue] = [
            "subtitle_files": .integer(Int64(subtitleResult.removedCount)),
            "screenshot_files": .integer(Int64(screenshotResult.removedCount)),
            "danmaku_files": .integer(Int64(danmakuResult.removedCount)),
            "freed_bytes": .integer(subtitleResult.removedBytes + screenshotResult.removedBytes + danmakuResult.removedBytes),
            "failed_files": .integer(Int64(failedCount)),
            "unsafe_root": .boolean(skippedUnsafeRoot),
            "database_bytes": .integer(databaseBytes),
        ]
        if failedCount > 0 || skippedUnsafeRoot {
            AppDiagnostics.logWarning("存储定期清理未完全执行", fields: fields)
        } else {
            AppDiagnostics.logInfo("存储定期清理完成", fields: fields)
        }
    }

    /// 跑一次数据库淘汰（媒体元数据缓存）。
    ///
    /// 与文件清理**分开收口**：文件那套是 `ManagedDirectoryPruner` 的通用淘汰，
    /// 数据库淘汰要看自己的两张上限（条数 / 体积）并且可能 `VACUUM`，语义不同。
    ///
    /// 只能从 `queue` 上调用（读 `databaseMaintenance` 的前提，见 `performMaintenance`）。
    private func runDatabaseMaintenance() {
        guard let work = databaseMaintenance else { return }
        Task { await work() }
    }
}

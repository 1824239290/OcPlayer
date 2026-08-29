import DiagnosticsKit
import Foundation

/// Storage owned by OcPlayer. Maintenance must never walk parent user folders.
enum AppStorageDirectories {
    static let importedSubtitles = URL.applicationSupportDirectory
        .appending(path: "OcPlayer/Subtitles", directoryHint: .isDirectory)
    static let screenshots = URL.picturesDirectory
        .appending(path: "OcPlayer", directoryHint: .isDirectory)
    static let danmaku = URL.applicationSupportDirectory
        .appending(path: "OcPlayer/Danmaku", directoryHint: .isDirectory)
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

    private func performMaintenance() {
        AppDiagnostics.logger.performMaintenance()

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
            // mapping.json 是永久性的剧集映射，被当普通缓存删掉会让同一集反复回源网关。
            preservedFileNames: ["mapping.json"]
        )

        let removedCount = subtitleResult.removedCount + screenshotResult.removedCount + danmakuResult.removedCount
        let failedCount = subtitleResult.failedRemovalCount + screenshotResult.failedRemovalCount + danmakuResult.failedRemovalCount
        let skippedUnsafeRoot = subtitleResult.skippedUnsafeRoot || screenshotResult.skippedUnsafeRoot || danmakuResult.skippedUnsafeRoot
        guard removedCount > 0 || failedCount > 0 || skippedUnsafeRoot else { return }
        let fields: [String: DiagnosticValue] = [
            "subtitle_files": .integer(Int64(subtitleResult.removedCount)),
            "screenshot_files": .integer(Int64(screenshotResult.removedCount)),
            "danmaku_files": .integer(Int64(danmakuResult.removedCount)),
            "freed_bytes": .integer(subtitleResult.removedBytes + screenshotResult.removedBytes + danmakuResult.removedBytes),
            "failed_files": .integer(Int64(failedCount)),
            "unsafe_root": .boolean(skippedUnsafeRoot),
        ]
        if failedCount > 0 || skippedUnsafeRoot {
            AppDiagnostics.logWarning("存储定期清理未完全执行", fields: fields)
        } else {
            AppDiagnostics.logInfo("存储定期清理完成", fields: fields)
        }
    }
}

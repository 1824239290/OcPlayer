import Foundation

/// 简单的文本日志落盘，方便在 Console.app 之外直接看播放链路。
/// 所有播放相关模块（ErikaKit / App 层）都往同一个文件追加。
/// 路径：~/Library/Logs/OcPlayer/playback.log
public enum PlaybackLog {
    private static let sink = LogFileSink()

    public static var fileURL: URL { sink.fileURL }

    public static func append(_ message: String) {
        sink.append(message)
    }
}

private final class LogFileSink: @unchecked Sendable {
    private let lock = NSLock()
    let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("Logs/OcPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("playback.log")
    }

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}

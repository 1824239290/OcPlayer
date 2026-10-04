import DiagnosticsKit
import Foundation

/// 图片字节的**自有**磁盘缓存（不依赖 `URLCache`）。
///
/// ## 为什么不用 `URLCache`
///
/// 离线出图曾经完全依赖 `URLCache`，实测**不可靠**：索引库里条目明明在
/// （`storage_policy = 0`、服务器发的是 `Cache-Control: public, max-age=31536000,
/// immutable`），但**换一个 `URLCache` 实例（= 重启 App）就再也读不回来**——
/// 同一个实例内能命中，跨实例一律 miss。表现就是用户报的「重启后图片全变占位符」。
///
/// 这个行为既无法在单元测试里断言（直接调 `cachedResponse(for:)` 是能读到的，
/// 走 `URLSession` 才暴露），也没法从 Foundation 拿到解释。图片能不能离线看是**用户
/// 可见的功能**，不该建在一个我们观察不透、也无法回归的机制上。
///
/// 所以字节自存：文件名 = 规范化键的稳定哈希，内容 = 原始响应体（JPEG/PNG）。
/// 读、写、淘汰全部由我们控制，可测、可观察、可解释。
///
/// ## 键的稳定性
///
/// 文件名来自 `ImageCacheKey`（已抹掉服务器地址）。**注意不能把 App 版本号算进键**：
/// 客户端身份头里含 `Version="0.2.0 (506)"` 而构建号 = git 提交数，用它当键会让
/// **每次发版都丢掉全部图片缓存**（实测 Build 505 与 506 的键哈希确实不同）。
/// 归属只需「哪台服务器 + 哪个账号」，见 `ImageCacheKey.authIdentity`。
final class ImageBlobStore: @unchecked Sendable {

    /// 默认上限 256 MB。与 `URLCache` 那份并存时总占用仍受控（512 + 256）。
    static let defaultMaxBytes = 256 * 1024 * 1024

    private let directory: URL
    private let maxBytes: Int
    private let lock = NSLock()
    /// 目录体积缓存：`load` 热路径上不该每次都枚举目录（海报墙一次几十张）。
    private var cachedBytes: Int?

    init(directory: URL, maxBytes: Int = ImageBlobStore.defaultMaxBytes) {
        self.directory = directory
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// 缓存键 → 文件名。**跨进程稳定**（`FNV1a`，非 `hashValue`）。
    static func fileName(for key: String) -> String {
        FNV1a.hex(of: key) + ".img"
    }

    func data(forKey key: String) -> Data? {
        let url = directory.appendingPathComponent(Self.fileName(for: key))
        // 读取时刷新 mtime：淘汰按「最久未使用」而不是「最早写入」，
        // 否则常看的老片海报会被新片挤掉。
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    func store(_ data: Data, forKey key: String) {
        guard !data.isEmpty else { return }
        let url = directory.appendingPathComponent(Self.fileName(for: key))
        do {
            try data.write(to: url, options: .atomic)
            lock.lock()
            cachedBytes = nil          // 让下次统计重新算
            lock.unlock()
            pruneIfNeeded()
        } catch {
            // 写不进去（磁盘满 / 权限）不该影响这次显示：图已经拿到手了。
            DiagnosticLogger(category: "Image").warning("图片字节写盘失败", fields: [
                "error": .string("\(error)"),
            ])
        }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lock.lock()
        cachedBytes = 0
        lock.unlock()
    }

    /// 当前占用（带缓存，供设置页显示）。
    var totalBytes: Int {
        lock.lock()
        if let cachedBytes {
            lock.unlock()
            return cachedBytes
        }
        lock.unlock()
        let bytes = Self.directorySize(directory)
        lock.lock()
        cachedBytes = bytes
        lock.unlock()
        return bytes
    }

    /// 超上限时按 mtime 最旧优先删。
    private func pruneIfNeeded() {
        let files = Self.filesByAge(directory)
        var total = files.reduce(0) { $0 + $1.size }
        guard total > maxBytes else {
            lock.lock(); cachedBytes = total; lock.unlock()
            return
        }
        // 删到上限的 90%：留出余量，免得每次写入都触发一轮扫描。
        let target = Int(Double(maxBytes) * 0.9)
        for file in files where total > target {
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
        lock.lock(); cachedBytes = total; lock.unlock()
    }

    private static func directorySize(_ directory: URL) -> Int {
        filesByAge(directory).reduce(0) { $0 + $1.size }
    }

    private static func filesByAge(_ directory: URL) -> [(url: URL, size: Int, date: Date)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name -> (URL, Int, Date)? in
            let url = directory.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? NSNumber,
                  let date = attrs[.modificationDate] as? Date
            else { return nil }
            return (url, size.intValue, date)
        }
        .sorted { $0.2 < $1.2 }
    }
}

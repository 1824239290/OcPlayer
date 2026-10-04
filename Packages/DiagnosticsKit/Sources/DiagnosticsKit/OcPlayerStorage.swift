import Foundation

/// OcPlayer 自有存储目录的**唯一事实源**。
///
/// 背景：`Application Support/OcPlayer/<子目录>` 这条路径原先在 6 处各自手拼
/// （凭据、Bangumi 库、弹幕、外挂字幕 ×2、图片缓存、App 维护脚本），于是：
/// - 路径写歪了不会编译报错，只会在运行时静默建出第二份目录；
/// - **存储维护看不见自己不知道的目录** —— `Bangumi.sqlite` 就是这么漏掉的：
///   它建在 `OcPlayer/` 下，却从没被 `AppStorageMaintenance` 管过（体积不可见、
///   永不清理、也没有上限）。这条不是理论风险，是实际发生过的事。
///
/// 因此：**新增落盘一律经本类型取路径**，再在 `AppStorageDirectories`
/// （App 层）登记进维护清单。
public enum OcPlayerStorage {

    /// 应用数据根目录（`Application Support/OcPlayer`）。
    ///
    /// 用 `applicationSupportDirectory` 而不是 `cachesDirectory`：这里的文件是
    /// **用户数据**（凭据、追番进度、弹幕映射），不是系统可以随手清掉的缓存。
    /// iOS 上该目录不参与系统清理，且可打 `isExcludedFromBackup`。
    public static var defaultRoot: URL {
        applicationSupport.appending(path: directoryName, directoryHint: .isDirectory)
    }

    /// 目录名。**改它等于丢掉所有用户的既有数据**，别动。
    public static let directoryName = "OcPlayer"

    /// 根目录下的一个子目录。`base` 只给测试注入临时目录用。
    public static func directory(_ name: String, in base: URL? = nil) -> URL {
        let root = base ?? defaultRoot
        return root.appending(path: name, directoryHint: .isDirectory)
    }

    /// 根目录下的一个文件。`base` 只给测试注入临时目录用。
    public static func file(_ name: String, in base: URL? = nil) -> URL {
        let root = base ?? defaultRoot
        return root.appending(path: name)
    }

    /// 建目录（幂等）。子目录写入前一律先调它，别指望调用方层层建。
    @discardableResult
    public static func ensureDirectory(_ name: String, in base: URL? = nil) throws -> URL {
        let url = directory(name, in: base)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 应用数据根目录（未附加 `OcPlayer`）。
    ///
    /// ⚠️ 只在本类型内部与确实需要「系统级 Application Support」的调用方使用；
    /// 业务取路径请用 `defaultRoot` / `directory(_:in:)`。
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL.applicationSupportDirectory
    }
}

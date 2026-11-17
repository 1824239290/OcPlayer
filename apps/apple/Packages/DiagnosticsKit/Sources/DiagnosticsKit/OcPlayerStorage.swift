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
///
/// ⚠️ 但**只有用户数据登记进那张清单**。可再生缓存（图片字节等）走
/// `cachesRoot` / `cacheDirectory(_:in:)`：它们不在 `Application Support` 下，
/// 由各自的容量上限自管（`URLCache` 512 MB + `ImageBlobStore` 256 MB），
/// 也不该被「按旧优先淘汰」的维护器当普通文件处理。
public enum OcPlayerStorage {

    /// 应用数据根目录（`Application Support/OcPlayer`）。
    ///
    /// 用 `applicationSupportDirectory` 而不是 `cachesDirectory`：这里的文件是
    /// **用户数据**（凭据、追番进度、弹幕映射），不是系统可以随手清掉的缓存。
    /// iOS 上该目录不参与系统清理，且可打 `isExcludedFromBackup`。
    ///
    /// 隔离运行（见 `isIsolated`）时换成临时目录 —— 自动化不许碰真实用户数据。
    public static var defaultRoot: URL {
        if isIsolated { return isolationRoot }
        return applicationSupport.appending(path: directoryName, directoryHint: .isDirectory)
    }

    // MARK: - 自动化隔离

    /// 自动化（AppTests / 验收脚本）的隔离开关：环境变量 **`OCPLAYER_ISOLATED_STORAGE=1`**。
    ///
    /// ## 为什么需要它
    ///
    /// `AppTests` 跑在 **App 宿主进程**里（`TEST_HOST = OcPlayer.app`），宿主照样装配
    /// 真实存储与偏好 —— 于是「跑一次测试」就把开发者本机的**真实数据**读写了一遍。
    /// 实测过一次（2026-10-16，macOS 全量用例）：跑完 `~/Library/Application Support/OcPlayer/`
    /// 下 `credentials.json`、`Media.sqlite-wal`、`Bangumi.sqlite-wal` 与真实偏好 plist 的
    /// mtime 全落在测试窗口内。凭据内容当时没坏，**但那是运气不是设计** —— 一个会写
    /// 开发机凭据文件的测试套件迟早会把它写坏。
    ///
    /// ## 打开后
    ///
    /// * 存储根（凭据 / 各 sqlite / 图片缓存 / 弹幕 / 字幕）→ `临时目录/OcPlayerAutomation`；
    /// * App 偏好默认域（`defaultPreferences`）→ 隔离根下的独立 plist。
    ///
    /// 生产（双击 App、真机验收）不设它，行为与从前**完全一致**。
    public static var isIsolated: Bool {
        ProcessInfo.processInfo.environment["OCPLAYER_ISOLATED_STORAGE"] == "1"
    }

    /// 隔离运行时的数据根。放临时目录：进程退出后由系统回收，多次运行之间也不互相串。
    public static var isolationRoot: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "OcPlayerAutomation", directoryHint: .isDirectory)
    }

    /// App 偏好的默认域（`ServerStore(defaults:)` / `AppModel(preferences:)` 等的默认值）。
    ///
    /// 正常就是 `.standard`；隔离运行时换成隔离根里的独立 plist —— `UserDefaults(suiteName:)`
    /// 认「像路径的名字」，于是隔离运行既**不碰真实偏好域**，也不在 `~/Library/Preferences`
    /// 留下垃圾。
    ///
    /// ⚠️ **边界**：视图层的 `@AppStorage`（50 处）仍读 `.standard`。那些键只在用户真的
    /// 去点开关时才会写，测试不点；隔离的是**App 自有的 store 与偏好域**（服务器档案、
    /// 首页骨架、TMDB 设置等）——正是测试宿主在启动期会写的那一批。
    public static var defaultPreferences: UserDefaults {
        guard isIsolated else { return .standard }
        try? FileManager.default.createDirectory(
            at: isolationRoot, withIntermediateDirectories: true)
        let path = isolationRoot.appending(path: "preferences").path
        if let isolated = UserDefaults(suiteName: path) { return isolated }
        // 兜底：万一路径式 suite 不被接受，退到进程级 suite —— 仍然碰不到真实域。
        return UserDefaults(
            suiteName: "dev.jumusu.OcPlayer.automation.\(ProcessInfo.processInfo.processIdentifier)"
        ) ?? .standard
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

    // MARK: - 可再生缓存（`Caches/`）

    /// 可再生缓存的根目录（`Caches/OcPlayer`）。
    ///
    /// **与 `defaultRoot` 的分工**（放错一边就是 bug，不是风格问题）：
    ///
    /// | | `defaultRoot`（Application Support） | `cachesRoot`（Caches） |
    /// |---|---|---|
    /// | 内容 | 用户数据：凭据、追番进度、弹幕映射、外挂字幕 | 可再生数据：图片字节、URL 响应 |
    /// | 丢了会怎样 | 用户要重新登录 / 丢进度 | 重新下载即可 |
    /// | iOS 系统存储吃紧 | **不回收** | **会被系统回收** |
    /// | iCloud / 备份 | 会进 | 不进 |
    ///
    /// 把图片缓存放进 Application Support 的实际后果：几百 MB 的**可重下**字节
    /// 进用户的 iCloud 备份，并且在系统存储吃紧时拿不回来（实测本机曾达 370 MB，
    /// 而两套缓存的上限相加是 768 MB）。
    ///
    /// 隔离运行（见 `isIsolated`）时同样落到隔离根下 —— 否则跑一次测试就会写开发机
    /// 真实的 `~/Library/Caches`。
    public static var cachesRoot: URL {
        if isIsolated {
            return isolationRoot.appending(path: "Caches", directoryHint: .isDirectory)
        }
        return caches.appending(path: directoryName, directoryHint: .isDirectory)
    }

    /// 缓存根目录下的一个子目录。`base` 只给测试注入临时目录用。
    public static func cacheDirectory(_ name: String, in base: URL? = nil) -> URL {
        (base ?? cachesRoot).appending(path: name, directoryHint: .isDirectory)
    }

    /// 系统缓存根（未附加 `OcPlayer`）。
    ///
    /// ⚠️ 只在本类型内部与确实需要「系统级 Caches」的调用方使用；
    /// 业务取路径请用 `cachesRoot` / `cacheDirectory(_:in:)`。
    public static var caches: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL.cachesDirectory
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

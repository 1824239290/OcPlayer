import AppDesignKit
import DiagnosticsKit
import Foundation

/// 记住每个服务器**用过的**图片缓存身份（`ImagePipeline.cacheIdentity` 的产物）。
///
/// ## 为什么必须记
///
/// 登录页的海报墙要在**没有 token** 的时候复原历史图片的缓存键，而键里含一个由
/// `DeviceId + Token` 派生的身份哈希（见 `ImageCacheKey.authIdentity`）。而登录页
/// 出现的时机恰恰是「刚退出登录」或「token 刚过期」——这两条路径**都会把 token
/// 删掉**（`ServerStore.signOut(id:)` → `tokens.delete`，见 `AppModel+Session` 的
/// `signOut()` 与 `handleAuthenticationRequired`）。那一刻再去算就晚了。
///
/// ## 为什么是**一串**而不是一个
///
/// 第一版只存「上次生效的那一个」，实测踩了：Jellyfin 的 **access token 会轮换**，
/// 而身份是拿 token 哈希出来的——轮换一次，全部缓存键跟着变，墙上 47 张海报
/// **一张都查不到**，而字节其实一张没少地躺在磁盘上（登录页于是静默退成程序化封面，
/// 不报错）。本机的 URL 缓存里翻出过 **5 个**不同的历史身份，就是这个原因。
///
/// 所以身份改成**记一串**（最近的在前），复原键时逐个试。试错只是多一次「文件在不在」
/// 的判断，代价可以忽略；试不到才是真的看不见图。
///
/// ## 首次升级时把历史捞回来
///
/// 光改成记一串还不够：**已经丢掉的那个身份补不回来**。但磁盘上还有一份记录——
/// `URLCache` 的键就是那条带 `_auth=<身份>` 的规范化 URL（见
/// `ImageCacheKey.canonicalURL`），也就是「这批字节当初是用哪个身份写进去的」唯一的
/// 现存证据。所以首次运行会只读地扫一遍那个库、把里面的身份并进历史。
///
/// 扫的是文件字节而不是 SQLite：`Cache.db` 正被系统 URLCache 持有，用 SQLite 打开它
/// 要处理锁与 schema（那是私有格式、会随系统变），而这里只需要「文件里出现过哪些
/// `_auth=` 值」。读不出来就当作没扫到，不抛错、不阻塞——它是**提示**，不是依赖。
///
/// ## 存哈希是安全的
///
/// 存的是 `FNV1a("DeviceId=…;Token=…;")` 的前 12 位十六进制，**推不回 token**；
/// 而它本来就是磁盘缓存文件名的一部分（`ImageBlobStore.fileName`），
/// 没有引入任何新的敏感信息。
@MainActor
enum ImageCacheIdentityStore {

    /// 每个服务器最多记几个历史身份。5 个是实测见过的量级，留一倍余量。
    static let historyLimit = 8

    /// 从 URL 缓存里最多捞几个身份。那是个全局池子（规范化 URL 抹掉了 host，
    /// 无法归属到某台服务器），捞多了只是让复原时多几次判断。
    static let discoveredLimit = 12

    /// 身份哈希的固定长度（`authIdentity` 取 FNV1a 十六进制的前 12 位）。
    static let identityLength = 12

    private static let prefix = "dev.jumusu.ocplayer.imageCacheIdentity."
    private static let discoveredKey = "dev.jumusu.ocplayer.imageCacheIdentities.discovered"
    /// 扫描每个进程只做一次。
    private static var didScanURLCache = false

    // MARK: - 记录

    /// 记下某个服务器当前生效的缓存身份。会话落地时调用（见 `AppModel.activate`）。
    ///
    /// **登出时刻意不清**：清掉就等于把「登录页该显示什么」一起清掉了，而那正是
    /// 这个值唯一的存在理由。
    static func remember(identity: String, tenant: String) {
        guard !identity.isEmpty, !tenant.isEmpty else { return }
        var list = history(for: tenant)
        list.removeAll { $0 == identity }
        list.insert(identity, at: 0)
        UserDefaults.standard.set(Array(list.prefix(historyLimit)), forKey: prefix + tenant)
    }

    // MARK: - 读取

    /// 某个服务器**用过的**全部身份，最近的在前。空 = 一次都没记过（调用方退程序化封面）。
    ///
    /// 除本服务器的历史之外，还会带上从 URL 缓存里捞到的全局身份池——那些身份属于
    /// 哪台服务器已经无从考证，但「多试一个哈希」的代价只是一次文件存在性判断。
    static func identities(for tenant: String) -> [String] {
        var result = history(for: tenant)
        for identity in discoveredIdentities() where !result.contains(identity) {
            result.append(identity)
        }
        return result
    }

    /// 最近一次生效的身份。没有历史时返回 nil。
    static func identity(for tenant: String) -> String? {
        history(for: tenant).first
    }

    /// 本服务器记过的历史（不含全局捞回来的那些）。
    static func history(for tenant: String) -> [String] {
        guard !tenant.isEmpty else { return [] }
        let defaults = UserDefaults.standard
        // 旧版这里存的是**一个字符串**，新版存数组。两者键相同，读法不冲突
        // （`stringArray` 读字符串返回 nil，反之亦然），所以旧值能平滑升上来。
        if let list = defaults.stringArray(forKey: prefix + tenant) {
            return list.filter { !$0.isEmpty }
        }
        if let legacy = defaults.string(forKey: prefix + tenant), !legacy.isEmpty {
            return [legacy]
        }
        return []
    }

    // MARK: - 从 URL 缓存捞历史身份

    private static func discoveredIdentities() -> [String] {
        let defaults = UserDefaults.standard
        var stored = defaults.stringArray(forKey: discoveredKey) ?? []
        guard !didScanURLCache else { return stored }
        didScanURLCache = true

        let found = scanURLCacheForIdentities()
        guard !found.isEmpty else { return stored }
        stored = Array(Set(stored).union(found)).sorted()
        defaults.set(stored, forKey: discoveredKey)
        return stored
    }

    /// 只读扫一遍图片缓存目录里的 URL 缓存库。
    static func scanURLCacheForIdentities() -> Set<String> {
        // 缓存已从 `Application Support` 搬到 `Caches`，这里必须跟着走，
        // 否则扫的是一个永远不存在的目录（空结果 = 登录页海报墙退化成程序化封面）。
        let directory = OcPlayerStorage.cacheDirectory("ImageCache")
        var found: Set<String> = []
        // `-wal` 里可能躺着还没并回主库的新记录，两个都看。
        for name in ["Cache.db", "Cache.db-wal"] {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
            found.formUnion(authIdentities(in: data))
            if found.count >= discoveredLimit { break }
        }
        return found
    }

    /// 从一段字节里挑出所有 `_auth=<12 位十六进制>` 的值。纯函数，便于直接断言。
    static func authIdentities(in data: Data) -> Set<String> {
        let marker = Data("_auth=".utf8)
        var result: Set<String> = []
        var searchStart = data.startIndex

        while result.count < discoveredLimit,
              let range = data.range(of: marker, in: searchStart..<data.endIndex) {
            let valueStart = range.upperBound
            guard let valueEnd = data.index(valueStart, offsetBy: identityLength, limitedBy: data.endIndex),
                  data.distance(from: valueStart, to: valueEnd) == identityLength else { break }

            // 找到就跳过这一整个值，避免在同一个值内部反复匹配。
            searchStart = valueEnd

            let value = String(decoding: data[valueStart..<valueEnd], as: UTF8.self)
            // 只要纯小写十六进制：`_auth=none`（公开图床）之类的会被这一步滤掉。
            if value.allSatisfy({ $0.isHexDigit && (!$0.isLetter || $0.isLowercase) }) {
                result.insert(value)
            }
        }
        return result
    }
}

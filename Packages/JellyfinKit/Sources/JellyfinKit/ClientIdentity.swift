import Foundation

/// 上报给 Jellyfin 的客户端身份。`DeviceId` 必须**跨启动稳定**（服务器拿它做设备管理），
/// 所以首用即生成、存 UserDefaults；DeviceName 取一次机器名后同样缓存。
public enum ClientIdentity {
    public static let clientName = "OcPlayer"

    /// Jellyfin client version derived from the host app's version metadata.
    /// Release builds therefore report the same marketing version and build
    /// number that users see in Finder / Settings instead of a duplicated
    /// source constant that can drift during packaging.
    public static var version: String {
        version(in: .main)
    }

    /// Product-token-safe app version for User-Agent strings. Build metadata is
    /// intentionally omitted so callers keep the `OcPlay/<semver> (...)` shape.
    public static var marketingVersion: String {
        marketingVersion(in: .main)
    }

    private static let deviceIDKey = "dev.jumusu.ocplayer.deviceId"
    private static let deviceNameKey = "dev.jumusu.ocplayer.deviceName"

    /// 用户自定义 User-Agent（设置页填写；nil = 用系统默认）。**全局生效**，
    /// 不区分服务器档案（设置页「网络」分组，对所有服务器一视同仁）。
    ///
    /// 部分媒体服开了播放器白名单，按 UA 拒绝非白名单客户端的拉流请求；用户把
    /// UA 改成白名单内的播放器即可通过。在**每次请求时**读取（不缓存进会话），
    /// 设置里改完立即生效，不需要重连。API 请求、播放拉流三条发送口
    /// （`EmbySession.data` / `JellyfinServer.send` / `PlaybackController` 的
    /// `open_with_headers`）共用这一个取值。
    public static let customUserAgentKey = "dev.jumusu.ocplayer.customUserAgent"

    public static var customUserAgent: String? {
        let raw = UserDefaults.standard.string(forKey: customUserAgentKey) ?? ""
        // 头值里不能有控制字符（换行、制表…）：`URLRequest.setValue` 遇到这种值
        // 会把**整条头**静默丢掉，不报错——用户以为生效了，其实发的是系统默认。
        // 在唯一的读取口统一剔除，三条发送路径一并覆盖。
        let cleaned = raw
            .components(separatedBy: .controlCharacters)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func version(in bundle: Bundle) -> String {
        let shortVersion = nonEmptyInfoValue(
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        )
        let build = nonEmptyInfoValue(
            bundle.object(forInfoDictionaryKey: "CFBundleVersion")
        )

        switch (shortVersion, build) {
        case let (.some(shortVersion), .some(build)) where build != shortVersion:
            return "\(shortVersion) (\(build))"
        case let (.some(shortVersion), _):
            return shortVersion
        case let (_, .some(build)):
            return build
        default:
            return "development"
        }
    }

    static func marketingVersion(in bundle: Bundle) -> String {
        nonEmptyInfoValue(
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        ) ?? nonEmptyInfoValue(
            bundle.object(forInfoDictionaryKey: "CFBundleVersion")
        ) ?? "development"
    }

    private static func nonEmptyInfoValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let identityLock = NSLock()

    /// 稳定设备 ID（UUID，首用生成）。读改写加锁：并发首用会双写两个不同值。
    public static var deviceID: String {
        identityLock.lock()
        defer { identityLock.unlock() }
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: deviceIDKey) {
            return stored
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: deviceIDKey)
        return id
    }

    /// 展示用设备名。不用 AppKit/UIKit 取「漂亮名字」：那些 API 有主线程约束，
    /// 机器名对服务器只是展示，`ProcessInfo.hostName`（如 "macbook.local"）足够。
    public static var deviceName: String {
        identityLock.lock()
        defer { identityLock.unlock() }
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: deviceNameKey) {
            return stored
        }
        let name = ProcessInfo.processInfo.hostName
        defaults.set(name, forKey: deviceNameKey)
        return name
    }

    /// Jellyfin `Authorization: MediaBrowser …` 头。API 客户端、图片管线和
    /// 内核 `open_with_headers`（含设置页直连）共用同一套身份字段，避免出现
    /// 硬编码 DeviceId / 版本漂移的第二套客户端。
    ///
    /// 字段必须按固定顺序拼接：Dictionary 字面量每次构造的迭代顺序随实例种子抖动
    /// （并发/多次调用会产出键序不同的字符串）。语义等价的头若字节不同，
    /// 上层以其哈希做缓存键时（如 RemoteImage 的凭证指纹）会误判「凭证变了」。
    public static func mediaBrowserAuthorizationHeader(
        userId: String? = nil,
        token: String? = nil
    ) -> String {
        authorizationHeader(scheme: "MediaBrowser", userId: userId, token: token)
    }

    /// 按产品分叉的认证头。**scheme 是两家唯一的分叉点**：Jellyfin 用
    /// `MediaBrowser`，Emby 用自己的 `Emby`（Emby 客户端一贯的写法）。
    /// 其余字段与拼接顺序完全一致，缓存键语义不受影响。
    ///
    /// ## 为什么要带 `UserId`
    ///
    /// 图片缓存的身份取的是「**哪台服务器 + 哪个账号**」（见 `ImageCacheKey.authIdentity`），
    /// 而这条头里原本只有 `DeviceId` 与 `Token` 够格当身份——`Token` **不是**账号：
    /// 服务端每次重新登录都会发一个新 token（同一账号、同一份可见范围）。拿它当身份，
    /// 等于每登录一次就把整个图片缓存另存一份：实测本机攒出过 **7 份**，512MB 的
    /// 图片缓存被切成七份、每份都更早被淘汰。`UserId` 才是账号的稳定标识——
    /// 换账号会变（正确），重新登录不会变。
    ///
    /// 服务端**不认识**这个字段，会照旧忽略（`MediaBrowser` 头的解析是按键取值）；
    /// 它是给缓存键用的，顺带让 `RemoteImage` 的凭证指纹也不再随 token 漂移。
    ///
    /// ## 为什么带缓存
    ///
    /// 这是**每张卡片每次 body** 都会走的一条路：`JellyfinServer.authorizationHeader`
    /// 与 `EmbySession.authorizationHeader` 都是计算属性，`DesignSystem` 里 7 处在
    /// `imageTarget` 系列里读它。而拼一次头要读 2 次 UserDefaults（`Device`/`DeviceId`，
    /// 各带 NSLock）加 2 次 Info.plist 查询（`Version`）—— 实测 **11.49 µs/次**，
    /// 一屏 20 张卡就是 **230 µs**，纯粹是「完全不变的数据反复现算」。
    ///
    /// ## 为什么缓存整条头，而不是分别缓存 `deviceID` / `deviceName` / `version`
    ///
    /// 因为 `version(in: bundle)` 是**可注入 Bundle** 的，而 `ClientIdentityTests`
    /// 确实用临时 Bundle 连测了 5 种版本组合（`"1.2.3 (45)"` / `"99"` / `"development"` 等）。
    /// 给 `version(in:)` 加无键全局缓存会**跨用例串台**。
    ///
    /// 只缓存拼好的头就绕开了这件事：这里用的 `version` 是 `version(in: .main)`，
    /// 进程内恒定；`deviceID` / `deviceName` 都只在首用时写一次 UserDefaults
    /// （全仓无第二写入点）。`version(in:)` 本体**一行都不用改**。
    ///
    /// ⚠️ 将来若新增「重设设备 ID / 改名」这类功能，**必须**同时清掉这张缓存
    /// （见 `resetHeaderCacheForTesting()` 同一处），否则会一直发旧设备身份。
    public static func authorizationHeader(
        scheme: String,
        userId: String? = nil,
        token: String? = nil
    ) -> String {
        let key = HeaderCacheKey(scheme: scheme, userId: userId ?? "", token: token ?? "")
        if let cached = cachedAuthorizationHeader(for: key) { return cached }
        let header = composeAuthorizationHeader(scheme: scheme, userId: userId, token: token)
        storeAuthorizationHeader(header, for: key)
        return header
    }

    /// 实际拼接。抽出来是为了让用例能拿到「不走缓存」的参考值做对拍。
    static func composeAuthorizationHeader(
        scheme: String,
        userId: String? = nil,
        token: String? = nil
    ) -> String {
        var fields: [(String, String)] = [
            ("Client", clientName),
            ("Device", deviceName),
            ("DeviceId", deviceID),
            ("Version", version),
        ]
        if let userId, !userId.isEmpty {
            fields.append(("UserId", userId))
        }
        if let token, !token.isEmpty {
            fields.append(("Token", token))
        }
        return scheme + " " + fields.map { "\($0.0)=\"\($0.1)\"" }.joined(separator: ", ")
    }

    // MARK: - 认证头缓存

    /// 缓存键。**必须含 token**：只按 `userId` 缓存会让 token 轮换后仍发旧 token。
    private struct HeaderCacheKey: Hashable {
        let scheme: String
        let userId: String
        let token: String
    }

    /// 上限 8 条。实际只会用到 1–2 条（当前服务器 + 可能的一台备机），
    /// 留余量是为了「切换服务器」时不必立刻清空。
    private static let headerCacheLimit = 8
    private static let headerLock = NSLock()
    nonisolated(unsafe) private static var headerCache: [HeaderCacheKey: String] = [:]

    private static func cachedAuthorizationHeader(for key: HeaderCacheKey) -> String? {
        headerLock.lock()
        defer { headerLock.unlock() }
        return headerCache[key]
    }

    private static func storeAuthorizationHeader(_ header: String, for key: HeaderCacheKey) {
        headerLock.lock()
        defer { headerLock.unlock() }
        if headerCache.count >= headerCacheLimit, headerCache[key] == nil {
            headerCache.removeAll(keepingCapacity: true)
        }
        headerCache[key] = header
    }

    /// 测试专用：清空认证头缓存。
    ///
    /// 生产**不需要**它 —— 缓存键含 token，换账号/重登自然不命中。但用例要断言
    /// 「缓存值 == 现拼值」就必须能回到冷状态。
    static func resetHeaderCacheForTesting() {
        headerLock.lock()
        headerCache.removeAll()
        headerLock.unlock()
    }

}

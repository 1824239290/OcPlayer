import Foundation

/// 凭据的落盘仓库：**单个 JSON 文件**，位于 Application Support，**排除备份**。
///
/// ## 为什么不用 Keychain
///
/// 本项目发行包统一 ad-hoc 签名（见 README「下载」与 `Config/App.xcconfig`）。
/// Keychain 条目的访问控制绑在代码签名上，于是：
/// - 每次重新构建 cdhash 都变 → 系统当成另一个 App → 开发时每次运行都弹授权框；
/// - AppTests 跑在 **App 宿主**里（`TEST_HOST = OcPlayer.app`），碰凭据的用例同样会弹，
///   CI 上没有 UI 应答，很可能失败或卡住；
/// - 重签名后**凭据会读不出来**——这正是 `DandanplaySettingsStore` 里已经写下的顾虑。
///
/// ## 为什么不用 UserDefaults
///
/// UserDefaults 落在 App 容器里，**会被 iCloud / iTunes 备份原样带走**，而它无法
/// 单独排除备份。对侧载 App 来说，备份是最现实的凭据泄露面。换成一个普通文件后
/// 可以打 `isExcludedFromBackup`，把凭据从备份里摘出去 —— 这是 Keychain 也解决不了的
/// 问题（Keychain 条目同样进加密备份），所以它本身就该做。
///
/// ## 存了什么
///
/// 刻意只收**凭据**（token / refresh token / 密码）与跨会话的认证材料；
/// 服务器地址、用户名、界面偏好等非机密信息仍留在 UserDefaults，避免把整个
/// 偏好体系搬进文件而带来迁移负担。
///
/// 值统一以 base64 存放，因此 string 与 Data 两种 API 共享同一份文件、不会互相踩。
public final class CredentialFileStore: @unchecked Sendable {

    /// 全局实例：三个域包（Jellyfin / Bangumi / MoviePilot）共用同一个文件，
    /// 避免各自算路径算歪。测试可注入独立目录。
    public static let shared = CredentialFileStore()

    private let lock = NSLock()
    private let fileURL: URL
    /// 懒加载缓存；nil = 还没读盘。
    private var cache: [String: String]?

    /// - Parameter directory: 默认 `Application Support/OcPlayer`（`OcPlayerStorage.defaultRoot`）；测试传临时目录。
    public init(directory: URL? = nil, fileName: String = "credentials.json") {
        let base = directory ?? OcPlayerStorage.defaultRoot
        self.fileURL = base.appending(path: fileName)
    }

    /// 落盘位置（测试与诊断用；**不要**写进日志正文）。
    public var url: URL { fileURL }

    // MARK: - 字符串

    public func string(forKey key: String) -> String? {
        guard let encoded = rawValue(forKey: key), let data = Data(base64Encoded: encoded) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    public func setString(_ value: String?, forKey key: String) {
        setRawValue(value.map { Data($0.utf8).base64EncodedString() }, forKey: key)
    }

    // MARK: - Data（Bangumi 的 OAuth 凭证是 JSON 编码后的 Data）

    public func data(forKey key: String) -> Data? {
        rawValue(forKey: key).flatMap { Data(base64Encoded: $0) }
    }

    public func setData(_ value: Data?, forKey key: String) {
        setRawValue(value?.base64EncodedString(), forKey: key)
    }

    // MARK: - 维护

    public func removeValue(forKey key: String) {
        setRawValue(nil, forKey: key)
    }

    /// 清空整个文件（换号 / 登出全清时用）。
    public func removeAll() {
        lock.withLock {
            cache = [:]
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // MARK: - 内部

    private func rawValue(forKey key: String) -> String? {
        lock.withLock {
            loadIfNeeded()
            return cache?[key]
        }
    }

    private func setRawValue(_ value: String?, forKey key: String) {
        lock.withLock {
            loadIfNeeded()
            var store = cache ?? [:]
            if let value {
                store[key] = value
            } else {
                store.removeValue(forKey: key)
            }
            cache = store
            persist(store)
        }
    }

    private func loadIfNeeded() {
        guard cache == nil else { return }
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            cache = [:]
            return
        }
        cache = decoded
    }

    /// 写盘 + 收紧权限 + 排除备份。
    ///
    /// 写失败**不抛错**：凭据写不进去不该让登录流程失败（本次会话内存里仍有值），
    /// 但会在下一次读盘时表现为「没记住登录」，这是可接受的降级。
    private func persist(_ store: [String: String]) {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if store.isEmpty {
                try? FileManager.default.removeItem(at: fileURL)
                return
            }
            let data = try JSONEncoder().encode(store)
            try data.write(to: fileURL, options: [.atomic])
            applyFileHardening()
        } catch {
            // 刻意不用 App 日志（本类型在 DiagnosticsKit 内，且凭据路径不该进日志正文）。
            // 失败只影响「下次启动还记得吗」，不影响本次会话。
        }
    }

    private func applyFileHardening() {
        let manager = FileManager.default
        // 0600：只有本用户可读写（与 UserDefaults plist 同档，不回退）。
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        // 排除备份：这是相对 UserDefaults 的**实质改进**——凭据不再随
        // iCloud / iTunes 备份离开设备。
        var resource = URLResourceValues()
        resource.isExcludedFromBackup = true
        var mutableURL = fileURL
        try? mutableURL.setResourceValues(resource)
        #if os(iOS)
        // 保持 iOS 默认档（首次解锁后可读）：App 要做后台播放上报，锁屏时也得能读，
        // 不能用更严的 .complete。
        try? manager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: fileURL.path)
        #endif
    }
}

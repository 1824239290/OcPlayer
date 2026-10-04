import CoreModel
import DiagnosticsKit
import Foundation
import JellyfinKit
import MetadataKit
import Observation

/// App 层的元数据缓存协调器：建库、包装服务器、供离线读。
///
/// 与 `BangumiCoordinator` 同款职责划分：域包（`MetadataKit`）只懂存储与协议，
/// 路径、生命周期、与 `AppModel` 的接线留在 App 层。
///
/// **测试下不建库**：`setup()` 只在 `AppModel.bootstrap()` 里调，而 bootstrap 在
/// 测试宿主下整段跳过（见 `AppModel+Session`）。未 setup 时 `wrap()` 原样返回内层
/// 服务器，于是测试行为与引入本模块之前完全一致、也不会碰真实 Application Support。
@MainActor
@Observable
final class MetadataCoordinator {

    /// 当前是否可用（建库完成）。false 时所有缓存功能降级为「直通」。
    private(set) var isReady = false
    /// 建库失败的原因（供设置页/诊断展示）。
    private(set) var setupError: String?
    /// 上次体积统计（字节，含 WAL）。
    private(set) var databaseBytes: Int64 = 0

    @ObservationIgnored private var store: MetadataStore?
    @ObservationIgnored private var setupTask: Task<Void, Never>?
    @ObservationIgnored private var currentTenant: TenantID?

    init() {}

    // MARK: - 建库

    /// 启动时调用一次，异步建库（不阻塞主线程）。
    ///
    /// - Parameter directory: 数据根目录；nil = `OcPlayerStorage.defaultRoot`。
    ///   测试传临时目录。
    func setup(directory: URL? = nil) {
        guard setupTask == nil else { return }
        let root = directory ?? OcPlayerStorage.defaultRoot
        // 目录只是路径，先记下来做体积统计；真正的建库在后台线程。
        databaseDirectory = root
        setupTask = Task.detached(priority: .userInitiated) {
            do {
                let store = try MetadataCache.open(at: root)
                await MainActor.run {
                    self.store = store
                    self.isReady = true
                    self.setupError = nil
                    self.refreshSize()
                }
            } catch {
                AppDiagnostics.logError("媒体元数据库建库失败 error=\(error)")
                // 失败必须复位 setupTask：否则 guard setupTask == nil 短路，
                // 重启前再也无法重试。
                await MainActor.run {
                    self.setupTask = nil
                    self.setupError = "元数据缓存初始化失败：\(error)"
                }
            }
        }
    }

    /// 等建库完成（写穿路径用；未 setup 时立刻返回 false）。
    func waitUntilReady() async -> Bool {
        if isReady { return true }
        guard let setupTask else { return false }
        await setupTask.value
        return isReady
    }

    @ObservationIgnored private var databaseDirectory: URL?

    // MARK: - 包装

    /// 把真实服务器包成写穿缓存版本。
    ///
    /// 未就绪时**原样返回内层**：缓存是可选增强，不该因为建库失败就让整个 App 不能用
    /// （磁盘满 / 权限异常都可能建库失败）。
    func wrap(_ server: any MediaServer) async -> any MediaServer {
        guard await waitUntilReady(), let store else { return server }
        let tenant = TenantID(profile: server.profile)
        currentTenant = tenant
        do {
            try await store.touchTenant(tenant, profile: server.profile)
        } catch {
            AppDiagnostics.logWarning("租户登记失败（不影响使用）", fields: ["error": .string("\(error)")])
        }
        return CachedMediaServer(wrapping: server, store: store, tenant: tenant)
    }

    // MARK: - 离线读

    /// 当前租户的存储句柄（供 `MetadataHydrator` 用）；未就绪时为 nil。
    var activeStore: MetadataStore? { store }

    /// 某个服务器的租户 id。
    func tenant(for server: any MediaServer) -> TenantID {
        TenantID(profile: server.profile)
    }

    /// 离线读句柄。未建库时返回 nil——调用方按「没有缓存」处理即可。
    ///
    /// 租户**现算**而不是复用 `currentTenant`：详情页可能在会话切换的瞬间被渲染，
    /// 用传进来的服务器档案算才不会读到上一台的缓存。
    func hydrator(for server: any MediaServer) -> MetadataHydrator? {
        guard let store else { return nil }
        return MetadataHydrator(store: store, tenant: TenantID(profile: server.profile))
    }

    // MARK: - 维护

    /// 刷新体积统计（含 WAL；数据库体积会随写入增长，设置页要显示最新值）。
    func refreshSize() {
        guard let databaseDirectory else { return }
        databaseBytes = MetadataCache.sizeInBytes(at: databaseDirectory)
    }

    /// 清空当前租户的缓存（设置页「清空」）。返回是否成功。
    @discardableResult
    func clearCurrentTenant() async -> Bool {
        guard let store else { return false }
        do {
            if let tenant = currentTenant {
                try await store.clear(tenant: tenant)
            } else {
                try await store.clearAll()
            }
            refreshSize()
            return true
        } catch {
            AppDiagnostics.logWarning("清空媒体元数据缓存失败", fields: ["error": .string("\(error)")])
            return false
        }
    }

    /// 跑一次淘汰 + 回收磁盘。维护定时器调它。
    ///
    /// 两条上限**互相独立**，各自都能单独生效：
    ///
    /// 1. **条数**：超过 3 万条就删到 3 万。
    /// 2. **体积**：超过 200 MB 就删掉当前条数的 **10%**（最旧的优先）再 `VACUUM`。
    ///
    /// 第二道刻意按「当前条数的比例」而不是「删到条数上限的 90%」：实测每条约 1 KB，
    /// 3 万条的条数上限折合才 ≈30 MB，**永远先于 200 MB 触发**——写成「删到 27000 条」
    /// 的话，体积那一道在条数未超限时恒为空操作（等于上限形同虚设）。按比例删则与
    /// 条数解耦：无论库里多少条，只要体积真的超了就会腾出空间。
    /// - Parameter maxItems: 条数上限（默认 `Eviction.maxItems`）。参数化是为了
    ///   **可测**：真实上限是 3 万条 / 200 MB，用例不可能真写到那个量级，
    ///   而「体积那一道到底会不会触发」恰恰是曾经写错过的逻辑（见下）。
    /// - Parameter maxBytes: 体积上限（默认 `Eviction.maxBytes`）。
    func runMaintenance(
        maxItems: Int = Eviction.maxItems,
        maxBytes: Int64 = Eviction.maxBytes
    ) async {
        guard let store else { return }
        do {
            let before = try await store.itemCount()
            try await store.evictItems(keepingAtMost: maxItems)

            if let databaseDirectory {
                let bytes = MetadataCache.sizeInBytes(at: databaseDirectory)
                if bytes > maxBytes {
                    let current = try await store.itemCount()
                    // 至少删 1 条：否则 current 很小时 target == current，又成了空操作。
                    let target = max(0, current - max(1, current / 10))
                    try await store.evictItems(keepingAtMost: target)
                    try await store.vacuum()
                }
            }

            let after = try await store.itemCount()
            if after != before {
                AppDiagnostics.logInfo("媒体元数据淘汰", fields: [
                    "before": .integer(Int64(before)),
                    "after": .integer(Int64(after)),
                ])
            }
            refreshSize()
        } catch {
            AppDiagnostics.logWarning("媒体元数据维护失败", fields: ["error": .string("\(error)")])
        }
    }
}

import DiagnosticsKit
import Foundation

/// 一台服务器（一个档案）的**地址决议器**：并发探活所有候选地址，按实测延迟择优，
/// 缓存结果；请求失败 / 网络变化 / 缓存过期时重新决议。
///
/// 存在的理由：`ServerProfile.baseURL` 只能存一个地址，而同一台服务器常常有
/// 局域网与 Tailscale 两个入口 —— 在家走局域网最快，出门只有 Tailscale 通。
/// 决议器把「用哪个入口」从**登录时的一次性选择**变成**请求前的动态判断**。
///
/// 三条设计约束：
///
/// 1. **择优看延迟**，不看地址类别。Tailscale 打洞成功时同城延迟可能比绕一圈的
///    局域网还低；反过来 `100.x` 走了 DERP 中继时又明显更慢。类别只用于展示。
/// 2. **粘性**：当前地址可达时，只有另一个**明显更快**才切。两个入口延迟接近时
///    来回切会让图片缓存、播放会话不断换域名，收益为零。
/// 3. **失败开放（fail-open）**：一个地址都探不通时保持原地址不动，绝不把
///    「探活本身有问题」变成「连不上服务器」。
///
/// 线程模型：状态全部由 `lock` 保护；`currentURL` 是同步快路径（每个请求都要读），
/// 探活与决议是 async 的。`onChange` 在**地址真的变了**时回调，且只在锁外调用，
/// 回调线程不保证 —— 调用方自己 hop 到需要的地方（App 层就是 hop 主线程再写
/// `ServerStore`，`UserDefaults` 写入必须留在主线程，见 `ServerStore` 的注释）。
public final class ServerEndpointDirectory: @unchecked Sendable {

    public typealias ChangeHandler = @Sendable (URL) -> Void

    // MARK: - 可调参数

    /// 决议结果的软有效期：到期后**后台**重探，不阻塞请求。
    public var cacheTTL: TimeInterval = 300
    /// 一个地址都探不通时的重探间隔：避免服务器整个下线后每个请求都等一轮探活。
    public var unreachableRetryInterval: TimeInterval = 5
    /// 失败触发的重新决议最小间隔：一串并发失败不该打成探活风暴。
    public var failureCooldown: TimeInterval = 3
    /// 粘性：当前地址可达时，新地址要快到「当前延迟 × 这个比例」以下才切。
    public var stickinessRatio: Double = 0.7
    /// 粘性的绝对下限（秒）：两个地址都快时（同机 / 同网段）不因为几毫秒抖动换址。
    public var stickinessSlack: TimeInterval = 0.02

    // MARK: - 状态

    private let lock = NSLock()
    private let probe: ServerProbe
    private let profileID: String
    /// 期望的服务器 ID（来自档案 id 的 `serverID` 段）：探活时用它挡住
    /// 「同一个域名换了台服务器」这种把会话指错门的切换。
    private let serverID: String?

    private var candidates: [ServerAddress]
    private var active: URL
    private var pinned: URL?
    private var authorizationHeader: String?

    private var resolvedAt: Date?
    private var earliestNextProbe: Date?
    private var hardInvalid = true
    private var lastFailoverAt: Date?
    private var resolution: Task<URL, Never>?
    private var generation = 0
    private var onChange: ChangeHandler?

    public init(
        profile: ServerProfile,
        authorizationHeader: String? = nil,
        probe: ServerProbe = ServerProbe()
    ) {
        self.profileID = profile.id
        // 用 `resolvedServerID` 而不是裸 `serverID`：老档案没有显式字段，但能从
        // 档案 id 前缀恢复，不恢复的话它们等于**没有**校验（探活只认「这个地址上
        // 有个 Jellyfin」，不认「是这个服务器」），而同一份档案在「添加地址」那条
        // 路上是带校验的 —— 两处口径必须一致，否则一条指向别家服务器的候选可能被
        // 自动选中、并把我们的 token 发过去。
        self.serverID = profile.resolvedServerID
        self.probe = probe
        self.authorizationHeader = authorizationHeader
        self.candidates = profile.allAddresses
        self.active = profile.pinnedURL ?? profile.baseURL
        self.pinned = profile.pinnedURL
    }

    // MARK: - 读

    /// 当前生效地址。**同步**可读（请求路径上不能每次都 await）。
    public var currentURL: URL { lock.withLock { active } }

    /// 是否被用户固定到了某个地址（固定模式下不做自动切换）。
    public var isPinned: Bool { lock.withLock { pinned != nil } }

    public var candidateCount: Int { lock.withLock { candidates.count } }

    /// 地址变化回调。**不得同步回调 `ServerStore`**（会在持有决议器锁时反向拿
    /// store 的锁）；App 层的写法是 `Task { @MainActor in ... }`。
    public func setChangeHandler(_ handler: ChangeHandler?) {
        lock.withLock { onChange = handler }
    }

    // MARK: - 档案同步

    /// 档案变了（地址增删、固定项、当前地址）时同步候选。
    public func sync(profile: ServerProfile) {
        let applied: (url: URL, handler: ChangeHandler?)? = lock.withLock {
            self.candidates = profile.allAddresses
            self.pinned = profile.pinnedURL
            // 服务器 ID 是档案身份的一部分，不会在会话存续期间变，故不在这里更新。
            if let pinned = profile.pinnedURL {
                guard !ServerAddress.isSame(pinned, active) else { return nil }
                active = pinned
                return (pinned, onChange)
            }
            // 当前生效地址被用户删掉了：回落到档案里的 baseURL，别继续往一个
            // 已经不在候选里的地址打请求。
            if !candidates.contains(where: { ServerAddress.isSame($0.url, active) }) {
                active = profile.baseURL
                return (profile.baseURL, onChange)
            }
            return nil
        }
        if let applied { applied.handler?(applied.url) }
    }

    /// 探活时带的认证头。登录成功后 token 才拿得到，所以它是可变的。
    public func setAuthorizationHeader(_ header: String?) {
        lock.withLock { authorizationHeader = header }
    }

    // MARK: - 决议

    /// 请求前调用：需要决议时决议。
    ///
    /// - 缓存新鲜 → 立即返回；
    /// - 软过期 → 立即返回旧值，同时后台重探（不阻塞请求）；
    /// - 硬失效（首启 / 网络变化 / 从没决议过）→ **等**一次探活再返回。
    public func resolvedURL() async -> URL {
        let decision: Decision = lock.withLock {
            if let earliest = earliestNextProbe, Date() < earliest { return .immediate }
            if hardInvalid || resolvedAt == nil { return .awaitResolution }
            if let resolvedAt, Date().timeIntervalSince(resolvedAt) >= cacheTTL { return .background }
            return .immediate
        }
        switch decision {
        case .immediate:
            return currentURL
        case .background:
            startBackgroundResolution()
            return currentURL
        case .awaitResolution:
            return await resolveNow()
        }
    }

    /// 探活**全部**候选地址（不改变当前生效地址、也不看固定设置），按延迟从快到慢。
    /// 管理页展示「哪条通、多快」用；它不参与决议，所以不会因为一次展示性探活
    /// 就把正在用的地址换掉。
    public func probeAllCandidates() async -> [ServerProbeResult] {
        let (targets, header, expected) = lock.withLock {
            (candidates.isEmpty ? [ServerAddress(url: active)] : candidates,
             authorizationHeader, serverID)
        }
        let results = await Self.probeAll(
            targets, probe: probe, authorizationHeader: header, serverID: expected)
        return results.sorted { $0.latency < $1.latency }
    }

    /// 强制立刻重新探活（管理页的「重新检测」/ 网络变化后的主动预热）。
    @discardableResult
    public func refresh() async -> URL {
        await resolveNow()
    }

    /// 作废缓存：下一次请求会**等**一次重新探活。网络路径变化 / 应用回前台时调。
    ///
    /// `generation += 1` 是必须的：只置标志的话，**在飞**的那轮探活回来时仍会照常
    /// 写 `resolvedAt`，把刚作废的结论重新标成「新鲜」——于是「网络换了」这件事被
    /// 丢掉，最长再等一个缓存周期（300s）才自愈。推进代次让那轮结果作废。
    public func invalidate() {
        lock.withLock {
            generation += 1
            hardInvalid = true
            resolvedAt = nil
            earliestNextProbe = nil
            // 同时放开 `resolution` 占用：否则新的 `resolvedURL()` 会 await 那个
            // 已成废案的在飞任务，拿回一个刚被作废的地址。
            resolution = nil
        }
    }

    /// 某个地址上的请求失败（传输层）：重新探活，返回是否换到了别的地址。
    ///
    /// 调用方（`JellyfinServer.send` / `EmbySession.data`）据此决定「立刻在新地址上
    /// 重试一次」还是「按原样退避重试」。
    @discardableResult
    public func reportFailure(of failed: URL) async -> Bool {
        let before = currentURL
        let allowed: Bool = lock.withLock {
            // 固定地址 = 用户明确要求只用它：不做自动切换。
            guard pinned == nil else { return false }
            if let last = lastFailoverAt,
               Date().timeIntervalSince(last) < failureCooldown { return false }
            lastFailoverAt = Date()
            return true
        }
        guard allowed else { return false }
        let after = await resolveNow()
        return !ServerAddress.isSame(after, before)
    }

    // MARK: - 内部

    private enum Decision {
        case immediate
        case background
        case awaitResolution
    }

    private func resolveNow() async -> URL {
        let task: Task<URL, Never> = lock.withLock {
            if let existing = resolution { return existing }
            return startResolutionLocked()
        }
        return await task.value
    }

    private func startBackgroundResolution() {
        lock.withLock {
            guard resolution == nil else { return }
            _ = startResolutionLocked()
        }
    }

    /// 必须在 `lock` 内调用。
    private func startResolutionLocked() -> Task<URL, Never> {
        generation += 1
        let generation = self.generation
        let targets = probeTargetsLocked()
        let probe = self.probe
        let authorizationHeader = self.authorizationHeader
        let serverID = self.serverID
        let fallback = active
        hardInvalid = false
        let task = Task<URL, Never> { [weak self] in
            let results = await Self.probeAll(
                targets, probe: probe, authorizationHeader: authorizationHeader, serverID: serverID)
            guard let self else { return fallback }
            return self.apply(results: results, generation: generation)
        }
        resolution = task
        return task
    }

    /// 必须在 `lock` 内调用。
    private func probeTargetsLocked() -> [ServerAddress] {
        if let pinned { return [ServerAddress(url: pinned)] }
        return candidates.isEmpty ? [ServerAddress(url: active)] : candidates
    }

    private static func probeAll(
        _ targets: [ServerAddress],
        probe: ServerProbe,
        authorizationHeader: String?,
        serverID: String?
    ) async -> [ServerProbeResult] {
        await withTaskGroup(of: ServerProbeResult?.self) { group in
            for target in targets {
                group.addTask {
                    await probe.probe(
                        url: target.url,
                        authorizationHeader: authorizationHeader,
                        expectedServerID: serverID)
                }
            }
            var results: [ServerProbeResult] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
    }

    private struct Applied {
        let url: URL
        let previous: URL
        let handler: ChangeHandler?
        let changed: Bool
        let stale: Bool
        let latency: TimeInterval?
    }

    private func apply(results: [ServerProbeResult], generation: Int) -> URL {
        let applied: Applied = lock.withLock {
            // 迟到的旧任务不许覆盖新结果（决议被作废后又发起了新一轮）。
            guard generation == self.generation else {
                return Applied(url: active, previous: active, handler: nil,
                               changed: false, stale: true, latency: nil)
            }
            resolution = nil
            let previous = active
            var chosen = active

            if let pinned {
                // 固定模式：只用固定地址；探不到也保持它（让请求如实报错，
                // 而不是偷偷换一条用户没选的线路）。
                chosen = pinned
            } else if let best = results.min(by: { $0.latency < $1.latency }) {
                if let current = results.first(where: { ServerAddress.isSame($0.url, active) }) {
                    // 粘性：当前地址可达时，只有明显更快才切。
                    let threshold = current.latency * stickinessRatio - stickinessSlack
                    chosen = best.latency < threshold ? best.url : current.url
                } else {
                    // 当前地址探不到 —— 出门那条路（局域网 → Tailscale）就走这里。
                    chosen = best.url
                }
            }

            if results.isEmpty {
                // 一个都探不通：保持原地址（fail-open），并让下一次决议晚点再来，
                // 免得服务器整个下线时每个请求都先等一轮 2 秒探活。
                resolvedAt = nil
                earliestNextProbe = Date().addingTimeInterval(unreachableRetryInterval)
            } else {
                resolvedAt = Date()
                earliestNextProbe = nil
            }
            active = chosen
            return Applied(
                url: chosen,
                previous: previous,
                handler: onChange,
                changed: !ServerAddress.isSame(chosen, previous),
                stale: false,
                latency: results.first(where: { ServerAddress.isSame($0.url, chosen) })?.latency)
        }

        guard !applied.stale else { return applied.url }
        if applied.changed, let latency = applied.latency {
            NetworkLog.logger.info(
                "服务器地址切换 \(applied.previous.host ?? "?") → \(applied.url.host ?? "?")",
                fields: [
                    "profile": .string(profileID),
                    "from": .string(applied.previous.absoluteString),
                    "to": .string(applied.url.absoluteString),
                    "latencyMs": .integer(Int64((latency * 1000).rounded())),
                ])
            applied.handler?(applied.url)
        }
        return applied.url
    }
}

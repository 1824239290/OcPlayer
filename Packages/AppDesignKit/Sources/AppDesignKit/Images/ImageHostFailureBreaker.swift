import Foundation

/// 按 host 记录连续网络失败；达到阈值后冷却，冷却后只放行一个半开探针。
///
/// 只记录真正尝试过网络后的结果。内存 / blob 命中不经过这里，也不会误复位故障计数。
public final class ImageHostFailureBreaker: @unchecked Sendable {
    public struct OpenCircuit: LocalizedError, Equatable {
        public let host: String

        public init(host: String) {
            self.host = host
        }

        public var errorDescription: String? {
            "图片宿主 \(host) 暂时熔断，等待冷却后重试"
        }
    }

    struct HostSnapshot: Equatable {
        var consecutiveFailures: Int
        var isOpen: Bool
        var probeInFlight: Bool
        var cooldownRemaining: TimeInterval
    }

    private struct HostState {
        var consecutiveFailures = 0
        var openedAt: Date?
        var probeInFlight = false
    }

    private let failureThreshold: Int
    private let cooldown: TimeInterval
    private let lock = NSLock()
    private var states: [String: HostState] = [:]

    public init(failureThreshold: Int = 3, cooldown: TimeInterval = 30) {
        self.failureThreshold = max(1, failureThreshold)
        self.cooldown = max(0, cooldown)
    }

    /// 网络前申请许可。冷却到期后的首个请求是半开探针，其余请求等探针结果。
    public func shouldAllowRequest(for url: URL, at now: Date = Date()) -> Bool {
        guard let host = Self.hostKey(for: url) else { return true }
        return lock.withLock {
            guard var state = states[host], let openedAt = state.openedAt else {
                return true
            }
            let remaining = cooldown - now.timeIntervalSince(openedAt)
            guard remaining <= 0 else { return false }
            guard !state.probeInFlight else { return false }
            state.probeInFlight = true
            states[host] = state
            return true
        }
    }

    /// 一次真正的网络失败。半开失败会重新开始完整冷却窗口。
    public func recordFailure(for url: URL, at now: Date = Date()) {
        guard let host = Self.hostKey(for: url) else { return }
        lock.withLock {
            var state = states[host] ?? HostState()
            if state.openedAt != nil {
                // 也包括打开前已在途、打开后才完成的失败：冷却应从最新故障算起。
                state.consecutiveFailures = max(failureThreshold, state.consecutiveFailures + 1)
                state.openedAt = now
                state.probeInFlight = false
            } else {
                state.consecutiveFailures += 1
                if state.consecutiveFailures >= failureThreshold {
                    state.openedAt = now
                    state.probeInFlight = false
                }
            }
            states[host] = state
        }
    }

    /// 任意真实网络成功都证明 host 已恢复，连续计数与半开状态一起复位。
    public func recordSuccess(for url: URL) {
        guard let host = Self.hostKey(for: url) else { return }
        lock.withLock {
            states[host] = nil
        }
    }

    /// 半开探针**没有结论**（请求被取消 / 视图走掉）：只释放探针位，不动冷却起点。
    ///
    /// 为什么必须有这一条：`shouldAllowRequest` 在冷却到期时会把 `probeInFlight`
    /// 置位，只有「成功」或「失败」才会清掉它。而图被取消是滚动时的常态——若探针
    /// 恰好命中一次取消，host 就会永久停在「冷却已过、但探针在途」的状态，
    /// 之后**所有**请求都被拒，比不熔断更糟（用户看到整墙永久占位）。
    public func releaseProbe(for url: URL) {
        guard let host = Self.hostKey(for: url) else { return }
        lock.withLock {
            guard var state = states[host], state.openedAt != nil else { return }
            state.probeInFlight = false
            states[host] = state
        }
    }

    func snapshot(for url: URL, at now: Date = Date()) -> HostSnapshot {
        guard let host = Self.hostKey(for: url) else {
            return HostSnapshot(
                consecutiveFailures: 0,
                isOpen: false,
                probeInFlight: false,
                cooldownRemaining: 0
            )
        }
        return lock.withLock {
            guard let state = states[host] else {
                return HostSnapshot(
                    consecutiveFailures: 0,
                    isOpen: false,
                    probeInFlight: false,
                    cooldownRemaining: 0
                )
            }
            let remaining = state.openedAt.map {
                max(0, cooldown - now.timeIntervalSince($0))
            } ?? 0
            return HostSnapshot(
                consecutiveFailures: state.consecutiveFailures,
                isOpen: state.openedAt != nil,
                probeInFlight: state.probeInFlight,
                cooldownRemaining: remaining
            )
        }
    }

    private static func hostKey(for url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }
}

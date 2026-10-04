import Foundation

/// TMDb 请求限流。
///
/// TMDb 的旧限流（40 请求 / 10 秒）早已取消，文档口径是「大约 50 请求 / 秒的上限，
/// 用来挡批量抓取，且**必须尊重 429**」。批量补全一整个媒体库时很容易瞬间打出几百个
/// 请求，所以这里主动限流，而不是等被拒了再退避。
///
/// 两道约束：
/// 1. **并发上限**：同时在飞的请求数（默认 4）。这一条比速率更重要——真正的风险
///    是几百个请求同时建连。
/// 2. **最小间隔**：两次请求之间的最小时间（默认 120ms ≈ 8 req/s）。远低于 50/s 的
///    上限，给同一出口 IP 上的其它用户留余量。
///
/// 用 actor 而不是信号量：需要「等够间隔」这种带时间的前置条件，
/// 用锁做会变成忙等或 sleep 占线程。
public actor TMDbRateLimiter {

    private let maxConcurrent: Int
    private let minimumInterval: TimeInterval
    private var inFlight = 0
    private var lastStart: Date?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(maxConcurrent: Int = 4, minimumInterval: TimeInterval = 0.12) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.minimumInterval = max(0, minimumInterval)
    }

    /// 取一个名额（不够就等）。**必须配对 `release()`**——用 `withPermit` 更安全。
    func acquire() async {
        while true {
            if inFlight < maxConcurrent, let wait = waitTime() {
                if wait <= 0 {
                    inFlight += 1
                    lastStart = Date()
                    return
                }
                // 还需等待：睡够再来抢（睡醒后条件可能已被别的请求改变）。
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                continue
            }
            // 并发已满：排队等唤醒。
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func release() {
        inFlight = max(0, inFlight - 1)
        guard !waiters.isEmpty else { return }
        let next = waiters.removeFirst()
        next.resume()
    }

    /// 距可以发起下一个请求还需多久（nil = 现在就能发）。
    private func waitTime() -> TimeInterval? {
        guard let lastStart else { return 0 }
        return minimumInterval - Date().timeIntervalSince(lastStart)
    }

    /// 包住一次请求：自动取名额 / 释放（含抛错路径）。
    func withPermit<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { Task { await self.release() } }
        return try await operation()
    }
}

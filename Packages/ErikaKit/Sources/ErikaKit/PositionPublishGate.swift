import Foundation

/// `positionChanged` 事件的发布闸门：把内核每帧一条（60–120Hz）的高频位置事件
/// 降到固定上限再进事件流。
///
/// **为什么需要它**：事件流是 `AsyncStream(bufferingPolicy: .bufferingNewest(256))`，
/// 而消费者（`PlayerState.start` 里那个 Task）跑在主 actor 上——一旦被 UI 工作占住
/// （大 body 重建、截图取帧、同步收尾），每帧一条的 position 会把 256 个槽位灌满。
/// `.bufferingNewest` 溢出时丢的是**最旧**的那批，也就是可能正好丢掉
/// `.stateChanged(.stopped)` / `.failed` 这类**控制事件**：UI 会卡在 playing、
/// 弹幕冻结，而且看门狗救不回来（它只看「位置有没有动」）。
///
/// **为什么降到 10Hz 没有损失**：
/// - 进度条：`PlayerTimeline` 本来 100ms 才发布一次 progress；
/// - 时间标签：只在整秒变化时发布；
/// - 弹幕：用的是 `PlaybackEngine.latestMediaTime`，它在 poll 事件时就已更新，
///   **根本不走这条事件流**；
/// - 卡死看门狗：每 2 秒才比对一次位置。
///
/// 闸门只作用于 position；状态 / 轨道 / 错误等低频事件一律即时发布，不受影响。
///
/// 只在渲染线程访问（`ErikaEngine.step` 是唯一调用方），因此不加锁。
struct PositionPublishGate {
    /// 两次发布之间的最小间隔。
    let interval: Duration
    private var lastPublished: ContinuousClock.Instant?
    private let clock = ContinuousClock()

    init(interval: Duration = .milliseconds(100)) {
        self.interval = interval
    }

    /// 到发布点返回 true 并记账；否则返回 false，调用方丢弃这个中间值。
    ///
    /// `now` 只为测试注入时间用；生产传 nil 走单调时钟。
    mutating func shouldPublish(now: ContinuousClock.Instant? = nil) -> Bool {
        let point = now ?? clock.now
        if let lastPublished, point - lastPublished < interval {
            return false
        }
        lastPublished = point
        return true
    }
}

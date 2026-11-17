import Foundation

/// 「同落点重复 seek」合并策略：**落点相同、且在窗口内的重复只放行第一条**。
///
/// ## 为什么需要它
///
/// 2026-11-07 实测（`~/Library/Logs/OcPlayer/diagnostics-20261107-142219-e32c398a.jsonl`）：
/// 11 次物理拖动产生了 **22 条 `kind=scrub`**，`from_ms`/`to_ms` **逐字相同**，
/// 同一对之间的间隔只有 **2~43 ms**。第二条对内核来说不是「更精确的落点」，
/// 而是一次纯粹的重复：每条 seek 都会让内核 `SourceCancellation::interrupt()`
/// 再打断一次在途 HTTP 读，而被打断的读在 liberika 里一律被翻成 EIO（-5），
/// 最终以播放会话 fatal 收场。本类型的作用就是把这条放大链路的**放大因子**去掉。
///
/// ## 语义（三条，少一条都会吃掉用户意图）
///
/// 1. 落点与**上一次被放行**的落点相同、且距那次放行 < `window` ⇒ `.coalesced`（吞掉）；
/// 2. 落点不同 ⇒ 一律 `.forward`（用户连续拖动每一段都要到内核，不能卡顿或跳格）；
/// 3. 距上次放行 ≥ `window` ⇒ 一律 `.forward`（「先拖到 A、又拖回 A」不会被吃掉）。
///
/// ## 两个刻意的口径选择
///
/// - **计时基准是「上次放行」而不是「上次提交」**。若按上次提交算，一串不停歇的
///   重复（每 < window 来一条）会把窗口无限顺延，用户的意图永远到不了内核；
///   按上次放行算，最坏情况下每 `window` 也至少放行一条，重复风暴只会被降频、不会被静音。
/// - **落点同一性量化到毫秒**（`landingKey`），与日志 `to_ms` 同一把尺子。
///   不用 `==` 比 `Double`：两次拖动算出的 `duration * fraction` 可能差最后几个二进制位
///   （日志 `to_ms` 相同而 `Double` 不同），那种「同一落点」必须算重复；反过来，
///   1 ms 以内的差异用户也无法表达成两个不同意图。
///
/// ## 窗口就是「拖动批次」
///
/// 这里没有独立的 `beginDrag()` / `endDrag()`：批次边界**只由窗口定义**。加显式的
/// 拖动起止钩子要改 SwiftUI 滑块与手势层的提交点（不在本类型的写入范围里），
/// 而实测重复对间隔只有 2~43 ms，300 ms 的窗口留了 7 倍余量。
///
/// ## 时钟
///
/// 本类型**不读时钟**：与同目录的 `PlaybackWatchClock` 同口径，由宿主把单调时刻
/// 传进来（`submit(landingSeconds:at:)`），所以单测是确定性的，不依赖 sleep。
public struct SeekCoalescer: Sendable {

    /// 默认窗口 **300 ms**：实测重复对间隔 2~43 ms（留 7 倍余量）；同时短于
    /// 用户「拖开再拖回同一落点」的手速量级，不会把真实意图当成重复。
    public static let defaultWindow: TimeInterval = 0.3

    /// 一次提交的判定。
    public enum Outcome: Equatable, Sendable {
        /// 放行：调用方应当真的去调内核。
        case forward
        /// 合并：本次落点与上次放行的相同且在窗口内。调用方**不要**调内核。
        /// 关联值是从上次放行到本次的间隔（秒），只为日志/排障。
        case coalesced(elapsedSinceForward: TimeInterval)
    }

    /// 合并窗口（秒）。非正或非有限时退化为「不合并」——配置写错时宁可多打一次内核，
    /// 也不能因为一个错参数把用户意图吃掉。
    public let window: TimeInterval

    /// 上次**放行**的落点（毫秒量化）与时刻。合并掉的那次不更新它们。
    private var lastForwardedKey: Int64?
    private var lastForwardedAt: TimeInterval?

    public init(window: TimeInterval = SeekCoalescer.defaultWindow) {
        self.window = (window.isFinite && window > 0) ? window : 0
    }

    /// 提交一次 seek 落点。返回值决定调用方要不要去调内核。
    ///
    /// `time` 是宿主提供的单调时刻（秒），两次调用之间必须同源；时间倒流（非单调时钟
    /// 的产物）一律按放行处理——放行的代价是多一次内核调用，吞掉的代价是用户动作丢失，
    /// 两者不对等，所以异常一律选前者。
    public mutating func submit(landingSeconds: Double, at time: TimeInterval) -> Outcome {
        guard landingSeconds.isFinite, time.isFinite else {
            // 落点/时刻无效：不表态、直接放行，也不污染下次判定的基准。
            return .forward
        }
        guard let key = Self.landingKey(landingSeconds) else { return .forward }
        if let lastKey = lastForwardedKey, let lastAt = lastForwardedAt {
            let elapsed = time - lastAt
            if key == lastKey, elapsed >= 0, elapsed < window {
                return .coalesced(elapsedSinceForward: elapsed)
            }
        }
        lastForwardedKey = key
        lastForwardedAt = time
        return .forward
    }

    /// 丢弃基准。窗口只有 300 ms，换源时不调也不会出错（最多多吞一条同落点 seek）；
    /// 给「引擎代际切换」这类显式边界留一个干净的入口，测试也用它。
    public mutating func reset() {
        lastForwardedKey = nil
        lastForwardedAt = nil
    }

    /// 落点同一性口径：毫秒量化（`.rounded()` 半值向远离零方向取整，与日志
    /// `to_ms = Int64(target * 1000)` 的截断最多差 1 ms，不影响判定）。
    static func landingKey(_ seconds: Double) -> Int64? {
        Int64(exactly: (seconds * 1000).rounded())
    }
}

import Foundation

/// Counts elapsed viewing time backed by advancing media positions. No timers or I/O.
/// The host supplies a monotonic clock; seeking must invalidate the anchor explicitly.
public struct PlaybackWatchClock: Sendable {
    private struct Anchor: Sendable {
        var time: Double
        var position: Double
        var rate: Double
    }
    private var anchor: Anchor?

    public init() {}

    public mutating func reset() { anchor = nil }

    public mutating func sample(position: Double, playing: Bool, buffering: Bool,
                                rate: Double, time: Double) -> Double {
        guard position.isFinite, position >= 0, time.isFinite,
              rate.isFinite, rate > 0 else { reset(); return 0 }
        let eligible = playing && !buffering
        defer {
            if !eligible { anchor = nil }
        }
        guard let previous = anchor else {
            if eligible { anchor = Anchor(time: time, position: position, rate: rate) }
            return 0
        }
        let elapsed = time - previous.time
        let progress = position - previous.position
        guard elapsed >= 0, elapsed <= 5, progress >= 0,
              rate == previous.rate, progress <= elapsed * rate + 0.5 else {
            anchor = eligible ? Anchor(time: time, position: position, rate: rate) : nil
            return 0
        }
        // Batch sub-frame jitter and repeated positions; a frozen clock earns no time.
        guard progress / rate >= 0.25 || !eligible else { return 0 }
        anchor = eligible ? Anchor(time: time, position: position, rate: rate) : nil
        // Media distance is only evidence, never the amount credited (2× remains wall time).
        return min(elapsed, progress / rate)
    }
}

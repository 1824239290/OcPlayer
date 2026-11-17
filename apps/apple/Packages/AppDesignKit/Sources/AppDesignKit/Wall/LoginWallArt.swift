import DiagnosticsKit
import Foundation

/// SplitMix64——小、快、确定性。程序化封面因此在每次启动、每张截图里都一模一样。
public struct SeededRandom {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// `0..<1` 上的均匀值。
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    public mutating func range(_ lower: Double, _ upper: Double) -> Double {
        lower + unit() * (upper - lower)
    }
}

/// 程序化封面的参数，在装配海报列表时**一次算好**。
///
/// 这样渲染一整面墙就是纯读值——没有哈希、没有随机数、没有分配。真实海报到位前
/// （首次安装、缓存被清、条目本来就没图）它就是那张封面，所以墙永远不空。
public struct LoginWallArt: Hashable, Sendable {
    public struct Blob: Hashable, Sendable {
        /// 中心点，`0...1` 的 tile 归一化坐标。
        public let x: Double
        public let y: Double
        /// 半径占 tile 宽的比例。
        public let radius: Double
        public let hue: Double
        public let opacity: Double
    }

    public let hue: Double
    public let blobs: [Blob]
    /// 掠光的倾角，做出「一张过塑海报」的反光。
    public let streakAngle: Double

    public init(hue: Double, blobs: [Blob], streakAngle: Double) {
        self.hue = hue
        self.blobs = blobs
        self.streakAngle = streakAngle
    }

    public static func make(seed: UInt64) -> LoginWallArt {
        var rng = SeededRandom(seed: seed)
        let hue = rng.unit()

        let blobs = (0..<3).map { index in
            Blob(
                x: rng.range(0.05, 0.95),
                y: rng.range(0.0, 0.85),
                radius: rng.range(0.45, 0.95),
                hue: (hue + rng.range(-0.14, 0.14) + 1).truncatingRemainder(dividingBy: 1),
                opacity: rng.range(0.35, 0.62) - Double(index) * 0.05
            )
        }

        return LoginWallArt(hue: hue, blobs: blobs, streakAngle: rng.range(-38, -12))
    }

    /// 由一个稳定字符串派生（条目 id 这类）。
    ///
    /// 用条目 id 而不是数组下标播种：条目被淘汰 / 新增时，其余海报的封面不会跟着
    /// 换一副面孔。哈希走 `FNV1a`——**别用 `Hasher` / `hashValue`**，它每进程随机
    /// 播种，会让墙每次冷启动都换一副面孔。
    public static func make(seedString: String) -> LoginWallArt {
        var hasher = FNV1a()
        hasher.feed(seedString)
        return make(seed: hasher.value)
    }
}

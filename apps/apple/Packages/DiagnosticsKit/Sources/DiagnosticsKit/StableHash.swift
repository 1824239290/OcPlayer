import Foundation

/// FNV-1a 64 位哈希（纯手写、与进程无关）：派生**需要跨进程 / 跨启动稳定**的标识。
///
/// **别用 `Hasher()` / `hashValue` 做持久化标识**：Swift 的 `Hasher` 每个进程随机
/// 播种，同一个输入这次启动和下次启动算出来不一样——拿它当缓存键、列表身份或派生
/// id，每次冷启动都会整批变一遍（review-20260914 P3-3 就是这么埋的）。
///
/// 现使用者：`MoviePilotKit.JSONValue.stableContentHash`（缺主键条目的 ForEach 身份）
/// 与 `JellyfinKit` 的缺 id 兜底派生。改这个算法等于改它们的标识，别顺手改。
public struct FNV1a {
    private var hash: UInt64 = 0xcbf29ce484222325

    public init() {}

    public mutating func feed(_ string: String) {
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
    }

    public func finishHex() -> String {
        String(format: "%016llx", hash)
    }

    /// 原始 64 位摘要。给「要的是种子而不是十六进制串」的场景（登录页海报墙的程序化
    /// 封面按条目 id 播种）；字符串口径仍走 `finishHex()`。
    public var value: UInt64 { hash }

    /// 一次算完的便捷入口（单串场景）。
    public static func hex(of string: String) -> String {
        var hasher = FNV1a()
        hasher.feed(string)
        return hasher.finishHex()
    }
}

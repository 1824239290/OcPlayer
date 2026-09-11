import SwiftUI

/// 时长格式：87 分钟 →「1 小时 27 分」；剧集分钟数 →「44 分钟」。
public struct RuntimeText: View {
    public let seconds: Double?

    public init(seconds: Double?) {
        self.seconds = seconds
    }

    public var body: some View {
        if let seconds, seconds > 0 {
            Text(Self.format(seconds))
        }
    }

    public static func format(_ seconds: Double) -> String {
        let total = Int(seconds / 60)
        if total >= 60 {
            return "\(total / 60) 小时 \(total % 60) 分"
        }
        return "\(max(total, 1)) 分钟"
    }
}

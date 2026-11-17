import Foundation

/// 「现在展示的是缓存内容」这条状态。
///
/// 出现的条件是**同时满足**两条：①页面已经有内容（来自内存快照或磁盘）②这次网络
/// 刷新失败了。只满足②时走的是各页既有的整页错误态，不该再叠这条提示。
///
/// 文案分两档，因为原因不同、用户该做的事也不同：
/// - `causedByConnectivity`：断网 / 连不上服务器 → 「离线」，提示查网络；
/// - 否则：服务端答复了但出错（5xx / 401）→ 不谎称离线，只说内容可能不是最新。
///
/// 详情页与首页共用同一套判断与文案，避免两处各自措辞（这个仓库里
/// 「同一个状态两个词」的教训见 MoviePilot 三态那次修复）。
struct StaleContentNotice: Equatable {
    /// 缓存内容的写入时间；nil = 本会话内拉的，不知道确切时间。
    var fetchedAt: Date?
    /// 是否由「连不上」导致（决定文案说不说「离线」）。
    var causedByConnectivity: Bool

    /// 给用户看的一行文案。
    func text(now: Date = Date()) -> String {
        let lead = causedByConnectivity ? "离线" : "内容可能不是最新"
        guard let fetchedAt else {
            // 本会话拉过、只是这次刷新没成功：说「离线」比编一个时间准确。
            return causedByConnectivity ? "\(lead) · 正在显示已加载的内容" : "\(lead) · 刷新失败"
        }
        return "\(lead) · 数据更新于 \(Self.relative(fetchedAt, now: now))"
    }

    /// 「3 分钟前 / 2 小时前 / 昨天 / 3 天前」。
    ///
    /// 用相对时间而不是绝对时间：离线时用户关心的是「这份东西有多旧」，
    /// 不是一个需要他自己去减的时间点。
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "刚刚"
        case ..<3600: return "\(Int(seconds / 60)) 分钟前"
        case ..<86_400: return "\(Int(seconds / 3600)) 小时前"
        case ..<172_800: return "昨天"
        default: return "\(Int(seconds / 86_400)) 天前"
        }
    }
}

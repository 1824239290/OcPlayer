import Foundation
import SwiftUI

/// 凭证失效（401）通知的统一解码与挂载。
///
/// Bangumi / MoviePilot 两个域各自实现了同一套「通知 → 凭证代次 → 处理」接线，
/// RootView 里曾有三段几乎逐行相同的 `onReceive`。收敛到这里：
/// 域只暴露通知名和 `handleAuthenticationRequired(generation:)`，解码与挂载共用。
enum AuthNotification {
    /// Bangumi / MoviePilot 的通知载荷都是 NSNumber 包着的凭证代次。
    static func credentialGeneration(from note: Notification) -> UInt64? {
        (note.object as? NSNumber)?.uint64Value
    }
}

extension View {
    /// 401 凭证失效 → 拉回未登录态。挂在根视图：401 可能来自任何页面
    /// （详情页标记章节、播放结束自动标记），那时对应分区的视图未必存在。
    func onAuthenticationRequired(
        _ name: Notification.Name,
        handler: @escaping (UInt64) async -> Void
    ) -> some View {
        onReceive(NotificationCenter.default.publisher(for: name)) { note in
            guard let generation = AuthNotification.credentialGeneration(from: note) else { return }
            Task { await handler(generation) }
        }
    }
}

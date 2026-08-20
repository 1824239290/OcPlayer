import Foundation

/// 关闭播放器时延迟 dismiss 的判定。抽成纯函数便于单测锁住
/// 「关旧片的 Task 不能清掉用户新开的 presentedPlayer」。
enum PlayerClosePolicy {
    static func shouldDismiss(presentedID: UUID?, closingID: UUID?) -> Bool {
        guard let closingID, let presentedID else { return false }
        return presentedID == closingID
    }
}

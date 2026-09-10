import SwiftUI

/// 空态/失败态的单一入口：包住 `ContentUnavailableView`，把手铺的
/// 标题/图标/描述/操作按钮收成一处。默认文案走 `UIStrings`。
public struct EmptyState: View {
    public let title: String
    public let systemImage: String
    public var message: String?
    public var actionTitle: String?
    public var action: (() -> Void)?

    /// 失败态：标题默认「加载失败」，操作默认「重试」。
    public init(
        failure message: String,
        title: String = UIStrings.loadFailed,
        systemImage: String = "exclamationmark.triangle",
        retry: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = retry == nil ? nil : UIStrings.retry
        self.action = retry
    }

    /// 空态：无内容可展示；可选一个引导操作（如「刷新」「去登录」）。
    public init(
        empty title: String,
        systemImage: String,
        message: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
    }
}

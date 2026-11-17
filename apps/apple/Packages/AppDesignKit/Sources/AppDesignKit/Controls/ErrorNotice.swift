import SwiftUI

/// 行内错误/提示条：图标 + 文案 + 可选「重试」。
/// 收编详情页 `loadErrorNotice` 与 Bangumi 的 `BangumiNotice` 两份同观感实现。
public struct ErrorNotice: View {
    public let message: String
    public var systemImage: String
    public var onRetry: (() -> Void)?

    public init(
        _ message: String,
        systemImage: String = "exclamationmark.triangle",
        onRetry: (() -> Void)? = nil
    ) {
        self.message = message
        self.systemImage = systemImage
        self.onRetry = onRetry
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
            Text(message).font(.callout)
            Spacer(minLength: 0)
            if let onRetry {
                Button(UIStrings.retry, action: onRetry)
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
        .foregroundStyle(.secondary)
    }
}

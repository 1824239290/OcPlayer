import SwiftUI

/// 简单的 `Label : Value` 键值行——设置页等 Form 内重复使用的布局。
/// 之前 `SettingsView` 和 `PlaybackKernelSection` 各写了一份私有副本。
public struct KeyValueRow: View {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

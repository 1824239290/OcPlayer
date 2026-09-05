import SwiftUI

/// 选项 chip 的统一外观：选中带对勾 + accent 高亮，未选中淡底细描边。
/// 筛选候选（MoviePilot）与排序字段（MoviePilot / 媒体库）共用。
struct OptionChip: View {
    let title: String
    let selected: Bool

    var body: some View {
        HStack(spacing: 4) {
            if selected {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
            }
            Text(title)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05),
            in: Capsule()
        )
        .overlay(
            Capsule().strokeBorder(
                selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08),
                lineWidth: 0.5
            )
        )
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
    }
}

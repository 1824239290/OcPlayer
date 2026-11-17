import AppDesignKit
import SwiftUI

/// MoviePilot 域的操作反馈条（添加下载成功 / 失败等即时反馈）：图标 + 文案，
/// 错误红、成功绿。
///
/// 轻量版是行内 Label（首页区块里贴着内容走）；卡片版垫液态玻璃（下载管理 /
/// 资源搜索页同款，作为独立条带出现）。此前三处各写一份，图标名都复制。
struct MoviePilotNoticeBanner: View {
    let text: String
    let isError: Bool
    /// true = 垫液态玻璃卡片（独立条带）；false = 行内轻量 Label。
    var glassCard = false

    private var icon: String {
        isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var tint: Color {
        isError ? .red : .green
    }

    var body: some View {
        if glassCard {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(text)
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(tint)
            .padding(12)
            .liquidGlassCard()
        } else {
            Label(text, systemImage: icon)
                .foregroundStyle(tint)
                .font(.callout)
                .padding(.vertical, 4)
        }
    }
}

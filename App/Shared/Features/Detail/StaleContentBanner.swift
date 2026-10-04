import SwiftUI

/// 「内容可能不是最新」的一行提示。
///
/// 刻意做得**很轻**：一行小字 + 一个图标，不挡内容、不占一整块、不弹窗。
/// 用户看的是自己点进来的那部片子，提示的作用只是告诉他「这是缓存，不是刚拉的」，
/// 不是拦着他。
///
/// 文案由 `StaleContentNotice.text()` 统一给（详情页与首页共用同一份措辞判断）。
struct StaleContentBanner: View {
    let notice: StaleContentNotice
    /// 正文区用 `.secondary`；垫在氛围背景上的页面可用别的色。
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: notice.causedByConnectivity ? "wifi.slash" : "exclamationmark.triangle")
                .font(.caption2)
            Text(notice.text())
                .font(.caption)
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }
}

import AppDesignKit
import SwiftUI

/// 登录前的品牌与欢迎文案；宽屏采用文字排版，手机保持紧凑的品牌标题。
struct OnboardingWelcomeView: View {
    let compact: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize = 60.0
    @ScaledMetric(relativeTo: .body) private var introductionSize = 17.0

    var body: some View {
        Group {
            if compact {
                compactContent
            } else {
                wideContent
            }
        }
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            OnboardingBrandMark()
                .frame(width: 40, height: 34)
            Text("OcPlayer")
                .font(.title3.weight(.semibold))
        }
        .accessibilityElement(children: .combine)
    }

    private var compactContent: some View {
        VStack(spacing: 14) {
            brand
            VStack(spacing: 12) {
                Text("好故事，即刻开场。")
                    .font(.title.weight(.bold))
                    .tracking(-1)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("你的私人影院，从这里开始。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
        }
    }

    private var wideContent: some View {
        VStack(alignment: .leading, spacing: 36) {
            brand

            VStack(alignment: .leading, spacing: 18) {
                Text("好故事，\n即刻开场。")
                    .font(.system(size: headlineSize, weight: .bold))
                    .tracking(-2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("你的私人影院，从这里开始。")
                    .font(.system(size: introductionSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Rectangle()
                .fill(.primary.opacity(0.12))
                .frame(width: 56, height: 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 24) {
                OnboardingFeatureText(
                    title: "连接私人媒体库",
                    detail: "浏览 Jellyfin 或 Emby 中的电影与剧集。"
                )
                OnboardingFeatureText(
                    title: "接着上次继续看",
                    detail: "同步观看进度，从上次停下的地方继续。"
                )
                OnboardingFeatureText(
                    title: "直接播放本地视频",
                    detail: "无需登录，打开本地文件即可播放。"
                )
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

private struct OnboardingFeatureText: View {
    let title: String
    let detail: String
    @ScaledMetric(relativeTo: .headline) private var titleSize = 17.0
    @ScaledMetric(relativeTo: .body) private var detailSize = 15.0

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: titleSize, weight: .medium))
            Text(detail)
                .font(.system(size: detailSize))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// 沿用启动页的品牌路径，避免登录页另造一套猫图标。
private struct OnboardingBrandMark: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Canvas { context, size in
            let bounds = OcMark.contentBBox
            let scale = min(size.width / bounds.width, size.height / bounds.height)
            context.translateBy(x: (size.width - bounds.width * scale) / 2,
                                y: (size.height - bounds.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [LaunchStyle.markTop(for: colorScheme), LaunchStyle.markBottom(for: colorScheme)]),
                startPoint: CGPoint(x: 512, y: LaunchStyle.markGradientTopY),
                endPoint: CGPoint(x: 512, y: LaunchStyle.markGradientBottomY)
            )
            context.fill(OcMark.headFillPath, with: shading, style: FillStyle(eoFill: true))
            for path in OcMark.whiskerFillPaths {
                context.fill(path, with: shading)
            }
            context.fill(OcMark.triangleFillPath, with: shading)
        }
        .accessibilityHidden(true)
    }
}

struct OnboardingBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LaunchStyle.backdrop(for: colorScheme)
                RadialGradient(
                    colors: [LoginWallStyle.accent.opacity(colorScheme == .dark ? 0.10 : 0.07), .clear],
                    center: UnitPoint(x: 0.12, y: 0.5),
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.65
                )
                RadialGradient(
                    colors: [LoginWallStyle.violet.opacity(0.07), .clear],
                    center: .topTrailing,
                    startRadius: 0,
                    endRadius: max(proxy.size.width, proxy.size.height) * 0.7
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

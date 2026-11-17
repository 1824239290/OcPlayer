import SwiftUI

/// 墙与卡片之间的一切。
///
/// 真实媒体库海报比占位图亮得多、饱和得多，所以遮罩是主力：全局压暗、**反向聚光灯**
/// （卡片所在处最暗）、镜头暗角、上下电影感压暗。目标是墙仍然读得出是一面海报墙，
/// 而卡片一眼就能看清。
///
/// 分模式：夜间黑纱、日间白雾。墙本身是一张照片，两种外观下都保持压色。
public struct LoginWallScrimView: View {
    public init() {}

    @Environment(\.colorScheme) private var colorScheme

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let maxRadius = max(size.width, size.height)
            let light = colorScheme == .light
            let tint: Color = light ? .white : .black
            // 强度按外观取（见 `LoginWallStyle.scrimStrength`）：日间白纱只要薄薄一层，
            // 压到夜间那个量级会把整面墙洗成灰雾。
            let s = LoginWallStyle.scrimStrength(for: colorScheme)

            ZStack {
                tint.opacity(0.46 * s)

                // 反向聚光灯——卡片正后方最暗，于是卡片的对比度不必去跟底下的画打架。
                RadialGradient(
                    stops: [
                        .init(color: tint.opacity(0.90 * s), location: 0),
                        .init(color: tint.opacity(0.84 * s), location: 0.34),
                        .init(color: tint.opacity(0.56 * s), location: 0.56),
                        .init(color: tint.opacity(0.18 * s), location: 0.78),
                        .init(color: .clear, location: 1)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: maxRadius * 0.62
                )

                // 镜头暗角。
                RadialGradient(
                    colors: [.clear, tint.opacity(0.26 * s), tint.opacity(0.88 * s)],
                    center: .center,
                    startRadius: maxRadius * 0.18,
                    endRadius: maxRadius * 0.82
                )

                // 上下电影感压暗。
                LinearGradient(
                    stops: [
                        .init(color: tint.opacity(0.72 * s), location: 0),
                        .init(color: tint.opacity(0.18 * s), location: 0.22),
                        .init(color: .clear, location: 0.42),
                        .init(color: tint.opacity(0.12 * s), location: 0.68),
                        .init(color: tint.opacity(0.74 * s), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
    }
}

/// 静态胶片颗粒板。
///
/// **刻意不动**：漂移肉眼看不出来，而这里挂一个 SwiftUI 动画会让整个窗口的渲染循环
/// 一直转。当静态贴图合成则一分钱不花。
public struct LoginWallFilmGrainView: View {
    public init() {}

    private let tile = LoginWallNoiseTexture.size

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Image(platform: LoginWallNoiseTexture.image)
                .resizable(resizingMode: .tile)
                .frame(width: size.width + tile, height: size.height + tile)
                .frame(width: size.width, height: size.height)
                .opacity(0.055)
                .blendMode(.overlay)
        }
        .allowsHitTesting(false)
    }
}

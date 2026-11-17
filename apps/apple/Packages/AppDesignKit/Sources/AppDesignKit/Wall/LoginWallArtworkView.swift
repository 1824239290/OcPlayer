import SwiftUI

/// tile 的离线那一半：一颗种子决定的渐变构图。
///
/// 真实海报到位前它就是那张封面，本机没有这张图时它**永久**顶替。只用渐变和形状，
/// 不用 `.blur()`——后者会给每张 tile 逼出一次离屏合成。
struct LoginWallArtworkView: View {
    let art: LoginWallArt
    let title: String
    let year: Int?
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            gradientField
            LinearGradient(
                colors: [.clear, .black.opacity(0.30), .black.opacity(0.92)],
                startPoint: .center,
                endPoint: .bottom
            )
            titleBlock
        }
        .clipShape(RoundedRectangle(cornerRadius: LoginWallStyle.cornerRadius, style: .continuous))
    }

    private var gradientField: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(hue: art.hue, saturation: 0.44, brightness: 0.36),
                    Color(hue: wrap(art.hue + 0.09), saturation: 0.60, brightness: 0.18),
                    Color(hue: wrap(art.hue - 0.07), saturation: 0.52, brightness: 0.07)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            GeometryReader { geometry in
                ForEach(art.blobs.indices, id: \.self) { index in
                    let blob = art.blobs[index]
                    let radius = blob.radius * geometry.size.width
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(hue: blob.hue, saturation: 0.68, brightness: 0.66)
                                        .opacity(blob.opacity),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: radius
                            )
                        )
                        .frame(width: radius * 2, height: radius * 2)
                        .position(x: blob.x * geometry.size.width, y: blob.y * geometry.size.height)
                }
            }

            // 斜掠过纸面的一道光，像过塑海报的反光。
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.12), .white.opacity(0.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .rotationEffect(.degrees(art.streakAngle))
                .scaleEffect(2.6)
                .blendMode(.plusLighter)
        }
    }

    /// 标题块。**没有标题就不画**：首次安装时墙上全是程序化封面，编不出标题，
    /// 画一行假字比留白更糟。
    @ViewBuilder
    private var titleBlock: some View {
        if !title.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: max(10, width * 0.098), weight: .bold, design: .rounded))
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.leading)
                if let year {
                    Text(String(year))
                        .font(.system(size: max(8, width * 0.072), weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.75), radius: 4, y: 1)
            .padding(.horizontal, width * 0.085)
            .padding(.bottom, width * 0.10)
        }
    }

    private func wrap(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder < 0 ? remainder + 1 : remainder
    }
}

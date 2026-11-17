import SwiftUI

/// 墙上方两团柔和的色晕：冷紫在左下、品牌橙在右上。
///
/// ## 为什么是**静态**的（而演示里是漂移的）
///
/// 演示用两个 `CABasicAnimation` 让色晕缓慢反向漂移，理由是「SwiftUI 的
/// `repeatForever` 会让整个窗口每帧重新 diff」（那条结论本仓也认）。但漂移本身
/// 幅度只有 ±26pt、周期 23 秒——在一面被遮罩压过的海报墙上几乎看不出来，而代价是
/// 一整套 AppKit / UIKit 分叉（`wantsLayer`、`layer` 的可选性、`alphaComponent`、
/// `layout()` vs `layoutSubviews()`）。
///
/// 静态渐变合成在**两个平台上都完全不花 CPU**（没有时钟、没有图层动画），
/// 视觉差别可以忽略，所以这里取静态。要恢复漂移的话，记得把上面那些分叉一起写回来。
///
/// 两团色斑用径向渐变、alpha 到边缘归零，所以叠在一起是「色晕」而不是两个圆。
public struct LoginWallAtmosphereView: View {
    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let unit = max(size.width, size.height)

            ZStack {
                bloom(color: LoginWallStyle.violet.opacity(0.20), diameter: unit * 1.4)
                    .position(x: size.width * 0.15, y: size.height * 0.75)
                bloom(color: LoginWallStyle.accent.opacity(0.17), diameter: unit * 1.3)
                    .position(x: size.width * 0.86, y: size.height * 0.20)
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
    }

    private func bloom(color: Color, diameter: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: color, location: 0),
                        .init(color: color.opacity(0.34), location: 0.45),
                        .init(color: color.opacity(0), location: 1)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: diameter / 2
                )
            )
            .frame(width: diameter, height: diameter)
    }
}

/// 卡片后面那层颜色绽放（同样静态，理由见 `LoginWallAtmosphereView`）。
public struct LoginWallGlowView: View {
    public let color: Color

    public init(color: Color) {
        self.color = color
    }

    public var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    stops: [
                        .init(color: color.opacity(0.34), location: 0),
                        .init(color: LoginWallStyle.violet.opacity(0.16), location: 0.42),
                        .init(color: color.opacity(0), location: 1)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 310
                )
            )
            .allowsHitTesting(false)
    }
}

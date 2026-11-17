import SwiftUI

/// 背景：一整面**静止**的海报墙，随指针倾斜。
///
/// 没有时钟、没有跑马灯。唯一会变的是倾斜量，而它只在指针移动时重算——
/// 没人碰的窗口一帧都不多画。
///
/// ## 结构：墙是**一张图**，每帧只动它的变换
///
/// 墙的像素由 `LoginWallRasterizer` 合成成一张位图（见那里的理由与实测数字）。
/// 这里只做三件事：
///
/// 1. 由视口算出 `LoginWallLayout`；
/// 2. 让 `LoginWallRaster` 去拿／维护那张合成图——它是 `Equatable` 的，指针变化
///    不会让它重跑 `body`；
/// 3. 对那张图施加 3D 倾斜 / 位移 / 缩放。**只有几何**，所以指针移动的代价是
///    一次图层变换，而不是重新合成一百多个 tile。
public struct LoginWallView: View {
    public let catalog: [LoginWallPoster]
    /// 归一化到 −1...1 的指针位置；`.zero` = 不倾斜。
    public let pointer: CGPoint
    public let motionEnabled: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    public init(catalog: [LoginWallPoster], pointer: CGPoint, motionEnabled: Bool) {
        self.catalog = catalog
        self.pointer = pointer
        self.motionEnabled = motionEnabled
    }

    public var body: some View {
        GeometryReader { geometry in
            // tile 数量由视口算出来，所以小窗口造一面小墙——也就只解码它显示的那些封面。
            let layout = LoginWallLayout(size: geometry.size, catalogSize: catalog.count)

            LoginWallRaster(
                catalog: catalog,
                layout: layout,
                scheme: colorScheme,
                scale: displayScale
            )
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .modifier(LoginWallPerspective(pointer: pointer, motionEnabled: motionEnabled))
        }
        .allowsHitTesting(false)
        // 整面墙是纯装饰：几十张海报逐个进无障碍树只会把读屏用户淹掉，
        // 而且它们既没有标题也不可交互。卡片那边才是真正要读的内容。
        .accessibilityHidden(true)
    }
}

/// 合成图的持有者，也是**指针移动碰不到的那一层**。
///
/// `Equatable` 是这里的重点：指针每动一次，父视图就重建一次这个值，但值没变，
/// SwiftUI 便跳过 `body`——于是既不会重算 `.task(id:)` 的键，也不会重画那张图。
private struct LoginWallRaster: View, Equatable {
    let catalog: [LoginWallPoster]
    let layout: LoginWallLayout
    let scheme: ColorScheme
    let scale: CGFloat

    /// 合成图。`nil` = 还没画好（首帧、刚改过尺寸），此时直接画 `LoginWallRasterContent`
    /// 兜底——同一份 tile 代码，所以观感是连续的，不会先白一下。
    @State private var raster: PlatformImage?

    /// `nonisolated`：只比 `Sendable` 的存储属性，不碰 main actor 上的任何东西。
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.layout == rhs.layout
            && lhs.scheme == rhs.scheme
            && lhs.scale == rhs.scale
            && lhs.catalog == rhs.catalog
    }

    var body: some View {
        canvas
            .task(id: RasterRequest(catalog: catalog, layout: layout, scheme: scheme)) {
                // 拖窗口时视口每帧都在变：等它停下来再画，别一帧一张合成图。
                // 这期间显示的是上一张图被拉到新尺寸，比每帧重画稳得多。
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                raster = await LoginWallRasterizer.raster(
                    catalog: catalog,
                    layout: layout,
                    scale: scale,
                    backdrop: LoginWallStyle.backdrop(for: scheme)
                )
            }
    }

    @ViewBuilder
    private var canvas: some View {
        if let raster {
            Image(platform: raster)
                .resizable()
                .interpolation(.high)
                .frame(width: layout.totalWidth, height: layout.totalHeight)
        } else {
            LoginWallRasterContent(
                catalog: catalog,
                layout: layout,
                images: [:],
                backdrop: LoginWallStyle.backdrop(for: scheme)
            )
        }
    }

    /// `.task(id:)` 的键。只有这三样会改变墙的像素，指针不在其中。
    private struct RasterRequest: Hashable {
        let catalog: [LoginWallPoster]
        let layout: LoginWallLayout
        let scheme: ColorScheme
    }
}

/// 整面墙的 3D 呈现，一次施加而不是逐列施加。
///
/// 只做几何变换——没有任何会作废子视图的东西，所以指针移动时它不重画那张合成图。
private struct LoginWallPerspective: ViewModifier {
    let pointer: CGPoint
    let motionEnabled: Bool

    private var offset: CGPoint { motionEnabled ? pointer : .zero }

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(LoginWallStyle.tiltDegrees - offset.y * LoginWallStyle.pointerTiltDegrees),
                axis: (x: 1, y: 0, z: 0),
                anchor: .center,
                perspective: 0.55
            )
            .rotation3DEffect(
                .degrees(offset.x * LoginWallStyle.pointerTiltDegrees * 1.7),
                axis: (x: 0, y: 1, z: 0),
                anchor: .center,
                perspective: 0.35
            )
            .offset(
                x: offset.x * LoginWallStyle.parallaxPoints,
                y: offset.y * LoginWallStyle.parallaxPoints * 0.55
            )
            .scaleEffect(LoginWallStyle.contentScale)
    }
}

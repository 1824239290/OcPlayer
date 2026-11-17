import CoreGraphics
import Foundation
import SwiftUI

/// 把整面海报墙**合成成一张位图**。
///
/// ## 为什么是「一张图」
///
/// 墙原来是一百多个 tile 视图：每个都有自己的圆角、描边、阴影、渐变，其中一部分
/// 还带 `plusLighter` 混合。指针一动，SwiftUI 就要把这棵树的 display list 整个重新
/// 生成、再把整窗重新合成一遍——实测指针移动时稳定吃掉一个核的 40% 以上，而画面
/// 只是「一面墙被轻轻推了一下」。
///
/// 合成成一张位图之后，每帧要动的只剩**一张纹理的变换**（`rotation3DEffect` +
/// `offset` + `scaleEffect`），实测降到 11%。
///
/// 顺带把**加载**也变成了一次：原来墙上每个 tile 各自去取图、各自解码，同一张海报
/// 在墙里出现两三次就解码两三次。这里先按 `poster.id` 去重、只解墙上真正用到的
/// 那几十张，画进一张图之后原图就可以放掉。
///
/// ## 什么时候会重画
///
/// 只在「视口尺寸 / 素材 / 外观」变化时。窗口拖拽会连续改变视口，所以调用方
/// （`LoginWallView`）先等一小会儿再画；这期间显示的是上一张合成图被拉伸到新尺寸
/// ——比每帧重画一张要稳得多。
@MainActor
public enum LoginWallRasterizer {

    /// 合成图长边的像素上限。整面墙约 1500×1200pt，2× 是 3000×2400；再大只是白占显存。
    static let maximumPixelExtent: CGFloat = 4096

    /// 画一张墙。`nil` = 没有素材（空库）或渲染失败，调用方退直接画。
    public static func raster(
        catalog: [LoginWallPoster],
        layout: LoginWallLayout,
        scale: CGFloat,
        backdrop: Color
    ) async -> PlatformImage? {
        guard !catalog.isEmpty, layout.tileCount > 0 else { return nil }

        let images = await decodePosters(catalog: catalog, layout: layout)
        guard !Task.isCancelled else { return nil }

        let content = LoginWallRasterContent(
            catalog: catalog,
            layout: layout,
            images: images,
            backdrop: backdrop
        )

        let renderer = ImageRenderer(content: content)
        renderer.scale = effectiveScale(scale, layout: layout)
        // 底色已经烘进去了，所以这张图没有透明像素——省掉 alpha 通道。
        renderer.isOpaque = true

        guard let cgImage = renderer.cgImage else { return nil }
        return makePlatformImage(cgImage, pointSize: layout.canvasSize)
    }

    /// 墙画布的点尺寸。
    private static func effectiveScale(_ scale: CGFloat, layout: LoginWallLayout) -> CGFloat {
        let extent = max(layout.totalWidth, layout.totalHeight)
        guard extent > 0 else { return 1 }
        return max(1, min(scale, maximumPixelExtent / extent))
    }

    private static func makePlatformImage(_ cgImage: CGImage, pointSize: CGSize) -> PlatformImage {
        #if canImport(UIKit)
        return UIImage(cgImage: cgImage)
        #else
        return NSImage(cgImage: cgImage, size: pointSize)
        #endif
    }

    /// 解出墙上真正用到的那些海报，**同一张只解一次**。
    ///
    /// 墙的排布让同一张海报在大窗口里合法地出现多次（见 `LoginWallPlan.rowStride`），
    /// 所以去重不是优化而是必需：不去重的话一张图会被解三四遍。
    private static func decodePosters(
        catalog: [LoginWallPoster],
        layout: LoginWallLayout
    ) async -> [String: PlatformImage] {
        let columns = LoginWallPlan.make(
            catalog: catalog,
            columns: layout.columnCount,
            rows: layout.rowCount
        )

        var seen = Set<String>()
        var posters: [LoginWallPoster] = []
        for column in columns {
            for tile in column.tiles where seen.insert(tile.poster.id).inserted {
                posters.append(tile.poster)
            }
        }
        guard !posters.isEmpty else { return [:] }

        // 并发取图；`LoginWallImageStore` 自己会收敛同一张的并发请求。
        var images: [String: PlatformImage] = [:]
        await withTaskGroup(of: (String, PlatformImage?).self) { group in
            for poster in posters {
                group.addTask { (poster.id, await LoginWallImageStore.shared.image(for: poster)) }
            }
            for await (id, image) in group {
                if let image { images[id] = image }
            }
        }
        return images
    }
}

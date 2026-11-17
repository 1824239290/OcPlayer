import SwiftUI

/// 墙的**像素**：整面墙画一遍，不带状态、不依赖指针、不异步。
///
/// 只有这一个实现，两处共用：
///
/// * `LoginWallRasterizer` 用它把整面墙 `ImageRenderer` 成**一张**位图（正式路径）；
/// * `LoginWallView` 在合成图还没出来时直接画它兜底——首帧、以及跑不了 `.task`
///   的 `ImageRenderer` 测试环境。
///
/// 合成图到位前的那几帧因此和合成图**逐像素同源**：同一份布局、同一份 tile 代码，
/// 换的只是「画到屏幕」还是「画到一张图里」。
struct LoginWallRasterContent: View {
    let catalog: [LoginWallPoster]
    let layout: LoginWallLayout
    /// poster.id → 已解码的位图。缺的那几张退程序化封面。
    let images: [String: PlatformImage]
    /// 垫在墙下面的底色。烘进合成图里，于是合成图可以是**不透明**的——
    /// 少一个 alpha 通道，也少一次逐帧混合。
    let backdrop: Color

    var body: some View {
        let columns = LoginWallPlan.make(
            catalog: catalog,
            columns: layout.columnCount,
            rows: layout.rowCount
        )

        HStack(spacing: layout.spacing) {
            ForEach(columns) { column in
                LoginWallRasterColumn(column: column, layout: layout, images: images)
            }
        }
        .frame(width: layout.totalWidth, height: layout.totalHeight)
        // 压色只作用在墙上，不作用在底色上——所以底色在它**之后**才垫进来。
        .saturation(LoginWallStyle.wallSaturation)
        .brightness(LoginWallStyle.wallBrightness)
        .background(backdrop)
    }
}

/// 墙里的一列。tile 的抖动与微移是位置的纯函数（见 `LoginWallPlan`），所以这里
/// 不需要任何随机数、任何缓存。
private struct LoginWallRasterColumn: View {
    let column: LoginWallPlan.Column
    let layout: LoginWallLayout
    let images: [String: PlatformImage]

    var body: some View {
        VStack(spacing: layout.spacing) {
            ForEach(column.tiles) { tile in
                LoginWallCardView(
                    poster: tile.poster,
                    width: layout.columnWidth,
                    image: images[tile.poster.id]
                )
                .frame(width: layout.columnWidth, height: layout.tileHeight)
                .rotationEffect(.degrees(tile.tilt))
                .offset(y: tile.offset)
            }
        }
        .frame(width: layout.columnWidth, height: layout.totalHeight, alignment: .top)
        // 列内 tile 的微移会探出列边界，裁掉——否则相邻两列会互相压边。
        .clipped()
    }
}

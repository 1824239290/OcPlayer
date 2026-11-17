import SwiftUI

/// 单张 tile：底下是程序化封面，真海报到了盖在上面。
///
/// 刻意**纯展示**——没有 `@State`、没有异步、不自己去取图。位图由调用方
/// （`LoginWallRasterizer` 先批量取好，或 `LoginWallRasterContent` 直接留空）交进来，
/// 于是这个视图可以被 `ImageRenderer` 同步渲染进一张合成图里。
struct LoginWallCardView: View {
    let poster: LoginWallPoster
    let width: CGFloat
    let image: PlatformImage?

    var body: some View {
        ZStack {
            // 有真海报就**不画**程序化封面：那张封面会被 `scaledToFill` 完全盖住，
            // 画它只是白白多出三团径向渐变加一个 `plusLighter` 混合。真海报是异步到的，
            // 到之前 `image` 是 nil，那几帧正好由程序化封面顶着——观感与原来一致。
            if let image {
                Image(platform: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LoginWallArtworkView(
                    art: poster.art,
                    title: poster.title,
                    year: poster.year,
                    width: width
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: LoginWallStyle.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LoginWallStyle.cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
        // 墙整体已经在无障碍树里隐藏（`LoginWallView`），这里不再逐张挂标签。
    }
}

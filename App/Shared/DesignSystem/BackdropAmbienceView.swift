import CoreModel
import SwiftUI

/// 全页氛围背景（Emby 详情页同款）：一张 backdrop 铺满整页、高斯模糊后
/// 压暗（夜间）/ 雾化（日间），内容浮在上面滚动。
///
/// 纯装饰层：取不到图（`url == nil`）时整体不渲染，页面自然回退到
/// `Color.pageBackground` 纯色。详情页放单图，首页由 `AmbientBackdropCarousel`
/// 换着放，共用这里的遮罩与裁剪。
struct BackdropAmbienceView: View {
    enum Scrim {
        /// 详情页：大段正文浮在上面，遮罩适中，底部渐隐进页面底色。
        case detail
        /// 首页：Rail 标题、卡片直接压在背景上，遮罩再重一档保对比度。
        case home
    }

    /// `MediaItem.imageTarget` 的产物。模糊底图给 800 宽的小图 + 512px 解码
    /// 下采样就够——反正要糊掉，别为氛围图拉原画。
    let target: (url: URL?, authHeader: String?)
    var scrim: Scrim = .detail

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let url = target.url {
            RemoteImage(url: url, authHeader: target.authHeader, maxPixelSize: 512)
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 4e7287e 的教训：fill 的溢出尺寸会参与布局、撑高兄弟图层，
                // 必须先钳回定界原位裁掉。
                .clipped()
                // 模糊会让图片边缘发虚透光，放大一点把虚边推出可视区，
                // 再钳回布局边界——blur/scale 的输出会画出 frame，
                // 不裁的话会盖到 macOS 侧栏等兄弟层上。
                .blur(radius: colorScheme == .light ? 36 : 28)
                .scaleEffect(1.12)
                .clipped()
                .overlay { scrimGradient }
                .ignoresSafeArea()
        }
    }

    /// 模式自适应遮罩：夜间黑纱压暗、日间白雾化（黑字内容的对比度由白雾保证），
    /// 底部统一渐隐到 `pageBackground`，让长内容区沉回页面底色。
    /// `pageBackground` 本身随模式取值，所以只有 tint 两个 stop 需要分模式。
    private var scrimGradient: some View {
        let light = colorScheme == .light
        let tint: Color = light ? .white : .black
        let top: Double
        let mid: Double
        switch scrim {
        case .detail:
            top = light ? 0.5 : 0.22
            mid = light ? 0.6 : 0.4
        case .home:
            top = light ? 0.55 : 0.28
            mid = light ? 0.66 : 0.48
        }
        return LinearGradient(
            stops: [
                .init(color: tint.opacity(top), location: 0),
                .init(color: tint.opacity(mid), location: 0.45),
                .init(color: Color.pageBackground.opacity(0.88), location: 0.85),
                .init(color: Color.pageBackground, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .animation(.easeInOut(duration: 0.5), value: colorScheme)
    }
}

import CoreModel
import SwiftUI

/// 全页氛围背景（Emby 详情页同款）：一张 backdrop 铺满整页、高斯模糊后垫底，
/// 内容浮在上面滚动。
///
/// 纯装饰层：取不到图（`url == nil`）时整体不渲染，页面自然回退到
/// `Color.pageBackground` 纯色。详情页放单图，首页由 `AmbientBackdropCarousel`
/// 换着放，共用这里的遮罩与裁剪。
struct BackdropAmbienceView: View {
    enum Scrim: Equatable {
        /// 详情页：顶部要浮白字头部（Logo 白字兜底 / metaRow 白字 / 白胶囊播放钮），
        /// 遮罩顶部两种外观下都压暗，下半段沉回页面底色。
        case detail
        /// 首页：Rail 标题、卡片直接压在背景上，全屏均衡的雾化/压暗。
        case home
        /// 侧栏列：行条目全高分布，底部不能沉回页面底色——那正是要修的
        /// 「侧栏底下空白」。全高均匀压暗保行文字可读，图一直透到底。
        case sidebar
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
                // 半径取低档：背景要能认出是哪部剧的海报。
                .blur(radius: colorScheme == .light ? 20 : 14)
                .scaleEffect(1.12)
                .clipped()
                .overlay { scrimGradient }
                .ignoresSafeArea()
        }
    }

    /// 模式自适应遮罩。`pageBackground` 本身随模式取值，分模式的只是 tint。
    private var scrimGradient: some View {
        let light = colorScheme == .light
        return Group {
            switch scrim {
            case .detail:
                // 全屏遮罩保持模式自适应：日间白雾、夜间黑纱，下半段沉回
                // 页面底色。白字头部的压暗不在这层——那会把日间上半屏
                // 染成浑浊过渡带；它绑在详情页英雄区视图上随头部滚动。
                let tint: Color = light ? .white : .black
                LinearGradient(
                    stops: [
                        .init(color: tint.opacity(light ? 0.5 : 0.22), location: 0),
                        .init(color: tint.opacity(light ? 0.6 : 0.4), location: 0.45),
                        .init(color: Color.pageBackground.opacity(0.88), location: 0.85),
                        .init(color: Color.pageBackground, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            case .home:
                // 全屏均衡档：夜间黑纱、日间白雾，底部渐隐回页面底色。
                let tint: Color = light ? .white : .black
                LinearGradient(
                    stops: [
                        .init(color: tint.opacity(light ? 0.55 : 0.28), location: 0),
                        .init(color: tint.opacity(light ? 0.66 : 0.48), location: 0.45),
                        .init(color: Color.pageBackground.opacity(0.88), location: 0.85),
                        .init(color: Color.pageBackground, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            case .sidebar:
                // 侧栏列专档：只压暗不收底，图要透到列底（否则侧栏下半截
                // 又是一块空玻璃）。夜间黑纱、日间白雾，首尾差一档制造纵深。
                let tint: Color = light ? .white : .black
                LinearGradient(
                    stops: [
                        .init(color: tint.opacity(light ? 0.5 : 0.3), location: 0),
                        .init(color: tint.opacity(light ? 0.62 : 0.52), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .animation(Motion.theme, value: colorScheme)
    }
}

// MARK: - 侧栏氛围声明

/// 页面向常规布局侧栏（Mac/iPad）声明的氛围底：侧栏玻璃只对窗外取景，
/// 垫在 split view 或窗口容器底下的内容都透不出来（scratch 实测），所以
/// `AppShellView.sidebar` 在有声明时摘掉系统玻璃底、把同一张图直接垫进列内。
/// 页面出现时声明、离屏时撤回（`windowAmbience(_:)`）；紧凑布局没有侧栏，
/// 声明无人消费，纯 no-op。
struct WindowAmbience: Hashable {
    var url: URL?
    var authHeader: String?
}

private struct WindowAmbienceSetter: ViewModifier {
    @Environment(AppModel.self) private var app
    let ambience: WindowAmbience?

    /// `url` 为空的声明视同无氛围：页面自己的氛围层同样不渲染，
    /// 侧栏保持系统玻璃原样，不能摘了底却什么都没垫。
    private var effective: WindowAmbience? {
        (ambience?.url != nil) ? ambience : nil
    }

    func body(content: Content) -> some View {
        content
            .onAppear { app.windowAmbience = effective }
            // 声明可能在页面存续期间晚到（详情页数据加载后才有 backdrop 图）。
            .onChange(of: effective) { _, newValue in app.windowAmbience = newValue }
            .onDisappear {
                // 只撤自己声明的值：push 新页时本页 onDisappear 可能晚于
                // 新页 onAppear，不能把人家刚声明的清掉。
                if app.windowAmbience == effective { app.windowAmbience = nil }
            }
    }
}

extension View {
    /// 声明本页的侧栏氛围底。传 `nil`（或 url 为空）表示本页没有氛围，
    /// 出现时会顺手清掉残留声明，让侧栏回到系统玻璃。
    func windowAmbience(_ ambience: WindowAmbience?) -> some View {
        modifier(WindowAmbienceSetter(ambience: ambience))
    }
}

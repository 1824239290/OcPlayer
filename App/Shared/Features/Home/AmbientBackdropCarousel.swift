import AppDesignKit
import CoreModel
import SwiftUI

/// 何时尝试装载氛围池。
///
/// 抽成纯值是为了可测：这里的判断错一次，后果是**整个会话都停在纯色底**
/// —— 而它恰恰只在冷启动抢跑时才出错，平时看不出来。
///
/// 实机日志（2026-09-30）就是这个场景：启动瞬间网络还没就绪，五个请求全部
/// `-1009`，其中氛围池的 `randomBackdropItems` 与它的回退源（`home.latest` /
/// `resume` / `nextUp`）**同时为空** → 池子装不上；而 `.task(id:)` 只认
/// `sessionGeneration`，它没变 → 这个会话再也不会重试，背景灰到关 App。
/// 下次启动网络恰好就绪，于是"自己好了"——这种偶发性正是它难被发现的原因。
struct BackdropCarouselTrigger: Hashable {
    let session: Int
    /// 是否值得再试一次。
    let shouldRetry: Bool
    /// 当前生效的服务器地址。地址换了（局域网 → Tailscale）时池子里的图片 URL
    /// 全部指着刚失效的那条，必须重拉一遍 —— 服务器地址是运行时决议的，视图不重建
    /// 就发现不了（`MediaServer` 的 `profile.baseURL` 不是可观察状态）。
    let endpoint: String?

    init(
        sessionGeneration: Int,
        poolIsEmpty: Bool,
        hasHomeFallback: Bool,
        endpoint: String? = nil
    ) {
        self.session = sessionGeneration
        self.endpoint = endpoint
        // 池子空着 + 首页数据已到位 = 一次值得重试的机会。
        // 池子装好后 `shouldRetry` 恒为 false，触发键稳定在 session 上，
        // 不会因为首页后续刷新（isLoading 翻转等）反复重启换片循环。
        self.shouldRetry = poolIsEmpty && hasHomeFallback
    }
}

/// 首页氛围背景的**渲染层**：把 `AppModel` 里氛围池当前那张图铺成模糊+雾化的
/// 固定底，每 12 秒淡入淡出换一张（节奏见 `AmbiencePool.swapInterval`）。
///
/// 装载与换片循环**不在这里**——池子的所有权与驱动都在模型侧
/// （`AppModel+Ambience`，由 `AppShellView` 根节点单点驱动）。这么分是因为池子
/// 不只服务首页：轮播当前那张还要给 iOS 上所有"自垫背景"的页面当图源，而原先
/// 池子住在该视图的 `@State` 里、视图只挂在首页 Tab 内——冷启动直奔别的 Tab 时
/// 那些页面整个会话都是纯色底。渲染仍留在原位（macOS 在整窗层、iOS 在首页 Tab 内），
/// 只是改成读模型。
///
/// 纯装饰：池子空（查询失败 / 库里没有带 backdrop 的条目）时整体不出现，
/// 页面回退纯色底。
///
/// 氛围图**常开**：设置页原有的「海报氛围背景」开关与 `SettingsKeys.ambientBackdrop`
/// 已一并移除，首页与详情页一律铺氛围底。旧偏好键不再有任何读取点——老用户盘上
/// 残留的 `false` 是死键，升级后氛围图照常出（见 CHANGELOG）。
struct AmbientBackdropCarousel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.isWindowFullscreen) private var isWindowFullscreen

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                if app.ambiencePoolIsLoaded {
                    BackdropAmbienceView(
                        target: app.currentAmbienceTarget,
                        scrim: .home
                    )
                    .transition(.section)
                }
            }
            .animation(Motion.ambient, value: app.ambienceIndex)

            // 全屏顶栏是不透明硬底（macOS 26 系统行为），顶部向窗口底色渐隐衔接；
            // 窗口态工具栏透明，图直接透出。见 FullscreenTitlebarFade。
            // **放在换片动画作用域之外**：放进去换片时会被交叉淡入卷着一起动，
            // 背景里滑出一条渐变带（全屏下肉眼可见）。
            if isWindowFullscreen {
                FullscreenTitlebarFade()
                    .transition(.section)
            }
        }
        .animation(Motion.ambient, value: isWindowFullscreen)
    }
}

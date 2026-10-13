import AppDesignKit
import CoreModel
import SwiftUI

/// 页面级氛围底的统一入口。
///
/// ## 为什么要有这一层
///
/// 两个平台拿到底图的方式**根本不同**，而这件事此前散落在 7 个调用点上各写一遍：
///
/// * **macOS**：`AppShellView` 根节点垫了一份常驻的整窗层（导航栈宿主透明），
///   所以**任何没画底的页面自动就有背景**；只有当页面有自己的主体图（详情页的
///   backdrop、资源页的海报）时才需要声明覆盖它。
/// * **iOS**：UIKit 宿主**不透明**（`WindowAmbience.reachesScreen == false`，
///   栈后垫层到不了屏幕），页面必须**自己垫**，否则落在系统纯色底上
///   （夜间=黑、日间=白）。
///
/// 分叉只允许存在于本文件。调用点只说"我这页的氛围底是什么"，不再关心平台差异——
/// 加一页就少一处漏（实测漏了 11 类页面：搜索 Tab、媒体库、Bangumi 四页、
/// 设置 10 个子页、管理服务器、开源许可证）。
///
/// ## 两条硬约束（都是本仓踩过的判例）
///
/// 1. **用 `.background {}` 挂载，不做 ZStack 兄弟节点**：`fill` 的溢出尺寸会参与
///    布局、把根布局撑大（macOS 侧栏时代实测两回，内容列被顶出屏幕）。
/// 2. **iOS 层不许加 `.drawingGroup()`**：它把子树栅格化进离屏纹理，纹理边界取的是
///    扩展前的 frame，会把链尾的 `.ignoresSafeArea()` 截断——图出不了内容区，到不了
///    iPad 侧栏玻璃底下（`987f3bc`）。只有 macOS 的整窗层可以加（那边确实需要
///    离屏合成来压住反复模糊的开销）。
struct AmbienceTarget: Equatable {
    /// 底图地址与鉴权头（`MediaItem.imageTarget` 的产物）。
    var url: URL?
    var authHeader: String?
    /// 遮罩档位：详情页/资源页用 `.detail`（顶部压暗，给白字头部兜底），
    /// 其余页面用 `.home`（全屏均衡雾化）。
    var scrim: BackdropAmbienceView.Scrim = .home
    /// 图出现时的淡入节奏。默认 `Motion.ambient`（1.6s）；命中内存缓存的兜底图
    /// 要用短淡入（1.6s 在推页那 0.35s 里只走到 ~25% 不透明度，观感等于没兜住）。
    var fade: Animation? = Motion.ambient
    /// 本页是否**自带主体图**。
    ///
    /// 只影响 macOS：自带图 → 声明 `windowAmbience` 覆盖整窗层（内容与侧栏连成一张
    /// 连续的图）；不带 → no-op（整窗层的首页轮播就是它该有的背景）。iOS 两种都自垫。
    var ownsArt = false

    /// 会话池当前那张（首页轮播同源）。所有"不以某个条目为主体"的页面都用它：
    /// 同一个 URL 已在内存缓存里，push 首帧就能画、与前一页背景连续。
    @MainActor
    static func sessionPool(_ app: AppModel) -> AmbienceTarget? {
        let target = app.currentAmbienceTarget
        guard target.url != nil else { return nil }
        return AmbienceTarget(url: target.url, authHeader: target.authHeader, scrim: .home)
    }

    /// 空 URL 的声明视同"没有氛围"：页面回退 `Color.pageBackground` 纯色底，
    /// 不渲染空图层（`BackdropAmbienceView` 自己在 url 为 nil 时也不出图）。
    var isEmpty: Bool { url == nil }
}

// MARK: - 修饰符

private struct PageAmbienceModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    let target: AmbienceTarget?

    /// 页面是否要自己画氛围层。
    ///
    /// * macOS 常规布局：整窗层够得着屏幕，页面保持透明才能和侧栏连成一张图——
    ///   只有自带主体图的页面要覆盖它（走 `windowAmbience` 声明）。
    /// * iOS（`reachesScreen == false`）与紧凑布局（没有整窗层）：一律自垫。
    private var drawsOwnLayer: Bool {
        !WindowAmbience.reachesScreen || app.isCompact
    }

    /// macOS 整窗声明：只有自带主体图的页面才发。
    ///
    /// 不发声明时**主动传 nil 占位**（而不是挂 nil 就不调修饰符）：`windowAmbience`
    /// 的 nil 语义是"本页声明无氛围"，会盖住下层的声明——这正是从"有图的详情页"
    /// 返回"无图的详情页"时该有的行为。
    private var declaredAmbience: WindowAmbience? {
        guard WindowAmbience.reachesScreen, let target, !target.isEmpty else { return nil }
        return target.ownsArt
            ? WindowAmbience(url: target.url, authHeader: target.authHeader, scrim: target.scrim)
            : nil
    }

    func body(content: Content) -> some View {
        content
            .background {
                if drawsOwnLayer, let target, !target.isEmpty {
                    BackdropAmbienceView(
                        target: (url: target.url, authHeader: target.authHeader),
                        scrim: target.scrim,
                        fade: target.fade
                    )
                    .allowsHitTesting(false)
                    // 调用点显式退出安全区：页面自身的 `ignoresSafeArea` 用法会改变
                    // 本层继承到的安全区（详情页的滚动视图忽略顶部后，层内部的
                    // `ignoresSafeArea` 就不再生效，图会被裁到工具栏以下）。
                    .ignoresSafeArea()
                }
            }
            // 纯色兜底永远在氛围层之下：图没到位 / 没图时页面有底色，不会落在
            // systemBackground 之外的宿主底上（iOS 的 split view / 导航栈底）。
            .background {
                if drawsOwnLayer {
                    Color.pageBackground.ignoresSafeArea()
                }
            }
            .windowAmbience(declaredAmbience)
    }
}

extension View {
    /// 声明本页的氛围底（双端统一入口，见 `AmbienceTarget`）。
    ///
    /// 传 `nil` 或 url 为空的 target：iOS 自垫分支只出兜底纯色（页面不留白底），
    /// macOS 不发整窗声明——两者都等于"本页没有氛围图"，与传 nil 同义。
    func pageAmbience(_ target: AmbienceTarget?) -> some View {
        modifier(PageAmbienceModifier(target: target))
    }
}

// MARK: - 路由页的挂载点

/// 路由页统一挂载点：**一处覆盖六类 push 页面**（媒体库 / Bangumi 个人 / 收藏列表 /
/// 条目详情 / 每日放送 / 10 个设置子页）。
///
/// 在此之前这些页面在 iOS 上一律没有背景——因为"每个页面自己垫"意味着新增一页就
/// 漏一处（实测漏了 11 类）。挂在路由出口后，**新增 `Route` case 自动继承**，
/// 不需要谁记得登记。
///
/// **详情页显式让路**：它有自己的主体图（条目 backdrop + TMDB 补图 + 合集成员兜底），
/// 整窗声明由 `DetailView` 自己发，而且底图未就绪时发的是 nil（"本页暂无氛围"）。
/// 外层要是在它之后再声明一次，就会把它的声明盖掉、详情页背景消失——所以这里跳过它。
private struct RouteAmbienceModifier: ViewModifier {
    @Environment(AppModel.self) private var app
    let route: AppModel.Route

    func body(content: Content) -> some View {
        switch route {
        case .detail:
            content
        case .library, .bangumiProfile, .bangumiCollectionList, .bangumiSubject, .bangumiCalendar,
             .settingsSubpage:
            content.pageAmbience(AmbienceTarget.sessionPool(app))
        }
    }
}

extension View {
    /// 路由页的氛围底（见 `RouteAmbienceModifier`）。挂在 `appRouteView` 上，
    /// 覆盖全部路由页；详情页跳过（它自己声明）。
    func routeAmbience(_ route: AppModel.Route) -> some View {
        modifier(RouteAmbienceModifier(route: route))
    }
}

import AppDesignKit
import CoreModel
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

#if !os(macOS)
/// iOS 外壳的尺寸类口径：**标签栏那一层 iPad 恒紧凑，页面内容那一层按设备真实宽度**。
///
/// 为什么要分两层：`TabView` **自己那一层**的尺寸类决定标签栏形态 —— iPadOS 18 起系统
/// 默认把标签栏放顶部（Liquid Glass 胶囊），只有把那一层钉成紧凑档才会落回 iPhone 那样的
/// 底部栏（SwiftUI 没有公开 API 能直接选「底部栏」，见 `compactLayout` 的注释）。但内容
/// 不该跟着降级：用户口径是「**tabview 保留 iPhone 样式，其他所有都保持 iPad 的**」——
/// 首页 rail、媒体库列数、详情页头部、设置卡片全部按设备真实宽度。
///
/// 所以两个落点读同一个纯函数的两个 `Layer`：`TabView` 读 `.tabBar`，每个 Tab 的内容读
/// `.pageContent`。抽成纯函数是为了能用例钉住「哪一层被强制、哪一层不动」—— 系统怎么渲染
/// 只能靠实拍，但这条分层决策是我们自己的。
enum ShellSizeClass {
    /// 哪一层在读这个尺寸类。
    enum Layer {
        /// `TabView` 自己那一层：决定标签栏画成底部栏还是顶部胶囊。
        case tabBar
        /// Tab 的内容层（Tab 根页 + push 出来的页）：决定页面版式。
        case pageContent
    }

    /// - Parameters:
    ///   - idiom: 真实设备类型（`UIDevice.current.userInterfaceIdiom`）。
    ///   - actual: 真实的 `horizontalSizeClass`。
    ///   - layer: 谁在读。
    /// - Returns:
    ///   - `.tabBar` 且 iPad：恒 `.compact` —— 标签栏落到底部（iPhone 形态）。
    ///   - 其余一律**原样返回**：iPad 的内容保持它自己的常规宽度；iPhone 的 compact 是
    ///     常态；Pro Max 横屏的 regular 是它自己的版式。都不动。
    static func resolved(idiom: UIUserInterfaceIdiom,
                         actual: UserInterfaceSizeClass?,
                         layer: Layer) -> UserInterfaceSizeClass? {
        guard layer == .tabBar, idiom == .pad else { return actual }
        return .compact
    }
}
#endif

/// 主框架：macOS 用顶栏液态玻璃药丸（分区），iPhone / iPad 统一用底部 Tab。
/// 播放器不在导航体系里 —— `RootView` 层的覆盖层负责（见 `AppModel.presentedPlayer`）。
///
/// 侧栏（`NavigationSplitView`）已撤：macOS 的分区入口收进顶栏药丸，iOS 两端
/// 用 Tab；媒体库入口在首页「媒体库」栏，整列宽度让给内容。iPad 曾试过与
/// macOS 同款顶栏药丸：iOS 的导航栏自带白底玻璃条、氛围层垫在导航栈外到不了
/// 屏幕（见 `WindowAmbience.reachesScreen`），顶栏既不是悬浮药丸、首页背景也
/// 出不来——iPad 回归 Tab 方案。
///
/// **iPad 上只有标签栏走 iPhone 形态，内容全部保持 iPad 版式**（用户口径：
/// 「tabview 保留 iPhone 样式的，但其他所有都保持 iPad 的」）。
///
/// 两层分开读尺寸类，见 `ShellSizeClass`：`TabView` 那一层恒紧凑（标签栏因此落到
/// 底部），每个 Tab 的内容层换回设备真实宽度（首页 rail / 媒体库列数 / 详情页头部 /
/// 设置卡片都还是 iPad 档）。
struct AppShellView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Bangumi / MoviePilot 集成开关（默认开）。关掉后顶栏药丸 / Tab 的对应入口消失，
    /// 停用瞬间若正停在那个分区，选中回落到首页；详情页与后台活动由各自触点
    /// 读同一组 key 门控（见 SettingsKeys）。
    @AppStorage(SettingsKeys.bangumiEnabled) private var bangumiEnabled = true
    @AppStorage(SettingsKeys.moviepilotEnabled) private var moviepilotEnabled = true

    #if os(macOS)
    /// 原生全屏状态：进全屏时系统把工具栏搬进独立的 NSToolbarFullScreenWindow，
    /// 顶栏是它画的不透明硬底，窗口态「氛围图透过玻璃顶栏」不再成立——氛围层
    /// 顶部改向窗口底色渐隐衔接（`FullscreenTitlebarFade`）。
    @State private var isWindowFullscreen = false
    #endif

    var body: some View {
        layout
            // 横向留白跟**窗口宽度**走，不跟设备型号走：iPad 拖到 1/3 宽时
            // hSizeClass 已经是 compact，而 UIDevice 的 idiom 仍是 .pad
            // （见 `EnvironmentValues.contentLeading` 的注释）。
            // 口径跟**内容**层（`contentSizeClass`），不跟标签栏层：iPad 的内容是
            // iPad 版式，留白就该是 52pt；跟着标签栏的紧凑档走会变成 22pt 的错位。
            .environment(\.contentLeading, contentLeading)
            #if os(macOS)
            // 首页轮播等页面内的氛围层经它感知全屏（整窗层直接读 @State）。
            .environment(\.isWindowFullscreen, isWindowFullscreen)
            #endif
            // 背景挂在 AppShell 根节点，分区内容重建时不销毁轮播视图。
            // 仅 macOS：iOS 的 TabView / 导航栈宿主自带不透明底，垫在后面的层
            // 到不了屏幕——iOS 的首页轮播挂在首页 Tab 栈内（见 compactLayout）。
            #if os(macOS)
            .background { windowAmbienceLayer }
            #endif
            // 氛围池驱动：**双端唯一装载点**。放在这里（而不是首页那个视图里）是
            // 因为池子产的取图三元组被一堆页面消费——挂在首页 Tab 内时，
            // 冷启动直奔别的 Tab / 进设置子页就没人为它装载，那些页面整个会话都停在
            // 纯色底。触发键变化（换会话 / 换地址 / 首页数据到位可补救）会自动重跑。
            .task(id: app.ambienceTrigger) { await app.runAmbienceCarousel() }
            // 自动化深链（Debug-only）：`OCPLAYER_START_ROUTE` 指定的 push 页 /
            // 设置子页在这里落地——挂 AppShell 而不挂 RootView，是因为目标页依赖
            // 「布局已定型、isCompact 已设定」这个前提（push 按它分派栈）。
            .task { await app.applyLaunchRouteIfNeeded() }
            // 集成停用时把停留在该分区的选中回落到首页——否则顶栏药丸 / Tab 少了
            // 一项而 selection 还指着旧值，会渲染出无入口的孤儿分区。
            .onChange(of: bangumiEnabled) { _, enabled in
                if !enabled, app.selectedSection == .bangumi {
                    app.selectedSection = .home
                }
            }
            .onChange(of: moviepilotEnabled) { _, enabled in
                if !enabled, app.selectedSection == .moviepilot {
                    app.selectedSection = .home
                }
            }
            // 两段式换页要读 reduceMotion 决定是否直切，AppModel 无环境，注入副本。
            .onAppear { app.reduceMotion = reduceMotion }
            .onChange(of: reduceMotion) { _, newValue in app.reduceMotion = newValue }
    }

    /// **标签栏那一层**用的尺寸类（`TabView` 自己读它）。
    ///
    /// - macOS：真实值（`horizontalSizeClass` 常为 nil → 视作 regular）。
    /// - iOS：**iPad 恒 compact** —— 标签栏因此落到底部（iPhone 形态），见 `ShellSizeClass`。
    private var shellSizeClass: UserInterfaceSizeClass? {
        #if os(macOS)
        sizeClass
        #else
        ShellSizeClass.resolved(idiom: UIDevice.current.userInterfaceIdiom,
                                actual: sizeClass,
                                layer: .tabBar)
        #endif
    }

    /// **页面内容那一层**用的尺寸类（每个 Tab 的内容读它）。
    ///
    /// iPad 上它与 `shellSizeClass` 相反：**设备真实宽度**（常规宽度 → iPad 版式）。
    /// 用户口径「tabview 保留 iPhone 样式的，但其他所有都保持 iPad 的」在这里落地。
    private var contentSizeClass: UserInterfaceSizeClass? {
        #if os(macOS)
        sizeClass
        #else
        ShellSizeClass.resolved(idiom: UIDevice.current.userInterfaceIdiom,
                                actual: sizeClass,
                                layer: .pageContent)
        #endif
    }

    /// 页面横向留白：跟**内容**尺寸类走（iPad 52pt / iPhone 22pt）。
    ///
    /// 不跟标签栏那一层走 —— 标签栏的紧凑档只是为了让栏落到底部，内容既然还是
    /// iPad 版式，留白就必须是 iPad 档；否则会出现「内容是 iPad 版式、左右留白却是
    /// iPhone 的 22pt」这种错位。
    private var contentLeading: CGFloat {
        contentSizeClass == .compact ? Metrics.compactContentInset : Metrics.contentInset
    }

    @ViewBuilder
    private var layout: some View {
        #if os(macOS)
        splitLayout
        #else
        compactLayout
        #endif
    }

    // MARK: - Mac / iPad：顶栏导航组（无侧栏）

    private var splitLayout: some View {
        detailColumn
        #if os(macOS)
        // 全屏跟踪：willEnter 先行（衔接层赶在硬底亮相前就位），didExit 收尾；
        // 起窗对齐兜底「状态恢复直接以全屏起窗」——那时通知可能早于订阅。
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isWindowFullscreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isWindowFullscreen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            syncFullscreenFlag()
        }
        #endif
        .onAppear {
            syncFullscreenFlag()
            app.setCompact(false)
        }
    }

    /// Mac / iPad 共用一个导航栈；切分区只替换栈内根页面，避免系统宿主层
    /// 跟着整栈淡入，短暂盖住常驻的背景。
    private var detailColumn: some View {
        // pop 拦截：系统返回键 / 手势都是把变短的 path 写回 binding——先不落地，
        // 让当前页走与 push 对称的两段式（淡出 → 再出现上一层）。拦截逻辑收在
        // `AppModel.handleStackPathChange`，栈的写入口只有模型那一个。
        NavigationStack(path: Binding(
            get: { app.path },
            set: { app.handleStackPathChange($0) }
        )) {
            sectionContent
                .appRoutes()
                .appShellChrome()
        }
    }

    /// 某个 Tab 的独立栈 binding。写入口同样收在 AppModel（`navPaths` 是
    /// `private(set)`），视图只拿 binding、拿不到数组。
    private func navPathBinding(_ section: AppModel.Section) -> Binding<[AppModel.Route]> {
        Binding(
            get: { app.navPath(for: section) },
            set: { app.setNavPath($0, for: section) }
        )
    }

    #if !os(macOS)

    /// iPhone / iPad 底部 Tab：首页 /（Bangumi）/（MoviePilot）/ 设置 / 搜索。
    /// Bangumi、MoviePilot 两个 Tab 跟随设置里的启用开关显隐；媒体库入口在
    /// 首页「媒体库」栏（不占 Tab）。搜索走 `Tab(role: .search)` 放大镜 Tab
    /// ——不挂首页 `.searchable`：iOS 26/27 实测「minimize 搜索 + 导航栏存在
    /// 工具栏项」点 X 收起会被系统重新展开（循环无法关闭），搜索 Tab 彻底
    /// 脱离导航栏。每个 Tab 有独立导航栈（`navPaths`），详情页走 push 而非
    /// sheet——播放器覆盖层不再被遮住。
    ///
    /// 强调色不在这里管：整棵树吃 `RootView` 根节点钉的那一个中性 tint，标签栏
    /// 未选中项的灰与内容侧是**同一个来源**，新增 Tab 不需要补任何一句。
    ///
    /// **但「选中 = 原色」那三格是例外**（用户口径 2026-10-22：首页头像、Bangumi、
    /// MoviePilot 三格要统一成「选中彩色 / 未选中灰」）：SwiftUI 的 `Tab` 只吃一张图、
    /// 且不吃 label 上的绘制修饰符，两态图只能由 `compactLayout` 背景里那层
    /// `TabBarBrandIconBridge` 塞进 `UITabBarItem.image` / `.selectedImage`。
    /// 所以下面两个品牌 Tab 的 `image:` 仍然传**模板**资产（那是注入没赶上时的回落态，
    /// 也是未选中态本身）；本文件里不需要再写任何彩色资产。
    ///
    /// **每个 Tab 的内容都挂 `.pageContentSizeClass(contentSizeClass)`**：外壳在
    /// `compactLayout` 里为了标签栏把尺寸类钉成了紧凑档（见那里的注释），内容必须换成
    /// 设备真实的那一份，否则整页版式会跟着标签栏一起降级成 iPhone 档。新增 Tab 别忘了这一句。
    @TabContentBuilder<AppModel.Section>
    private var compactTabs: some TabContent<AppModel.Section> {
        // 五个 Tab 根页统一用 `pageAmbience`：它会按平台分叉（iOS 自垫 /
        // macOS 靠整窗层），调用点不再各自写一遍 `.background { BackdropAmbienceView }`。
        //
        // 两条历史约束仍成立，只是收进了 `PageAmbience`：
        //   * 必须走 `.background`（布局隔离）——氛围层做 ZStack 兄弟节点时其
        //     `ignoresSafeArea` 会把根布局撑到全窗宽、内容列被顶出屏幕；
        //   * 首页那一格垫的是**轮播组件本身**（不是单图），它会随 12s 换片自己淡入
        //     淡出——所以首页不走 `pageAmbience` 的单图语义。
        // 首页 Tab 的图标是**服务端上这个账号的头像**（对照产品 Rex 的「发现」栏位
        // 就是这个形态），没有头像时回落系统原来的 `house.fill`。
        //
        // ## 三条实测约束（iOS 26.3 / iPhone 17 Pro 模拟器实拍，别再踩）
        //
        // 1. **label 里不能有 `if/else`**。条件视图会让标签栏在那个位置画出一个约
        //    84pt 的**黑色圆角块**，图标与「首页」文字全被盖住（A/B 实拍：把条件
        //    换成单一 `Image` 立刻恢复正常）。所以条件提到 **Tab 这一层**，两个分支
        //    各自的 label 里只有一个 `Image`。
        // 2. **位图必须是 `alwaysOriginal`，而且要在 `UIImage` 上设**。否则标签栏把
        //    它当模板图渲染 —— 整张头像变成一坨纯色（浅色模式下是黑的，实测就是
        //    84pt 纯黑圆角块）。SwiftUI 的 `.renderingMode(.original)` 在这里不起作用。
        // 3. **位图要按点尺寸栅格化**。标签栏按图片的**自然尺寸**画，`.frame` /
        //    `.resizable()` / `.clipShape()` 全部被忽略：84px 的位图会被画成 84pt。
        //    所以裁圆、缩放、渲染模式三件事都在装载时烤进位图（见
        //    `AppModel+Avatar.swift` 的 `tabIcon(from:)`），这里只放一个裸 `Image`。
        //
        // 两个分支的 `value` 都是 `.home`：头像到位只是标签栏那一格换个图标，
        // 选中分区与内容栈都不受影响。
        //
        // **头像那一格的「选中原色 / 未选中灰化」不在这里表达**：label 里只能放一张
        // 彩色位图（上面第 1 条约束：条件视图会画出黑块），灰化后的那张由
        // `TabBarBrandIconBridge` 在标签栏侧按状态替换（它同样接管下面两个品牌 Tab）。
        if let avatar = app.userAvatarImage {
            Tab(value: AppModel.Section.home) {
                homeTabRoot
            } label: {
                Label {
                    Text("首页")
                } icon: {
                    Image(platform: avatar)
                }
            }
        } else {
            Tab("首页", systemImage: "house.fill", value: AppModel.Section.home) {
                homeTabRoot
            }
        }

        if bangumiEnabled {
            Tab("Bangumi", image: "bangumi-logo", value: AppModel.Section.bangumi) {
                NavigationStack(path: navPathBinding(.bangumi)) {
                    BangumiHomeView()
                        .appRoutes()
                        // 与首页同一张轮播图（池子同源）：跨 Tab 背景连续，也不多拉图。
                        .pageAmbience(AmbienceTarget.sessionPool(app))
                }
                .pageContentSizeClass(contentSizeClass)
            }
        }

        if moviepilotEnabled {
            Tab("MoviePilot", image: "moviepilot-logo", value: AppModel.Section.moviepilot) {
                NavigationStack(path: navPathBinding(.moviepilot)) {
                    MoviePilotHomeView()
                        .appRoutes()
                        .pageAmbience(AmbienceTarget.sessionPool(app))
                }
                .pageContentSizeClass(contentSizeClass)
            }
        }

        Tab("设置", systemImage: "gearshape", value: AppModel.Section.settings) {
            NavigationStack(path: navPathBinding(.settings)) {
                SettingsView()
                    .appRoutes()
                    .pageAmbience(AmbienceTarget.sessionPool(app))
            }
            .pageContentSizeClass(contentSizeClass)
        }

        // 搜索 Tab 此前**没有**垫任何底（漏网的第 11 类页面）：iOS 上整页纯色，
        // 而底部 Tab 栏玻璃底下能透出氛围图——图就在栈根下面，页面自己没画。
        Tab("搜索", systemImage: "magnifyingglass", value: AppModel.Section.search, role: .search) {
            NavigationStack(path: navPathBinding(.search)) {
                HomeSearchView()
                    .appRoutes()
                    .pageAmbience(AmbienceTarget.sessionPool(app))
            }
            .pageContentSizeClass(contentSizeClass)
        }
    }

    /// 首页 Tab 的根页。抽出来是因为它有两个调用点（有头像 / 没头像两个 label 分支，
    /// 见 `compactTabs` 的注释）——抄两份迟早会漂移。
    @ViewBuilder
    private var homeTabRoot: some View {
        NavigationStack(path: navPathBinding(.home)) {
            HomeView()
                .appRoutes()
                .background {
                    AmbientBackdropCarousel()
                        .ignoresSafeArea()
                }
        }
        .pageContentSizeClass(contentSizeClass)
    }

    private var compactLayout: some View {
        // 切换动画只由下面的 `.motion` 驱动（value 变化自动动画，reduceMotion
        // 自动直切）——setter 里再包一层 withAnimation 是同一变化的双驱动。
        return TabView(selection: Binding(
            get: { app.selectedSection },
            set: { newSection in app.selectedSection = newSection }
        )) {
            compactTabs
        }
        // **iPad 上只有标签栏走 iPhone 形态**（用户口径：「tabview 保留 iPhone 样式的，
        // 但其他所有都保持 iPad 的」）：这一层钉成紧凑档只是为了标签栏落到底部，
        // **内容不受影响** —— 每个 Tab 的内容都由 `pageContentSizeClass(contentSizeClass)`
        // 换回设备真实宽度（见 `compactTabs`）。
        //
        // ## 为什么是「改尺寸类」而不是某个「选底部栏」的开关
        //
        // SwiftUI **没有**这种 API：`EnvironmentValues.tabBarPlacement` 是只读的
        // （只能读「栏现在在哪」）、`.tabViewStyle(.tabBarOnly)` 只管「别变成侧栏」、
        // `UITabBarController.mode` 同样只有 automatic / tabBar / tabSidebar。能用的
        // 只有尺寸类这个**副作用** —— `TabView` 那一层的尺寸类决定标签栏形态。
        //
        // ## 代价（认下来的）
        //
        // 这是**跟平台口径对着干**：iPadOS 18 起标签栏默认在顶部（Liquid Glass 顶部
        // 胶囊）。将来系统改行为，会**静默**退回顶部胶囊 —— 不会崩，但会白改，所以
        // 这条口径在 `CHANGELOG` 与本注释里都写明来历。
        //
        // 顺带解决的一件事：顶部胶囊**只渲染文字、把图标丢掉了**，所以头像在 iPad 上
        // 原本根本看不到（见 `AppModel+Avatar.swift`）；底部栏有图标，头像就出来了。
        .environment(\.horizontalSizeClass, shellSizeClass)
        // 品牌图标 / 首页头像的「选中=原色、未选中=灰」：SwiftUI 的 `Tab` 只吃一张图，
        // 两态图只能从 UIKit 侧塞进 `UITabBarItem.image` / `.selectedImage`（为什么必须
        // 这样、以及实拍验证见 `TabBarBrandIconBridge`）。挂在 background 上：它只负责
        // 找到宿主标签栏并换图，不参与布局，也不接管设置 / 搜索这些非品牌槽位。
        .background { TabBarBrandIconBridge(avatar: app.userAvatarImage) }
        // 标签栏的选中色**继承** `RootView` 根节点钉的中性 tint（`.primary`）：
        // 未选中的 glyph 依旧是系统灰；选中项的品牌图 / 头像则由上面那层换成原色
        // （它们不吃 tint）。系统自带的玻璃选中底保留（iOS 26 的悬浮玻璃标签栏）。
        // 这里不再单独钉一遍——两处钉同一个值只会制造"改了一处忘了另一处"的机会。
        //
        // 两条走过弯路的路子，别再试：
        //   * `UITabBar.appearance().tintColor = .label` —— iOS 26 的玻璃标签栏
        //     不认这套 appearance 代理，实测选中项依旧是系统蓝；
        //   * 内容侧用 `.tint(Color.accentColor)` 把强调色钉回去 —— 自我指涉，
        //     且钉的是具体色值 `Color.blue`；见文件末「强调色」一节的说明。
        .motion(Motion.slide, value: app.selectedSection)
        .onAppear { app.setCompact(true) }
    }
    #endif

    @ViewBuilder
    private var sectionContent: some View {
        Group {
            switch app.selectedSection {
            case .home:
                HomeView()
            case .settings:
                SettingsView()
            case .bangumi:
                BangumiHomeView()
            case .moviepilot:
                MoviePilotHomeView()
            case .search:
                // 仅 iOS 放大镜 Tab 使用；常规布局不会到达此分支。
                EmptyView()
            }
        }
        .transition(.section)
        .motion(Motion.standard, value: app.selectedSection)
        // 两段式转场第一段：进入点击后本页淡出，淡出完成才落地 push，新页由
        // routeExiting 复位的回弹淡入接力入场（见 AppModel.beginRouteExit）。
        .routeExitFade()
        // 栈根在 push 期间必须保持隐藏：页面是透明的（氛围层透显设计），栈根
        // 漏出来会透过详情页显示。用 **path 驱动**而不是 onAppear/onDisappear
        // 生命周期——播放器开合翻转窗口工具栏可见性会重放生命周期，播放结束
        // 后栈根会被亮回来（首页透过透明详情页漏出 + 氛围声明被清成「背景丢失」）。
        .opacity(app.path.isEmpty ? 1 : 0)
        .motion(Motion.standard, value: app.path.isEmpty)
    }

    /// 首页轮播常驻底层；详情页声明的背景只在它上面覆盖。
    @ViewBuilder
    private var windowAmbienceLayer: some View {
        ZStack(alignment: .top) {
            AmbientBackdropCarousel()

            ZStack {
                if let ambience = app.windowAmbience {
                    BackdropAmbienceView(
                        target: (url: ambience.url, authHeader: ambience.authHeader),
                        scrim: ambience.scrim
                    )
                    .drawingGroup()
                    .allowsHitTesting(false)
                    // 顶栏必须由本层盖住：页面自身的 ignoresSafeArea 用法会改变
                    // 层继承到的安全区（详情页 ScrollView 忽略顶部后，层内
                    // BackdropAmbienceView 的内部 ignoresSafeArea 不再生效，
                    // 图片被 .clipped() 裁到工具栏以下，顶栏露出窗口底色），
                    // 所以在调用点再显式退出一次安全区。
                    .ignoresSafeArea()
                    .transition(.section)
                }
            }
            // 只动画专属背景，底下的首页轮播始终留在视图树里。
            .motion(Motion.ambient, value: app.windowAmbience)

            #if os(macOS)
            // 全屏：顶栏是不透明硬底，顶部向窗口底色渐隐衔接（见
            // FullscreenTitlebarFade）；窗口态工具栏透玻璃，无需此层。
            // **必须放在氛围层的动画作用域之外**：放进去会被换页/换图的
            // 交叉淡入卷着一起动，插进/移出时在背景里滑出一条渐变带
            // （全屏下肉眼可见）。
            if isWindowFullscreen, app.windowAmbience != nil {
                FullscreenTitlebarFade()
                    .transition(.section)
            }
            #endif
        }
        #if os(macOS)
        .motion(Motion.standard, value: isWindowFullscreen)
        #endif
    }

    /// 对齐一次窗口实际全屏状态（macOS；iOS 恒 no-op）。
    private func syncFullscreenFlag() {
        #if os(macOS)
        let fullscreen = NSApp.windows.contains { $0.styleMask.contains(.fullScreen) }
        if isWindowFullscreen != fullscreen {
            isWindowFullscreen = fullscreen
        }
        #endif
    }
}

// MARK: - 强调色

// 强调色（中性）统一由 `RootView` 在**根节点**钉一次，这里不再按 Tab 各钉一遍。
//
// 历史：曾经在 `compactLayout` 给 TabView 钉 `.tint(Color.primary)` 改标签栏选中色，
// 再给每个 Tab 根页挂 `.tabContentAccent()`（钉具体色值 `Color.blue`）把强调色"钉回去"。
// 那次改动顺带把 Toggle（绿→蓝）、菜单式 Picker 取值（灰→蓝）、圆形不定 ProgressView
// （灰→蓝）、工具栏按钮（label→蓝）、`.bordered` 底（中性→蓝）一起换了色，原因是
// `.tint` 是环境值、而公开 API 无法把它还原成"未设置"（`\.tint` 是 package 保护级）。
// 根节点钉一次就没有"内容被污染再钉回来"这回事，也不再有"新增 Tab 忘了补一句"的坑。

// MARK: - 两段式换页：退场淡出

/// 读 `app.routeExiting` 给当前页画换页过渡：两段式的第一段——离场页淡出
/// （`Motion.exit`），落地后回弹淡入就是落点页的入场（新视图隐藏态出生，
/// 复位时正好有 from-state）。淡出期间顺便禁点击，防止点中已透明的按钮。
///
/// **当前只有三处挂载**：栈根 `sectionContent`、路由出口 `appRouteView`，
/// 以及呈现式页面（`appShellBackChrome(title:presented:)` 里按 `presented` 非空补挂，
/// 这类页面不在路由出口上）。
/// 分区药丸按钮**没挂**（它挂在工具栏里、退出系统共享胶囊后几何自绘，挂上淡出会
/// 在工具栏里闪一下），所以换分区时内容淡出、按钮硬切。要改就来这里加。
/// 「换页进行中忽略新请求」是 `AppModel.beginRouteExit` 的语义，不在这一层。
struct RouteExitFader: ViewModifier {
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .opacity(app.routeExiting ? 0 : 1)
            .motion(Motion.exit, value: app.routeExiting)
            .allowsHitTesting(!app.routeExiting)
    }
}

extension View {
    /// 页面与工具栏按钮共用的两段式换页淡出层。
    func routeExitFade() -> some View {
        modifier(RouteExitFader())
    }
}

// MARK: - 路由页被盖即隐

/// 路由页「被盖住即隐藏」。页面是透明的（氛围层透显设计），栈里被当前页盖住的
/// **路由页**必须自己隐掉，否则会透过当前页漏出——栈根用的是
/// `.opacity(app.path.isEmpty)`（c9f728c），路由页同理按栈深度驱动：
/// onAppear（落地即栈顶）时记下自己的深度，`app.path.count` 与之一致＝
/// 我在栈顶＝可见。
///
/// 为什么不用 onDisappear：实测 macOS 26 的导航栈 push 时**不给被盖页发
/// onDisappear**（探针证实整个进出播放流程零生命周期事件），「被覆盖即复位」
/// 的生命周期方案因此从未生效——被盖页一直 opacity 1，只是系统平时不
/// 合成它；播放器开合翻转窗口工具栏可见性、乃至改一次窗口尺寸，都会让它
/// 重新参与合成，透过透明详情页漏出（用户报「播放完返回详情页背景丢失」）。
/// 与栈根同一哲学：**path 驱动、与生命周期解耦**。
///
/// 仅 macOS 生效：紧凑布局的导航栈宿主不合成被盖页，且 `app.path` 在
/// 紧凑布局下恒空，深度无意义（iOS 直通）。
private struct CoveredPageHider: ViewModifier {
    @Environment(AppModel.self) private var app
    /// 本页在共享栈里的深度；nil＝尚未落地（落地过渡交给 routeExitFade 复位淡入）。
    @State private var depth: Int?

    func body(content: Content) -> some View {
        #if os(macOS)
        let isTop = depth == app.path.count
        content
            .onAppear { depth = app.path.count }
            .opacity(isTop ? 1 : 0)
            .motion(Motion.standard, value: isTop)
        #else
        content
        #endif
    }
}

extension View {
    /// 路由页按栈深度自动显隐（见 `CoveredPageHider`）。挂在路由出口上，
    /// 整页一份，在 `routeExitFade` 之前（退场淡出时本页仍是栈顶）。
    func coveredPageHidden() -> some View {
        modifier(CoveredPageHider())
    }
}

// MARK: - 呈现式页面宿主被盖即隐

/// 呈现式页面（`navigationDestination(isPresented:)`）**宿主**的「被盖即隐」。
/// 这类页面不在 `app.path` 上，`CoveredPageHider` 的深度比较看不见这层覆盖，
/// 宿主在呈现落地后依旧「是栈顶」；而呈现族全是透显设计（资源搜索页声明整窗
/// 氛围、下载管理页透明透显首页轮播、管理服务器 / 许可证走系统 List·Form 半透
/// 底），宿主内容会透过它们漏出——与路由页漏出同一族，同样 **绑定驱动**、与
/// 生命周期解耦（macOS 26 上生命周期回调靠不住，见 `CoveredPageHider`）。
///
/// 只动 opacity 不摘视图：宿主的氛围声明（若有）要保持活着，供被盖期间
/// 整窗层继续渲染、落地页直接取用。
private struct PresentedCoverHider: ViewModifier {
    let bindings: [Binding<Bool>]

    private var anyPresented: Bool {
        bindings.contains { $0.wrappedValue }
    }

    func body(content: Content) -> some View {
        #if os(macOS)
        content
            .opacity(anyPresented ? 0 : 1)
            .motion(Motion.standard, value: anyPresented)
        #else
        content
        #endif
    }
}

extension View {
    /// 宿主页在自己呈现的页面存续期间整页隐去（见 `PresentedCoverHider`）。
    /// 挂在宿主的 navigationDestination 注册点旁，把**自己的**呈现开关都交进来
    /// （一个宿主可以呈现多页，如设置页的服务器 / 许可证）。谁呈现谁负责交——
    /// 新增 `navigationDestination(isPresented:)` 时记得回宿主这里登记。
    func coveredByPresented(_ bindings: Binding<Bool>...) -> some View {
        modifier(PresentedCoverHider(bindings: bindings))
    }
}

// MARK: - 自绘返回键（常规布局）

/// 常规布局的返回键：系统返回键的 pop 点击即系统级滑出（不经 binding、
/// 拦不住），换自绘键走 `AppModel.back()` 两段式（淡出 → 弹栈 → 落点淡入）。
/// 正圆玻璃钮（36×36，与分区药丸同高）；系统共享底要隐藏，否则系统圆角
/// 矩形底和自绘圆叠两层。
///
/// `presented` 是呈现式页面（`navigationDestination(isPresented:)`）的落地开关：
/// 这类页面不在 `path` 上，`back()` 的弹栈守卫会把它整个吞掉（点返回毫无反应），
/// 必须改走对称的 `popPresented`。
struct AppShellBackButton: View {
    @Environment(AppModel.self) private var app
    var presented: Binding<Bool>?

    var body: some View {
        Button {
            if let presented {
                app.popPresented { presented.wrappedValue = false }
            } else {
                app.back()
            }
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: Circle())
        .help("返回")
        .accessibilityLabel("返回")
    }
}

/// push 页的返回键 + 可选顶栏标题。
/// - compact（iPhone）：系统返回键 + 标题，保持原样。
/// - iPad（常规宽度、Tab 外壳）：顶栏已有胶囊 + 返回键，标题去掉——页面头部
///   自己有名字（详情页 Logo / 库页网格），再放一个只会和胶囊挤在一起；inline
///   + removing: .title 双保险，大标题与栏内标题都不出。
/// - macOS 常规布局：系统渲染的标题文字无法参与两段式淡入淡出——`title` 非空时
///   隐藏系统标题，与返回键放**同一个工具栏项**自绘（保证 [返回键, 标题] 顺序），
///   随 routeExiting 整体淡出 / 淡入。
private struct RegularBackChrome: ViewModifier {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let title: String?
    /// 非 nil 表示本页由 `navigationDestination(isPresented:)` 呈现：返回键改走
    /// `popPresented`，并由本层补挂离场淡出（路由页的淡出在 `appRouteView`）。
    let presented: Binding<Bool>?

    func body(content: Content) -> some View {
        Group {
            if app.isCompact {
                #if os(iOS)
                if sizeClass == .regular {
                    content
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar(removing: .title)
                } else {
                    content
                }
                #else
                content
                #endif
            } else if title != nil {
                exitFaded(content)
                    .navigationBarBackButtonHidden(true)
                    .toolbar(removing: .title)
                    .toolbar { toolbarItem }
            } else {
                exitFaded(content)
                    .navigationBarBackButtonHidden(true)
                    .toolbar { toolbarItem }
            }
        }
    }

    /// 呈现式页面自己画离场淡出：它不在路由出口（`appRouteView`）上，没人替它挂
    /// 就只剩「等 0.45s 再硬关」。路由页传 nil（淡出由 `appRouteView` 那份负责，
    /// 同一层不挂两份）。
    @ViewBuilder
    private func exitFaded(_ content: Content) -> some View {
        if presented != nil {
            content.routeExitFade()
        } else {
            content
        }
    }

    private var toolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 10) {
                AppShellBackButton(presented: presented)
                if let title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }
        }
        .sharedBackgroundVisibility(.hidden)
    }
}

extension View {
    /// push 页返回键 + 可选顶栏标题（常规布局自绘，compact 原样）。
    func appShellBackChrome(title: String? = nil) -> some View {
        modifier(RegularBackChrome(title: title, presented: nil))
    }

    /// 呈现式页面（`navigationDestination(isPresented:)`）的返回键 + 标题。
    ///
    /// 与上一个重载的唯一区别是把页面自己的落地开关交进自绘返回键：这类页面
    /// 不在 `path` 上，`back()` 弹不动（常规布局下返回键点了没反应），得走
    /// `AppModel.popPresented`；顺带由本层补挂离场淡出。
    func appShellBackChrome(title: String? = nil, presented: Binding<Bool>) -> some View {
        modifier(RegularBackChrome(title: title, presented: presented))
    }
}

// MARK: - Tab 内容层的尺寸类

/// 把 Tab 内容层（Tab 根页 + 它 push 出来的所有页）的尺寸类钉成**设备真实宽度**。
///
/// 存在的唯一理由：外壳为了让标签栏落到底部，给 `TabView` 那一层钉了紧凑档
/// （见 `compactLayout`），而环境是**向下继承**的 —— 不在这里换回来，整页版式就会跟着
/// 标签栏一起降级成 iPhone 档。用户口径：「**tabview 保留 iPhone 样式的，但其他所有都
/// 保持 iPad 的**」。
///
/// 落在每个 Tab 的内容上（而不是某个具体页面）：Tab 根页、push 出来的页
/// （`appRoutes()` 的 destination 都在这棵子树里）一起生效，新增页面不用各自补。
///
/// 值由 `AppShellView.contentSizeClass` 给：iPad 上是真实常规宽度，iPhone 上是它自己的
/// compact —— 也就是「设备本来什么宽度，内容就什么版式」。
private struct PageContentSizeClass: ViewModifier {
    let sizeClass: UserInterfaceSizeClass?

    func body(content: Content) -> some View {
        content.environment(\.horizontalSizeClass, sizeClass)
    }
}

extension View {
    /// Tab 内容层的尺寸类（见 `PageContentSizeClass`）。
    func pageContentSizeClass(_ sizeClass: UserInterfaceSizeClass?) -> some View {
        modifier(PageContentSizeClass(sizeClass: sizeClass))
    }
}

// MARK: - 路由注册（各 NavigationStack 都挂这一个）

extension View {
    /// `.detail(item)` → 详情页（播放页不走路由，由 RootView 覆盖层呈现）。
    /// `.id(item.id)`：navigationDestination 会复用视图实例，不同条目必须换身份，
    /// 不然季选择器 / 集列表这些 @State 会带着上一部片的值。
    func appRoutes() -> some View {
        navigationDestination(for: AppModel.Route.self) { route in
            appRouteView(route)
        }
    }

    @ViewBuilder
    private func appRouteView(_ route: AppModel.Route) -> some View {
        Group {
            switch route {
            case .detail(let item):
                DetailView(item: item)
                    .id(item.id)
                    .appShellBackChrome(title: item.name)
            case .library(let library):
                LibraryView(library: library)
                    .appShellBackChrome(title: library.name)
            case .bangumiProfile:
                BangumiProfileView()
                    .appShellBackChrome(title: "我的")
            case .bangumiCollectionList(let type):
                BangumiCollectionListView(subjectType: type)
                    .appShellBackChrome(title: "我的\(type.description)")
            case .bangumiSubject(let subjectID, let initialSubject):
                BangumiSubjectDetailView(subjectID: subjectID, initialSubject: initialSubject)
                    .id(subjectID)
                    // 无 initialSubject 时名称要异步加载，标题交给系统渲染。
                    .appShellBackChrome(
                        title: initialSubject.map { $0.nameCN.isEmpty ? $0.name : $0.nameCN }
                    )
            case .bangumiCalendar:
                BangumiCalendarView()
                    .appShellBackChrome(title: "每日放送")
            case .settingsSubpage(let subpage):
                settingsSubpageView(subpage)
            }
        }
        // 两段式换页由本页自己淡出（routeExiting 复位的回弹淡入即入场，
        // 见 RouteExitFader）；系统 push 滑动已由 AppModel.push 禁动画掐掉。
        // 两者在 iOS 上都空转：系统自带 push / pop 滑动，routeExiting 也不会被置起。
        // coveredPageHidden：被后推的页盖住时按深度归零透明度（见 CoveredPageHider）。
        .routeAmbience(route)
        .coveredPageHidden()
        .routeExitFade()
    }

    /// 设置 hub 的子页（`SettingsSubpage`）。页面自身不设 navigationTitle——
    /// 统一在这里按子页给定，与 appShellBackChrome 的自绘标题共用一个字符串
    /// （同 LibraryView 的「navigationTitle + chrome 同名」口径）。
    @ViewBuilder
    private func settingsSubpageView(_ subpage: SettingsSubpage) -> some View {
        Group {
            switch subpage {
            case .playback: PlaybackSettingsView()
            case .homeSections: HomeSectionsSettingsView()
            case .danmaku: DanmakuSettingsView()
            case .network: NetworkSettingsView()
            case .jellyfin: JellyfinSettingsView()
            case .bangumi: BangumiSettingsView()
            case .moviepilot: MoviePilotSettingsView()
            case .tmdb: TMDbSettingsView()
            case .maintenance: MaintenanceSettingsView()
            case .about: AboutSettingsView()
            }
        }
        .navigationTitle(subpage.title)
        .appShellBackChrome(title: subpage.title)
    }
}

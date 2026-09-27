import AppDesignKit
import CoreModel
import SwiftUI

#if os(macOS)
import AppKit
#endif

/// 主框架：Mac / iPad 用顶栏液态玻璃药丸（分区），iPhone 用底部 Tab。
/// 播放器不在导航体系里 —— `RootView` 层的覆盖层负责（见 `AppModel.presentedPlayer`）。
///
/// 侧栏（`NavigationSplitView`）已撤：分区入口收进顶栏药丸，媒体库入口在首页
/// 「媒体库」栏（iPhone 是「媒体库」Tab），整列宽度让给内容。
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
            .environment(\.contentLeading, contentLeading)
            #if os(macOS)
            // 首页轮播等页面内的氛围层经它感知全屏（整窗层直接读 @State）。
            .environment(\.isWindowFullscreen, isWindowFullscreen)
            #endif
            // 背景挂在 AppShell 根节点，分区内容重建时不销毁轮播视图。
            .background { windowAmbienceLayer }
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

    /// nil 视作 regular：macOS 上 `horizontalSizeClass` 常为 nil，窗口再窄也不走紧凑版式。
    private var contentLeading: CGFloat {
        sizeClass == .compact ? Metrics.compactContentInset : Metrics.contentInset
    }

    @ViewBuilder
    private var layout: some View {
        #if os(macOS)
        splitLayout
        #else
        if sizeClass == .regular {
            splitLayout
        } else {
            compactLayout
        }
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
        // 让当前页走与 push 对称的两段式（淡出 → 再出现上一层，见
        // AppModel.beginRouteExit），返回不再是硬切。
        let path = Binding(
            get: { app.path },
            set: { newValue in
                if newValue.count < app.path.count {
                    app.beginRouteExit { app.path = newValue }
                } else {
                    app.path = newValue
                }
            }
        )
        return NavigationStack(path: path) {
            sectionContent
                .appRoutes()
                .appShellChrome()
        }
    }

    #if !os(macOS)

    /// iPhone 底部 Tab：首页 / 媒体库 / （Bangumi）/（MoviePilot）/ 设置。
    /// Bangumi、MoviePilot 两个 Tab 跟随设置里的启用开关显隐，关掉后 Tab 数
    /// 最少 3 个；每个 Tab 有独立导航栈（`navPaths`），详情页走 push 而非 sheet
    /// ——播放器覆盖层不再被遮住。
    private var compactLayout: some View {
        @Bindable var app = app
        return TabView(selection: Binding(
            get: { app.selectedSection },
            set: { newSection in
                if reduceMotion {
                    app.selectedSection = newSection
                } else {
                    withAnimation(Motion.slide) {
                        app.selectedSection = newSection
                    }
                }
            }
        )) {
            NavigationStack(path: $app.navPaths.home) {
                HomeView()
                    .appRoutes()
            }
            .tabItem { Label("首页", systemImage: "house.fill") }
            .tag(AppModel.Section.home)

            NavigationStack(path: $app.navPaths.libraries) {
                MediaLibraryListView()
                    .appRoutes()
            }
            .tabItem { Label("媒体库", systemImage: "square.stack") }
            .tag(AppModel.Section.libraries)

            if bangumiEnabled {
                NavigationStack(path: $app.navPaths.bangumi) {
                    BangumiHomeView()
                        .appRoutes()
                }
                .tabItem { Label("Bangumi", image: "bangumi-logo") }
                .tag(AppModel.Section.bangumi)
            }

            if moviepilotEnabled {
                NavigationStack(path: $app.navPaths.moviepilot) {
                    MoviePilotHomeView()
                        .appRoutes()
                }
                .tabItem { Label("MoviePilot", image: "moviepilot-logo") }
                .tag(AppModel.Section.moviepilot)
            }

            NavigationStack(path: $app.navPaths.settings) {
                SettingsView()
                    .appRoutes()
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(AppModel.Section.settings)
        }
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
            case .libraries:
                // 仅 iPhone 紧凑布局使用；常规布局不会到达此分支。
                MediaLibraryListView()
            }
        }
        .transition(.section)
        .motionAnimation(Motion.standard, value: app.selectedSection, reduceMotion: reduceMotion)
        // 两段式转场第一段：进入点击后本页淡出，淡出完成才落地 push，新页由
        // pageEntrance 接力入场（见 AppModel.beginRouteExit）。
        .routeExitFade()
        // 栈根是 pop 的落点：push 时被覆盖复位，pop 返回重放入场，不然从详情页
        // 返回首页仍是硬切。initiallyVisible 保证启动瞬间不播动画。
        .pageEntrance(initiallyVisible: true)
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
                    .transition(.opacity)
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
                    .transition(.opacity)
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

    static func icon(for type: MediaLibrary.CollectionType) -> String {
        switch type {
        case .movies: "film"
        case .tvshows: "tv"
        case .music, .musicvideos: "music.note"
        case .books: "book"
        case .photos: "photo"
        case .boxsets: "square.stack"
        case .playlists: "list.bullet"
        case .livetv: "antenna.radiowaves.left.and.right"
        case .homevideos: "video"
        case .folders, .unknown: "folder"
        }
    }
}

// MARK: - 媒体库列表页（iPhone 合并 Tab）

/// iPhone 上所有媒体库的入口列表。每个库一行，点进去是 `LibraryView`。
/// 之前每个库占一个 Tab，库多了会把 Bangumi/MoviePilot 挤进系统「更多」；
/// 合并成一个 Tab 后 Tab 总数固定 5 个。
struct MediaLibraryListView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if app.libraries.isEmpty {
                if let error = app.librariesError {
                    EmptyState(failure: error, title: "无法加载媒体库", systemImage: "wifi.exclamationmark") {
                        Task { await app.reloadBrowserData() }
                    }
                } else {
                    EmptyState(empty: "还没有媒体库", systemImage: "square.stack")
                }
            } else {
                List {
                    ForEach(app.libraries) { library in
                        Button {
                            app.openLibrary(library)
                        } label: {
                            HStack {
                                Label(library.name, systemImage: AppShellView.icon(for: library.collectionType))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("媒体库")
    }
}

// MARK: - 两段式换页：退场淡出

/// 读 `app.routeExiting` 给当前页/工具栏按钮画换页过渡：两段式的第一段——
/// 离场页淡出（`Motion.exit`），落地后回弹淡入就是落点页/新按钮的入场
/// （新视图隐藏态出生，复位时正好有 from-state）。页面与工具栏按钮都挂它；
/// 淡出期间顺便禁点击，防止点中已透明的按钮。
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

// MARK: - 自绘返回键（常规布局）

/// 常规布局的返回键：系统返回键的 pop 点击即系统级滑出（不经 binding、
/// 拦不住），换自绘键走 `AppModel.back()` 两段式（淡出 → 弹栈 → 落点淡入）。
/// 正圆玻璃钮（36×36，与分区药丸同高）；系统共享底要隐藏，否则系统圆角
/// 矩形底和自绘圆叠两层。
struct AppShellBackButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Button {
            app.back()
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

/// push 页的返回键 + 可选顶栏标题。compact（iPhone）保留系统返回键与标题。
/// 常规布局：系统渲染的标题文字无法参与两段式淡入淡出——`title` 非空时
/// 隐藏系统标题，与返回键放**同一个工具栏项**自绘（保证 [返回键, 标题] 顺序），
/// 随 routeExiting 整体淡出 / 淡入。
private struct RegularBackChrome: ViewModifier {
    @Environment(AppModel.self) private var app
    let title: String?

    func body(content: Content) -> some View {
        Group {
            if app.isCompact {
                content
            } else if title != nil {
                content
                    .navigationBarBackButtonHidden(true)
                    .toolbar(removing: .title)
                    .toolbar { toolbarItem }
            } else {
                content
                    .navigationBarBackButtonHidden(true)
                    .toolbar { toolbarItem }
            }
        }
    }

    private var toolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 10) {
                AppShellBackButton()
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
        modifier(RegularBackChrome(title: title))
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
            }
        }
        // macOS 系统 push 被吞（见 pageEntrance 注释），所有路由页统一自带入场；
        // 两段式换页时由本页自己淡出（routeExitFade）。
        .routeExitFade()
        .pageEntrance()
    }
}

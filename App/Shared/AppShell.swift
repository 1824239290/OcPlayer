import AppDesignKit
import CoreModel
import SwiftUI

#if os(macOS)
import AppKit
#endif

/// 主框架：Mac / iPad 用顶栏液态玻璃药丸（分区）+「媒体库」按钮，iPhone 用底部 Tab。
/// 播放器不在导航体系里 —— `RootView` 层的覆盖层负责（见 `AppModel.presentedPlayer`）。
///
/// 侧栏（`NavigationSplitView`）已撤：分区入口收进顶栏药丸，媒体库改由单独的
/// 「媒体库」按钮弹出选择（见 `AppShellChrome.swift`），整列宽度让给内容。
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
            // 顶栏导航条挂在**窗口工具栏**上，不挂在某个导航栈的根内容上：工具栏
            // 属于窗口，push 进详情页后这组按钮与媒体库按钮照样在（换页不必先返回）。
            // iPad 的导航栏由栈自己提供，见 `stack(content:)` 里的 `appShellChrome()`。
            .toolbar {
                AppShellNavigationToolbarContent()
            }
            #endif
        // 整窗氛围底（页面经 windowAmbience(_:) 声明）：垫在导航栈**后面**。
        // macOS 26 上只有栈根的背景能铺满全窗（首页轮播就是这么垫到工具栏玻璃
        // 底下的），pushed 页被裁在栈内、导航栈宿主自带不透明底，页面自己在栈内
        // 垫什么都连不到工具栏——垫在这里，透明的 pushed 页和工具栏玻璃透出的
        // 才是同一张连续的图。
        // 必须走 layout 隔离的 `.background`：氛围图的 fill 溢出若作为 ZStack
        // 兄弟参与布局，会把导航栈撑出窗口（4e7287e 同款坑）。
        .background { windowAmbienceLayer }
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

    /// 常规布局的导航栈：Mac / iPad 共用一个 `app.path`（切换分区清栈，见
    /// `AppModel.selectedSection`）。顶栏导航条由 `appShellChrome()` 挂载——
    /// iOS 挂在根内容上（导航栏由栈提供），macOS 是空操作（挂窗口工具栏）。
    private func stack<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        @Bindable var app = app
        return NavigationStack(path: $app.path) {
            content()
                .appRoutes()
                .appShellChrome()
        }
        .transition(.section)
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
            set: { app.selectedSection = $0 }
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
                .tabItem { Label("Bangumi", systemImage: "tv.fill") }
                .tag(AppModel.Section.bangumi)
            }

            if moviepilotEnabled {
                NavigationStack(path: $app.navPaths.moviepilot) {
                    MoviePilotHomeView()
                        .appRoutes()
                }
                .tabItem { Label("MoviePilot", systemImage: "film.stack") }
                .tag(AppModel.Section.moviepilot)
            }

            NavigationStack(path: $app.navPaths.settings) {
                SettingsView()
                    .appRoutes()
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(AppModel.Section.settings)
        }
        .onAppear { app.setCompact(true) }
    }
    #endif

    private var detailColumn: some View {
        Group {
            switch app.selectedSection {
            case .home:
                stack { HomeView() }
            case .library(let id):
                if let library = app.libraries.first(where: { $0.id == id }) {
                    stack { LibraryView(library: library) }
                } else {
                    EmptyState(empty: "媒体库不存在", systemImage: "tray")
                        .transition(.section)
                }
            case .settings:
                stack { SettingsView() }
            case .bangumi:
                stack { BangumiHomeView() }
            case .moviepilot:
                stack { MoviePilotHomeView() }
            case .libraries:
                // 仅 iPhone 紧凑布局使用；常规布局走 `.library(id)`，不会到达此分支。
                stack { MediaLibraryListView() }
            }
        }
        .motionAnimation(Motion.standard, value: app.selectedSection, reduceMotion: reduceMotion)
    }

    /// 当前声明页的整窗氛围层；无声明时整体不渲染，各页自己兜底纯色。
    @ViewBuilder
    private var windowAmbienceLayer: some View {
        ZStack(alignment: .top) {
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
                    .id(ambience)
                    .transition(.opacity)
                }
            }
            // 换页换图走氛围档慢淡变；减弱动态效果时 .motion 自动降级直切。
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
                        NavigationLink(value: AppModel.Route.library(library)) {
                            Label(library.name, systemImage: AppShellView.icon(for: library.collectionType))
                        }
                    }
                }
            }
        }
        .navigationTitle("媒体库")
    }
}

// MARK: - 路由注册（各 NavigationStack 都挂这一个）

extension View {
    /// `.detail(item)` → 详情页（播放页不走路由，由 RootView 覆盖层呈现）。
    /// `.id(item.id)`：navigationDestination 会复用视图实例，不同条目必须换身份，
    /// 不然季选择器 / 集列表这些 @State 会带着上一部片的值。
    func appRoutes() -> some View {
        navigationDestination(for: AppModel.Route.self) { route in
            switch route {
            case .detail(let item):
                DetailView(item: item)
                    .id(item.id)
            case .library(let library):
                LibraryView(library: library)
            case .bangumiProfile:
                BangumiProfileView()
            case .bangumiCollectionList(let type):
                BangumiCollectionListView(subjectType: type)
            case .bangumiSubject(let subjectID, let initialSubject):
                BangumiSubjectDetailView(subjectID: subjectID, initialSubject: initialSubject)
                    .id(subjectID)
            case .bangumiCalendar:
                BangumiCalendarView()
            }
        }
    }
}

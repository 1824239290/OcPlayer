import CoreModel
import SwiftUI

/// 主框架：Mac / iPad 用玻璃侧栏（NavigationSplitView），iPhone 用底部 Tab。
/// 播放器不在导航体系里 —— `RootView` 层的覆盖层负责（见 `AppModel.presentedPlayer`）。
struct AppShellView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        layout
            // 横向留白跟**窗口宽度**走，不跟设备型号走：iPad 拖到 1/3 宽时
            // hSizeClass 已经是 compact，而 UIDevice 的 idiom 仍是 .pad
            // （见 `EnvironmentValues.contentLeading` 的注释）。
            .environment(\.contentLeading, contentLeading)
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

    // MARK: - Mac / iPad：侧栏

    private var splitLayout: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 212, max: 260)
        } detail: {
            detailColumn
        }
        // 整窗氛围底（页面经 windowAmbience(_:) 声明）：垫在整块 split view
        // **后面**。macOS 26 上只有栈根的背景能铺满全窗（首页轮播就是这么垫到
        // 侧栏玻璃底下的），pushed 页被裁在详情列里、导航栈宿主自带不透明底，
        // 页面自己在列内垫什么都连不到侧栏——垫在这里，透明的 pushed 页和
        // 侧栏玻璃透出的才是同一张连续的图。
        // 必须走 layout 隔离的 `.background`：氛围图的 fill 溢出若作为 ZStack
        // 兄弟参与布局，会把 split view 撑出窗口（4e7287e 同款坑）。
        .background { windowAmbienceLayer }
        .onAppear { app.setCompact(false) }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { app.selectedSection },
            set: { app.selectedSection = $0 ?? .home }
        )) {
            Section {
                Label("首页", systemImage: "house.fill").tag(AppModel.Section.home)
                Label("MoviePilot", systemImage: "film.stack")
                    .tag(AppModel.Section.moviepilot)
                Label("Bangumi", systemImage: "tv.fill")
                    .tag(AppModel.Section.bangumi)
            }

            Section("媒体库") {
                if app.libraries.isEmpty, let librariesError = app.librariesError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(librariesError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(UIStrings.retry) {
                            Task { await app.reloadBrowserData() }
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(app.libraries) { library in
                        Label(library.name, systemImage: Self.icon(for: library.collectionType))
                            .tag(AppModel.Section.library(library.id))
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            settingsFooter
        }
        .listStyle(.sidebar)
    }

    #if !os(macOS)

    /// iPhone 底部 Tab：首页 / 媒体库 / Bangumi / MoviePilot / 设置（固定 5 个，不触发「更多」）。
    /// 每个 Tab 有独立导航栈（`navPaths`），详情页走 push 而非 sheet——播放器覆盖层不再被遮住。
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

            NavigationStack(path: $app.navPaths.bangumi) {
                BangumiHomeView()
                    .appRoutes()
            }
            .tabItem { Label("Bangumi", systemImage: "tv.fill") }
            .tag(AppModel.Section.bangumi)

            NavigationStack(path: $app.navPaths.moviepilot) {
                MoviePilotHomeView()
                    .appRoutes()
            }
            .tabItem { Label("MoviePilot", systemImage: "film.stack") }
            .tag(AppModel.Section.moviepilot)

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
        @Bindable var app = app
        return Group {
            switch app.selectedSection {
            case .home:
                NavigationStack(path: $app.path) {
                    HomeView()
                        .appRoutes()
                }
                .transition(.section)
            case .library(let id):
                if let library = app.libraries.first(where: { $0.id == id }) {
                    NavigationStack(path: $app.path) {
                        LibraryView(library: library)
                            .appRoutes()
                    }
                    .transition(.section)
                } else {
                    ContentUnavailableView("媒体库不存在", systemImage: "tray")
                        .transition(.section)
                }
            case .settings:
                NavigationStack(path: $app.path) {
                    SettingsView()
                        .appRoutes()
                }
                .transition(.section)
            case .bangumi:
                NavigationStack(path: $app.path) {
                    BangumiHomeView()
                        .appRoutes()
                }
                .transition(.section)
            case .moviepilot:
                NavigationStack(path: $app.path) {
                    MoviePilotHomeView()
                        .appRoutes()
                }
                .transition(.section)
            case .libraries:
                // 仅 iPhone 紧凑布局使用；常规布局走 `.library(id)`，不会到达此分支。
                NavigationStack(path: $app.path) {
                    MediaLibraryListView()
                        .appRoutes()
                }
                .transition(.section)
            }
        }
        .motionAnimation(Motion.standard, value: app.selectedSection, reduceMotion: reduceMotion)
    }

    /// 当前声明页的整窗氛围层；无声明时整体不渲染，各页自己兜底纯色。
    @ViewBuilder
    private var windowAmbienceLayer: some View {
        ZStack {
            if let ambience = app.windowAmbience {
                BackdropAmbienceView(
                    target: (url: ambience.url, authHeader: ambience.authHeader),
                    scrim: ambience.scrim
                )
                .drawingGroup()
                .allowsHitTesting(false)
                .id(ambience)
                .transition(.opacity)
            }
        }
        // 换页换图走氛围档慢淡变；减弱动态效果时 .motion 自动降级直切。
        .motion(Motion.ambient, value: app.windowAmbience)
    }

    private var settingsFooter: some View {
        Button {
            app.selectedSection = .settings
        } label: {
            Label("设置", systemImage: "gearshape")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    app.selectedSection == .settings
                        ? AnyShapeStyle(.tint.opacity(0.18))
                        : AnyShapeStyle(.clear),
                    in: .rect(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(app.selectedSection == .settings ? .isSelected : [])
        .padding(8)
        .background(.ultraThinMaterial)
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
                    ContentUnavailableView {
                        Label("无法加载媒体库", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button(UIStrings.retry) { Task { await app.reloadBrowserData() } }
                    }
                } else {
                    ContentUnavailableView("还没有媒体库", systemImage: "square.stack")
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

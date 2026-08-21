import CoreModel
import SwiftUI

/// 主框架：Mac / iPad 用玻璃侧栏（NavigationSplitView），iPhone 用底部 Tab。
/// 播放器不在导航体系里 —— `RootView` 层的覆盖层负责（见 `AppModel.presentedPlayer`）。
struct AppShellView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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
        .onAppear { app.setCompact(false) }
    }

    private var sidebar: some View {
        List(selection: Binding(
            get: { app.selectedSection },
            set: { app.selectedSection = $0 ?? .home }
        )) {
            Section {
                Label("首页", systemImage: "house.fill").tag(AppModel.Section.home)
            }

            Section("Bangumi") {
                Label("进度管理", systemImage: "arrow.triangle.branch")
                    .tag(AppModel.Section.bangumi)
            }

            Section("媒体库") {
                if app.libraries.isEmpty, let librariesError = app.librariesError {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(librariesError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("重试") {
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

    /// iPhone 底部 Tab：首页 / 电影 / 剧集 / 设置（音乐等 M4 再进）。
    /// 详情在小屏走 sheet（多 Tab 多 NavigationStack 共享 path 会互相踩）。
    private var compactLayout: some View {
        TabView(selection: Binding(
            get: { app.selectedSection },
            set: { app.selectedSection = $0 }
        )) {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(AppModel.Section.home)
            ForEach(iphoneLibraries) { library in
                LibraryView(library: library)
                    .tabItem { Label(library.name, systemImage: Self.icon(for: library.collectionType)) }
                    .tag(AppModel.Section.library(library.id))
            }
            BangumiHomeView()
                .tabItem { Label("Bangumi", systemImage: "arrow.triangle.branch") }
                .tag(AppModel.Section.bangumi)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(AppModel.Section.settings)
        }
        .sheet(item: Binding(
            get: { app.presentedDetail },
            set: { app.presentedDetail = $0 }
        )) { item in
            NavigationStack {
                DetailView(item: item)
                    .id(item.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("完成") { app.presentedDetail = nil }
                        }
                    }
            }
        }
        .onAppear { app.setCompact(true) }
    }

    /// iPhone 上只挑电影 / 剧集两个一级库，避免 Tab 爆炸；其余 M4 收进「更多」。
    private var iphoneLibraries: [MediaLibrary] {
        app.libraries.filter { $0.collectionType == .movies || $0.collectionType == .tvshows }
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
                .transition(.opacity)
            case .library(let id):
                if let library = app.libraries.first(where: { $0.id == id }) {
                    NavigationStack(path: $app.path) {
                        LibraryView(library: library)
                            .appRoutes()
                    }
                    .transition(.opacity)
                } else {
                    ContentUnavailableView("媒体库不存在", systemImage: "tray")
                        .transition(.opacity)
                }
            case .settings:
                NavigationStack(path: $app.path) {
                    SettingsView()
                        .appRoutes()
                }
                .transition(.opacity)
            case .bangumi:
                NavigationStack(path: $app.path) {
                    BangumiHomeView()
                        .appRoutes()
                }
                .transition(.opacity)
            }
        }
        .motionAnimation(.easeInOut(duration: 0.2), value: app.selectedSection, reduceMotion: reduceMotion)
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
                        ? Color.accentColor.opacity(0.18)
                        : .clear,
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
            case .bangumiProfile:
                BangumiProfileView()
            case .bangumiCollectionList(let type):
                BangumiCollectionListView(subjectType: type)
            }
        }
    }
}

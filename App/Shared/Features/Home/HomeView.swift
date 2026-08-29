import CoreModel
import SwiftUI

/// 首页：继续观看 + 接下来看 + 最近添加。
struct HomeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCompact: Bool { sizeClass == .compact }
    private var stillWidth: CGFloat { isCompact ? Metrics.compactStillWidth : Metrics.stillWidth }
    private var posterWidth: CGFloat? { isCompact ? Metrics.compactPosterWidth : nil }

    var body: some View {
        Group {
            if app.server == nil {
                noServerState
            } else if app.home.isLoading && app.home.latest.isEmpty {
                loadingState
            } else if let error = app.home.error, app.home.latest.isEmpty {
                errorState(error)
            } else {
                content
            }
        }
        .navigationTitle("首页")
        #if os(macOS)
        .navigationSubtitle(app.server == nil ? "未连接" : app.serverLabel)
        #endif
    }

    private var noServerState: some View {
        ContentUnavailableView {
            Label("还没连接服务器", systemImage: "antenna.radiowaves.left.and.right.slash")
        } description: {
            Text("连上媒体库后，这里会有继续观看和最近添加。本地文件播放不受影响。")
        } actions: {
            Button("去连接") { app.reconnectFlow() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var content: some View {
        // 不再包一层 GeometryReader：它会在每次侧栏拖动/窗口变化时强迫整页重测，
        // 滚轮滚动时也更容易和嵌套横向 Rail 抢布局，手感发沉。
        // 宽度由 Rail 内 `.frame(maxWidth: .infinity)` + 卡片固定宽约束。
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !app.home.resume.isEmpty {
                    Rail("继续观看", kind: .still, items: app.home.resume) { item in
                        StillCard(
                            item: item,
                            server: app.server,
                            actionIcon: "chevron.right",
                            actionAccessibilityLabel: "打开 \(item.seriesName ?? item.name) 详情",
                            width: stillWidth
                        ) {
                            app.openSeriesDetail(for: item)
                        }
                    }
                    .transition(.opacity)
                }

                if !app.home.nextUp.isEmpty {
                    Rail("接下来看", kind: .still, items: app.home.nextUp) { item in
                        StillCard(
                            item: item,
                            server: app.server,
                            actionIcon: "chevron.right",
                            actionAccessibilityLabel: "打开 \(item.seriesName ?? item.name) 详情",
                            width: stillWidth
                        ) {
                            app.openSeriesDetail(for: item)
                        }
                    }
                    .transition(.opacity)
                }

                if !app.home.latest.isEmpty {
                    Rail("最近添加", kind: .poster, items: app.home.latest) { item in
                        PosterCard(item: item, server: app.server, width: posterWidth) {
                            app.openDetail(item)
                        }
                    }
                    .transition(.opacity)
                }

                if app.home.resume.isEmpty && app.home.nextUp.isEmpty && app.home.latest.isEmpty {
                    ContentUnavailableView {
                        Label("媒体库暂无可展示内容", systemImage: "sparkles")
                    } description: {
                        Text("媒体库可能正在建立索引或没有未看项目。可在侧栏或下方切换媒体库浏览。")
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                    .padding(.top, 40)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .refreshable { await app.reloadBrowserData() }
        // 下拉刷新会先清空再填充三条 Rail 的数组，count 变化触发整体 crossfade。
        .motionAnimation(.easeInOut(duration: 0.25), value: app.home.resume.count, reduceMotion: reduceMotion)
        .motionAnimation(.easeInOut(duration: 0.25), value: app.home.nextUp.count, reduceMotion: reduceMotion)
        .motionAnimation(.easeInOut(duration: 0.25), value: app.home.latest.count, reduceMotion: reduceMotion)
    }

    private var loadingState: some View {
        // 骨架屏：铺和真实布局同尺寸的 Rail（继续观看 / 接下来看 = 剧照卡，
        // 最近添加 = 海报卡），数据加载完原位替换。
        //
        // 铺几条按上一次成功加载的结论走（`home.railPresence`，跨启动保留）——
        // 写死三条的话，没有「继续观看」的服务器上骨架撤掉时会塌掉几百 pt。
        let presence = app.home.railPresence
        // 上一次三条全空（空库 / 全新服务器）：还是铺一条，全空的加载页看着像卡死。
        let showsLatest = presence.latest || presence.railCount == 0
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if presence.resume {
                    SkeletonRail(title: "继续观看", kind: .still)
                }
                if presence.nextUp {
                    SkeletonRail(title: "接下来看", kind: .still)
                }
                if showsLatest {
                    SkeletonRail(title: "最近添加", kind: .poster)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
        }
        .scrollDisabled(true)
        .skeletonShimmer()
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("首页加载失败", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button(UIStrings.retry) { Task { await app.reloadBrowserData() } }
        }
    }
}

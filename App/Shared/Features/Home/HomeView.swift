import CoreModel
import SwiftUI

/// 首页：继续观看 + 接下来看 + 最近添加。
struct HomeView: View {
    @Environment(AppModel.self) private var app

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
            Label("还没连接 Jellyfin", systemImage: "antenna.radiowaves.left.and.right.slash")
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
                    Rail("继续观看", kind: .still) {
                        ForEach(app.home.resume) { item in
                            StillCard(
                                item: item,
                                server: app.server,
                                actionIcon: "chevron.right",
                                actionAccessibilityLabel: "打开 \(item.seriesName ?? item.name) 电视剧详情"
                            ) {
                                app.openSeriesDetail(for: item)
                            }
                        }
                    }
                }

                if !app.home.nextUp.isEmpty {
                    Rail("接下来看", kind: .still) {
                        ForEach(app.home.nextUp) { item in
                            StillCard(
                                item: item,
                                server: app.server,
                                actionIcon: "chevron.right",
                                actionAccessibilityLabel: "打开 \(item.seriesName ?? item.name) 电视剧详情"
                            ) {
                                app.openSeriesDetail(for: item)
                            }
                        }
                    }
                }

                if !app.home.latest.isEmpty {
                    Rail("最近添加", kind: .poster) {
                        ForEach(app.home.latest) { item in
                            PosterCard(item: item, server: app.server) {
                                app.openDetail(item)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .refreshable { await app.reloadBrowserData() }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("正在连接 \(app.serverLabel)…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("首页加载失败", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
        } actions: {
            Button("重试") { Task { await app.reloadBrowserData() } }
        }
    }
}

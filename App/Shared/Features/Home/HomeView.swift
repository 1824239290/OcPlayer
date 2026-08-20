import CoreModel
import SwiftUI

/// 首页：英雄区（最近添加里挑有背景图的）+ 继续观看 + 接下来看 + 最近添加。
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
        GeometryReader { viewport in
            let contentWidth = max(viewport.size.width, 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !app.home.resume.isEmpty {
                        Rail("继续观看") {
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
                        Rail("接下来看") {
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
                        Rail("最近添加") {
                            ForEach(app.home.latest) { item in
                                PosterCard(item: item, server: app.server) {
                                    app.openDetail(item)
                                }
                            }
                        }
                    }
                }
                // Vertical ScrollView 对内容的横向提议可能是 nil；仅使用
                // `maxWidth: .infinity` 仍会让横向 Rail 的理想宽度泄漏到详情列外。
                // 用外层 GeometryReader 的真实视口宽度硬约束内容列，侧栏开合时
                // HeroCarousel 只能测到当前详情列的可视宽度。
                .frame(width: contentWidth, alignment: .leading)
                .padding(.bottom, 12)
            }
            .contentMargins(.horizontal, 0, for: .scrollContent)
            .refreshable { await app.reloadBrowserData() }
        }
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


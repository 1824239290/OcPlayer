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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !app.home.heroes.isEmpty {
                    HeroCarousel(
                        items: app.home.heroes,
                        eyebrowPrefix: app.home.heroLabel
                    ) { item in
                        app.play(item, resumeSeconds: item.playState?.positionSeconds)
                    } onDetail: { item in
                        app.openDetail(item)
                    }
                }

                if !app.home.resume.isEmpty {
                    Rail("继续观看") {
                        ForEach(app.home.resume) { item in
                            StillCard(item: item, server: app.server) {
                                app.play(item, resumeSeconds: item.playState?.positionSeconds)
                            }
                        }
                    }
                }

                if !app.home.nextUp.isEmpty {
                    Rail("接下来看") {
                        ForEach(app.home.nextUp) { item in
                            StillCard(item: item, server: app.server) {
                                app.play(item, resumeSeconds: nil)
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

                footer
            }
            .padding(.bottom, 48)
        }
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

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("\(app.serverLabel) · 直连直解")
            Text("继续观看的进度由服务器记录，换设备也能接着看")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, Metrics.contentLeading)
        .padding(.top, 28)
    }
}

// MARK: - 英雄区轮播（设计稿：全幅背景 + 底部渐隐 + 大标题 + 播放/详情）

/// 英雄区轮播容器：多张卡片 + 自动轮播 + 底部圆点。
/// 只有一张时退化为静态横幅（不轮播、不显示圆点）。
private struct HeroCarousel: View {
    let items: [MediaItem]
    var eyebrowPrefix: String
    var onPlay: (MediaItem) -> Void
    var onDetail: (MediaItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// 当前轮播页（对应 HeroBanner 的 `.id(i)`）；手动滑动和程序跳转都会更新它。
    @State private var scrollID: Int? = 0
    /// 鼠标悬停时暂停自动轮播。
    @State private var isHovering = false

    private var count: Int { items.count }
    private var currentIndex: Int { scrollID ?? 0 }
    private var interval: Duration { .seconds(6) }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { i in
                    HeroBanner(item: items[i], eyebrowPrefix: eyebrowPrefix) {
                        onPlay(items[i])
                    } onDetail: {
                        onDetail(items[i])
                    }
                    .containerRelativeFrame(.horizontal)
                    .id(i)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollID)
        .scrollIndicators(.hidden)
        .overlay(alignment: .bottom) {
            if count > 1 { dots }
        }
        // macOS 的横向 ScrollView 有时无视 .scrollIndicators(.hidden)，
        // 裁掉底部一条把滚动条截在视野外（圆点在 26pt 之上，不受影响）。
        .mask { Rectangle().padding(.bottom, 18) }
        .clipped()
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .task(id: advanceID) {
            guard count > 1, !reduceMotion, scenePhase == .active else { return }
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                scrollID = (currentIndex + 1) % count
            }
        }
    }

    /// 计时器重跑标识：悬停 / 窗口失焦 / 轮播内容变化时重建，避免在暂停期间累积跳转。
    private var advanceID: Int {
        var hasher = Hasher()
        hasher.combine(isHovering)
        hasher.combine(scenePhase)
        hasher.combine(count)
        hasher.combine(currentIndex)
        return hasher.finalize()
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i == currentIndex ? .white : .white.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .scaleEffect(i == currentIndex ? 1.15 : 1)
                    .animation(.spring(duration: 0.25), value: currentIndex)
                    .onTapGesture { select(i) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.38), in: Capsule())
        .padding(.bottom, 26)
    }

    private func select(_ i: Int) {
        guard i != currentIndex else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
            scrollID = i
        }
    }
}

/// 单张英雄横幅。
private struct HeroBanner: View {
    let item: MediaItem
    var eyebrowPrefix: String
    var onPlay: () -> Void
    var onDetail: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            let target = item.imageTarget(app.server, kind: .backdrop, width: 1600)
            Group {
                if let url = target.url {
                    RemoteImage(url: url, authHeader: target.authHeader)
                } else {
                    Rectangle().fill(.quinary)
                }
            }
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)

            LinearGradient(
                colors: [.black.opacity(0.92), .black.opacity(0.55), .clear],
                startPoint: .bottom, endPoint: .center
            )
            .frame(height: heroHeight)

            VStack(alignment: .leading, spacing: 12) {
                Text("\(eyebrowPrefix) · \(item.year.map(String.init) ?? "剧集")")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text(item.name)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                HStack(spacing: 9) {
                    ForEach(metaParts, id: \.self) { part in
                        if part != metaParts.first {
                            Text("·").foregroundStyle(.white.opacity(0.4))
                        }
                        Text(part).foregroundStyle(.white.opacity(0.8))
                    }
                    if let rating = item.officialRating {
                        Text(rating)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .font(.subheadline)

                HStack(spacing: 12) {
                    Button {
                        withAnimation(reduceMotion ? nil : .spring(duration: 0.2)) { onPlay() }
                    } label: {
                        Label("播放", systemImage: "play.fill")
                            .padding(.horizontal, 28).padding(.vertical, 13)
                            .background(.white, in: Capsule())
                            .foregroundStyle(.black)
                            .font(.body.weight(.semibold))
                    }
                    .buttonStyle(.plain)

                    Button {
                        withAnimation(reduceMotion ? nil : .spring(duration: 0.2)) { onDetail() }
                    } label: {
                        Image(systemName: "info")
                            .font(.body)
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.16), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.28)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Metrics.contentLeading)
            .padding(.bottom, 36)
        }
    }

    private var heroHeight: CGFloat {
        #if os(macOS)
        500
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? 480 : 400
        #endif
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if !item.genres.isEmpty { parts.append(item.genres.prefix(2).joined(separator: " / ")) }
        if let runtime = item.runtimeSeconds { parts.append(RuntimeText.format(runtime)) }
        if parts.isEmpty { parts.append("Jellyfin") }
        return parts
    }
}

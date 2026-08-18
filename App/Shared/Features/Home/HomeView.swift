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
                    if !app.home.heroes.isEmpty {
                        HeroCarousel(
                            items: app.home.heroes,
                            eyebrowPrefix: app.home.heroLabel,
                            width: contentWidth
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
                // Vertical ScrollView 对内容的横向提议可能是 nil；仅使用
                // `maxWidth: .infinity` 仍会让横向 Rail 的理想宽度泄漏到详情列外。
                // 用外层 GeometryReader 的真实视口宽度硬约束内容列，侧栏开合时
                // HeroCarousel 只能测到当前详情列的可视宽度。
                .frame(width: contentWidth, alignment: .leading)
                .padding(.bottom, 48)
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
    let width: CGFloat
    var onPlay: (MediaItem) -> Void
    var onDetail: (MediaItem) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    /// 当前轮播页。使用媒体 ID 而不是数组下标，刷新数据后仍能保持稳定身份。
    @State private var scrollID: MediaItem.ID?
    /// AppKit 可能恢复横向 ScrollView 的旧像素偏移；首次布局后强制回到第一张。
    @State private var hasAnchoredInitialPage = false
    /// 鼠标悬停时暂停自动轮播。
    @State private var isHovering = false

    private var count: Int { items.count }
    private var currentIndex: Int {
        guard let scrollID,
              let index = items.firstIndex(where: { $0.id == scrollID })
        else { return 0 }
        return index
    }
    private var interval: Duration { .seconds(6) }

    init(
        items: [MediaItem],
        eyebrowPrefix: String,
        width: CGFloat,
        onPlay: @escaping (MediaItem) -> Void,
        onDetail: @escaping (MediaItem) -> Void
    ) {
        self.items = items
        self.eyebrowPrefix = eyebrowPrefix
        self.width = width
        self.onPlay = onPlay
        self.onDetail = onDetail
        _scrollID = State(initialValue: items.first?.id)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        HeroBanner(
                            item: item,
                            eyebrowPrefix: eyebrowPrefix,
                            width: width,
                            height: heroHeight
                        ) {
                            onPlay(item)
                        } onDetail: {
                            onDetail(item)
                        }
                        // 外层详情列是唯一宽度来源，避免启动时内外 GeometryReader
                        // 在 NavigationSplitView 恢复侧栏的不同布局轮次里读到两套宽度。
                        .id(item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            // 冷启动时绑定必须在第一次布局前已有值，并明确按页首对齐；否则
            // macOS 会采用“最小滚动距离”，把第一页停在两个页面之间。
            .scrollPosition(id: $scrollID, anchor: .leading)
            .scrollIndicators(.hidden)
            // live resize 会先更新视口再更新 target frame。等待宽度稳定后再无动画
            // 重锚当前媒体；同步 scrollTo 会用新视口对齐旧 frame，留下错误偏移。
            .task(id: layoutID) {
                let isInitialAnchor = !hasAnchoredInitialPage
                let targetID = isInitialAnchor ? items.first?.id : scrollID
                do {
                    try await Task.sleep(for: .milliseconds(80))
                } catch {
                    return
                }
                guard let targetID,
                      (isInitialAnchor || scrollID == targetID),
                      items.contains(where: { $0.id == targetID })
                else { return }

                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if isInitialAnchor {
                        hasAnchoredInitialPage = true
                        scrollID = targetID
                    }
                    proxy.scrollTo(targetID, anchor: .leading)
                }
            }
        }
        .frame(width: width, height: heroHeight)
        .overlay(alignment: .bottom) {
            if count > 1 { dots }
        }
        // macOS 的横向 ScrollView 有时无视 .scrollIndicators(.hidden)，
        // 裁掉底部一条把滚动条截在视野外（圆点在 26pt 之上，不受影响）。
        .mask { Rectangle().padding(.bottom, 18) }
        .clipped()
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onAppear { normalizeScrollID() }
        .onChange(of: items.map(\.id)) {
            normalizeScrollID()
        }
        .task(id: advanceID) {
            guard count > 1, !reduceMotion, scenePhase == .active else { return }
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                scrollID = items[(currentIndex + 1) % count].id
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

    /// 只跟页面几何和内容集合走，不包含当前页，避免自动轮播时重启校正任务。
    private var layoutID: Int {
        var hasher = Hasher()
        hasher.combine(Int(width.rounded()))
        for item in items { hasher.combine(item.id) }
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
            scrollID = items[i].id
        }
    }

    private func normalizeScrollID() {
        guard !items.isEmpty else {
            scrollID = nil
            return
        }
        if let scrollID, items.contains(where: { $0.id == scrollID }) { return }
        scrollID = items[0].id
    }

    private var heroHeight: CGFloat {
        #if os(macOS)
        500
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? 480 : 400
        #endif
    }
}

/// 单张英雄横幅。
private struct HeroBanner: View {
    let item: MediaItem
    var eyebrowPrefix: String
    let width: CGFloat
    let height: CGFloat
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
            .frame(width: width, height: height)

            LinearGradient(
                colors: [.black.opacity(0.92), .black.opacity(0.55), .clear],
                startPoint: .bottom, endPoint: .center
            )
            .frame(width: width, height: height)

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
            // 长标题的理想宽度可能大于窄窗口。先加边距，再由外层 frame 收住
            // 整个信息层；如果把 frame 放在 padding 前，padding 会把它重新撑宽
            // 104pt，ZStack 居中后就会左右各裁掉约 52pt。
            .padding(.horizontal, Metrics.contentLeading)
            .padding(.bottom, 36)
            .frame(width: width, alignment: .leading)
        }
        .frame(width: width, height: height, alignment: .bottomLeading)
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

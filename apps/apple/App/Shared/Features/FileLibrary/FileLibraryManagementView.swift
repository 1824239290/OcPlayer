import AppDesignKit
import OcPlayerCore
import SwiftUI
import UniformTypeIdentifiers

/// 文件媒体库管理面板：分类添加、目录扫描、TMDB 刮削任务与权限维护。
///
/// 主浏览体验（首页 / 媒体库 / 详情 / 搜索 / 观影 / 设置）已统一接入 `AppShellView`；
/// 本面板仅负责文件来源特有的运维操作，可由首页提示条、工具栏菜单或设置页打开。
/// 视觉上沿用 `AppSheet` 系列（固定顶栏 + 滚动卡片 + 底部操作），每个分类一张卡片，
/// 把文件夹、扫描与刮削状态收拢在同一处，不再按任务类型重复罗列分类。
struct FileLibraryManagementView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let sourceID: String

    @State private var libraries: [OcpFileLibrary.Library] = []
    @State private var jobs: [OcpFileLibrary.Job] = []
    @State private var scrapes: [OcpFileLibrary.ScrapeRun] = []
    @State private var unmatchedItems: [OcpFileLibrary.Item] = []
    @State private var matchingItem: OcpFileLibrary.Item?
    @State private var working = false
    @State private var error: String?
    @State private var reloadGeneration = 0
    @State private var appendingToLibrary: OcpFileLibrary.Library?
    @State private var pickingLocalFolders = false
    @State private var reauthorizingRoot: OcpFileLibrary.LibraryRoot?
    @State private var pickingReauthFolder = false
    @State private var renamingLibrary: OcpFileLibrary.Library?
    @State private var renameInput = ""
    @State private var deletingLibrary: OcpFileLibrary.Library?
    @State private var removingRoot: (library: OcpFileLibrary.Library, root: OcpFileLibrary.LibraryRoot)?
    @State private var showsAllUnmatched = false

    private static let activeScanStatuses: Set<String> = ["enumerating", "running", "queued"]
    private static let resumableScanStatuses: Set<String> = ["paused", "interrupted", "waitingPermission", "waitingCredentials", "waitingNetwork"]
    private static let activeScrapeStatuses: Set<String> = ["running", "queued", "waitingNetwork"]
    private static let resumableScrapeStatuses: Set<String> = ["paused", "interrupted", "waitingCredentials"]
    private static let retryableScrapeStatuses: Set<String> = ["partialFailure", "failed", "needsMatch"]
    private static let unmatchedPreviewLimit = 8

    private var source: OcpFileLibrary.Source? {
        app.fileLibrary.sources.first { $0.sourceId == sourceID }
    }

    private var isLocalSource: Bool { source?.kind == "localFolder" }

    private var sheetTitle: String {
        isLocalSource ? "本地媒体库" : (source?.displayName ?? "管理文件媒体库")
    }

    private var folderCount: Int {
        libraries.reduce(0) { $0 + $1.allRoots.count }
    }

    private var headerSubtitle: String? {
        guard let source else { return nil }
        let scope = "\(libraries.count) 个分类 · \(folderCount) 个文件夹"
        return source.kind == "localFolder" ? scope : "\(FileLibraryProjection.sourceKindLabel(source.kind)) · \(scope)"
    }

    private var scrapingAvailable: Bool {
        app.tmdb.isConfigured && app.fileLibrary.capabilities?.tmdbScraping == true
    }

    var body: some View {
        VStack(spacing: 0) {
            AppSheetHeader(
                title: sheetTitle,
                symbol: isLocalSource ? "internaldrive" : "externaldrive.connected.to.line.below",
                subtitle: headerSubtitle
            )
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let source { sourceCard(source) }
                    if let message = app.fileLibrary.permissionErrors[sourceID] {
                        permissionCard(message)
                    }
                    librariesSection
                    if !unmatchedItems.isEmpty { unmatchedSection }
                    notices
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 2)
                .padding(.bottom, 24)
            }
            .refreshable { await reload() }
            AppSheetDivider()
            AppSheetFooter {
                footerStatus
            } actions: {
                Button("完成") { dismiss() }
                    .buttonStyle(AppSheetButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .appSheetSurface(size: .subscription)
        .task(id: "\(sourceID)-\(app.fileLibrary.catalogRevision)-\(app.fileLibrary.metadataRevision)") {
            await reload()
        }
        .fileImporter(
            isPresented: $pickingLocalFolders,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            let target = appendingToLibrary
            appendingToLibrary = nil
            guard let target else { return }
            Task { await appendLocalFolders(result, to: target) }
        }
        .background {
            Color.clear
                .fileImporter(
                    isPresented: $pickingReauthFolder,
                    allowedContentTypes: [.folder]
                ) { result in
                    let targetRoot = reauthorizingRoot
                    reauthorizingRoot = nil
                    guard let source, let targetRoot else { return }
                    do {
                        try app.fileLibrary.authorizeRoot(source: source, libraryRoot: targetRoot, url: try result.get())
                        error = nil
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
        }
        .alert(
            "重命名分类",
            isPresented: Binding(
                get: { renamingLibrary != nil },
                set: { if !$0 { renamingLibrary = nil } }
            ),
            presenting: renamingLibrary
        ) { target in
            TextField("分类名称", text: $renameInput)
            Button("取消", role: .cancel) { renamingLibrary = nil }
            Button("保存") {
                let newName = renameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                renamingLibrary = nil
                guard !newName.isEmpty else { return }
                Task { await rename(target, to: newName) }
            }
        } message: { target in
            Text("为「\(target.name)」设置新的显示名称。")
        }
        .alert(
            "删除分类？",
            isPresented: Binding(
                get: { deletingLibrary != nil },
                set: { if !$0 { deletingLibrary = nil } }
            ),
            presenting: deletingLibrary
        ) { target in
            Button("取消", role: .cancel) { deletingLibrary = nil }
            Button("删除分类", role: .destructive) {
                deletingLibrary = nil
                Task { await delete(target) }
            }
        } message: { target in
            Text("将从媒体库移除「\(target.name)」及其索引和观看记录，不会删除你的视频文件。")
        }
        .alert(
            "移除文件夹？",
            isPresented: Binding(
                get: { removingRoot != nil },
                set: { if !$0 { removingRoot = nil } }
            ),
            presenting: removingRoot
        ) { pair in
            Button("取消", role: .cancel) { removingRoot = nil }
            Button("移除文件夹", role: .destructive) {
                removingRoot = nil
                Task { await removeRoot(pair.root, from: pair.library) }
            }
        } message: { pair in
            Text("将从分类「\(pair.library.name)」移除文件夹 \(pair.root.rootPath) 及其索引，不会删除你的视频文件。")
        }
        .sheet(item: $matchingItem) { item in
            FileLibraryMatchSheet(item: item)
        }
    }

    // MARK: - 来源

    private func sourceCard(_ source: OcpFileLibrary.Source) -> some View {
        let isLocal = source.kind == "localFolder"
        return HStack(spacing: 12) {
            ManagementIconTile(symbol: isLocal ? "folder.fill" : "network")
            VStack(alignment: .leading, spacing: 3) {
                Text(FileLibraryProjection.sourceKindLabel(source.kind))
                    .font(.callout.weight(.medium))
                Text(isLocal ? "全局唯一 · 支持跨磁盘合并多个文件夹" : source.rootPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(isLocal ? "" : source.rootPath)
            }
            Spacer(minLength: 8)
            if !isLocal {
                Button {
                    app.addFileLibraryDraft = FileLibraryDraft(sourceID: sourceID, connectionOnly: true)
                } label: {
                    Label("更新凭据", systemImage: "key")
                }
                .buttonStyle(ManagementChipButtonStyle())
                .help("更新连接凭据")
            }
            Button {
                app.mediaLibrarySheet = .sources
            } label: {
                Label("切换来源", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(ManagementChipButtonStyle())
            .help("切换或管理媒体来源")
        }
        .managementCard()
    }

    private func permissionCard(_ message: String) -> some View {
        let missingRoots = app.fileLibrary.permissionErrorRoots[sourceID] ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("目录权限需要重新授权")
                        .font(.callout.weight(.semibold))
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if missingRoots.isEmpty {
                Button("前往媒体来源重新授权") {
                    app.mediaLibrarySheet = .sources
                }
                .buttonStyle(ManagementChipButtonStyle(prominent: true))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(missingRoots.enumerated()), id: \.element.id) { index, missing in
                        if index > 0 { ManagementInsetDivider() }
                        HStack(spacing: 10) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 13))
                                .foregroundStyle(.orange)
                                .frame(width: 18)
                            Text(missing.rootPath)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(missing.rootPath)
                            Spacer(minLength: 8)
                            Button("重新授权") {
                                reauthorizingRoot = missing
                                pickingReauthFolder = true
                            }
                            .buttonStyle(ManagementChipButtonStyle(prominent: true))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
                .managementInset()
            }
        }
        .managementCard(tint: .orange)
    }

    // MARK: - 分类

    private var librariesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                ManagementSectionTitle(title: "分类", count: libraries.count)
                Spacer(minLength: 8)
                if !libraries.isEmpty {
                    Button {
                        app.addFileLibraryDraft = FileLibraryDraft(sourceID: sourceID)
                    } label: {
                        Label("添加分类", systemImage: "plus")
                    }
                    .buttonStyle(ManagementChipButtonStyle())
                    .disabled(working)
                    .help("添加新分类或批量添加文件夹")
                }
            }
            if libraries.isEmpty {
                emptyLibrariesCard
            } else {
                ForEach(libraries) { library in
                    libraryCard(library)
                }
                Text("扫描完成后会先匹配电影与整剧，再补齐本地已有季、集的元数据；未自动匹配的条目可在下方或详情页手动绑定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var emptyLibrariesCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("还没有分类")
                .font(.callout.weight(.medium))
            Text("添加电影或电视剧文件夹，扫描后会自动整理并获取海报与简介。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                app.addFileLibraryDraft = FileLibraryDraft(sourceID: sourceID)
            } label: {
                Label("添加分类", systemImage: "plus")
            }
            .buttonStyle(ManagementChipButtonStyle(prominent: true))
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .managementCard()
    }

    private func libraryCard(_ library: OcpFileLibrary.Library) -> some View {
        let roots = library.allRoots
        let isMovies = library.type == .movies
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ManagementIconTile(symbol: isMovies ? "film" : "tv")
                VStack(alignment: .leading, spacing: 3) {
                    Text(library.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(isMovies ? "电影" : "电视剧") · \(roots.count) 个文件夹")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                libraryMenu(library)
            }

            VStack(spacing: 0) {
                ForEach(roots) { root in
                    folderRow(root, in: library, removable: roots.count > 1)
                    ManagementInsetDivider()
                }
                Button {
                    beginAppendingFolders(to: library)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 18)
                        Text("追加文件夹（合并显示）")
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(working)
            }
            .managementInset()

            VStack(alignment: .leading, spacing: 12) {
                scanRow(library, job: jobs.first { $0.libraryId == library.libraryId })
                ManagementInsetDivider(leading: 32)
                scrapeRow(library, run: scrapes.first { $0.libraryId == library.libraryId })
            }
        }
        .managementCard()
    }

    private func libraryMenu(_ library: OcpFileLibrary.Library) -> some View {
        Menu {
            Button {
                beginAppendingFolders(to: library)
            } label: {
                Label("追加文件夹…", systemImage: "folder.badge.plus")
            }
            Button {
                renameInput = library.name
                renamingLibrary = library
            } label: {
                Label("重命名…", systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                deletingLibrary = library
            } label: {
                Label("删除分类…", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                #if os(iOS)
                .frame(width: 36, height: 36)
                #else
                .frame(width: 28, height: 28)
                #endif
                .background(Color.primary.opacity(0.05), in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(working)
        .help("更多操作")
        .accessibilityLabel("「\(library.name)」更多操作")
    }

    private func folderRow(_ root: OcpFileLibrary.LibraryRoot, in library: OcpFileLibrary.Library, removable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(root.rootPath)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(root.rootPath)
            Spacer(minLength: 8)
            if removable {
                Button(role: .destructive) {
                    removingRoot = (library, root)
                } label: {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(working)
                .help("从此分类移除该文件夹")
                .accessibilityLabel("移除文件夹 \(root.rootPath)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - 任务状态

    @ViewBuilder
    private func scanRow(_ library: OcpFileLibrary.Library, job: OcpFileLibrary.Job?) -> some View {
        let isActive = job.map { Self.activeScanStatuses.contains($0.status) } ?? false
        let isResumable = job.map { Self.resumableScanStatuses.contains($0.status) } ?? false
        ManagementTaskRow(
            symbol: "magnifyingglass",
            title: "目录扫描",
            status: job?.fileLibraryStatusLabel ?? "尚未扫描",
            tone: job.map { Self.scanTone($0.status) } ?? .neutral,
            detail: job.map { job -> String in
                var text = "发现 \(job.filesFound) 个文件 · 已扫描 \(job.directoriesDone) 个目录"
                if job.errorCount > 0 { text += " · \(job.errorCount) 个错误" }
                return text
            } ?? "扫描后会把视频文件整理进此分类。",
            error: job?.lastError,
            isActive: isActive
        ) {
            if let job, isActive {
                Button("暂停") { Task { await control(job, .pause) } }
                    .buttonStyle(ManagementChipButtonStyle())
                Button("取消") { Task { await control(job, .cancel) } }
                    .buttonStyle(ManagementChipButtonStyle())
            } else if let job, isResumable {
                Button("继续") { Task { await control(job, .resume) } }
                    .buttonStyle(ManagementChipButtonStyle(prominent: true))
                Button("取消") { Task { await control(job, .cancel) } }
                    .buttonStyle(ManagementChipButtonStyle())
            } else {
                Button {
                    Task { await scan(library) }
                } label: {
                    Label(job == nil ? "扫描" : "重新扫描", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ManagementChipButtonStyle(prominent: job == nil))
            }
        }
    }

    @ViewBuilder
    private func scrapeRow(_ library: OcpFileLibrary.Library, run: OcpFileLibrary.ScrapeRun?) -> some View {
        let isActive = run.map { Self.activeScrapeStatuses.contains($0.status) } ?? false
        let isResumable = run.map { Self.resumableScrapeStatuses.contains($0.status) } ?? false
        let isRetryable = run.map { Self.retryableScrapeStatuses.contains($0.status) } ?? false
        let progress: Double? = run.flatMap { run -> Double? in
            guard run.total > 0, isActive || run.status == "paused" else { return nil }
            return min(1, Double(run.completed) / Double(run.total))
        }
        ManagementTaskRow(
            symbol: "sparkles",
            title: "TMDB 刮削",
            status: run?.fileLibraryStatusLabel ?? (app.tmdb.isConfigured ? "尚未刮削" : "未配置凭据"),
            tone: run.map { Self.scrapeTone($0.status) } ?? (app.tmdb.isConfigured ? .neutral : .warning),
            detail: scrapeDetail(run),
            error: run?.lastError,
            isActive: isActive,
            progress: progress
        ) {
            Group {
                if let run, isActive {
                    Button("暂停") { Task { await controlScrape(run, .pause) } }
                        .buttonStyle(ManagementChipButtonStyle())
                    Button("取消") { Task { await controlScrape(run, .cancel) } }
                        .buttonStyle(ManagementChipButtonStyle())
                } else if let run, isResumable {
                    Button("继续") { Task { await controlScrape(run, .resume) } }
                        .buttonStyle(ManagementChipButtonStyle(prominent: true))
                        .disabled(!app.tmdb.isConfigured)
                    if run.status == "paused" {
                        Button("取消") { Task { await controlScrape(run, .cancel) } }
                            .buttonStyle(ManagementChipButtonStyle())
                    }
                } else {
                    if let run, isRetryable {
                        Button("重试失败项") { Task { await controlScrape(run, .retry) } }
                            .buttonStyle(ManagementChipButtonStyle(prominent: true))
                            .disabled(!app.tmdb.isConfigured)
                    }
                    Button {
                        Task { await scrape(library) }
                    } label: {
                        Label(run == nil ? "刮削" : "刷新", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(ManagementChipButtonStyle(prominent: run == nil && scrapingAvailable))
                    .disabled(!scrapingAvailable)
                    .help(scrapingAvailable ? "从 TMDB 刮削 / 刷新「\(library.name)」的元数据" : "需要先配置并验证 TMDB 凭据")
                }
            }
            .disabled(working)
        }
    }

    private func scrapeDetail(_ run: OcpFileLibrary.ScrapeRun?) -> String {
        guard let run else {
            return app.tmdb.isConfigured
                ? "从 TMDB 获取海报、简介与剧集信息。"
                : "在线刮削已暂停。配置并验证 TMDB 凭据后可继续；已保存的海报、详情与播放进度仍可离线使用。"
        }
        var parts = ["完成 \(run.completed) / \(run.total) 项"]
        if run.unmatched > 0 { parts.append("待手动匹配 \(run.unmatched) 项") }
        if run.failed > 0 { parts.append("失败 \(run.failed) 项") }
        if let retry = run.nextRetryAt {
            parts.append("下次重试 \(Date(timeIntervalSince1970: retry).formatted(date: .omitted, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private static func scanTone(_ status: String) -> ManagementStatusTone {
        switch status {
        case "completed": .success
        case "failed", "interrupted", "waitingPermission", "waitingCredentials", "waitingNetwork": .warning
        case "enumerating", "running", "queued": .active
        default: .neutral
        }
    }

    private static func scrapeTone(_ status: String) -> ManagementStatusTone {
        switch status {
        case "completed": .success
        case "failed", "partialFailure", "needsMatch", "interrupted", "waitingCredentials", "waitingNetwork": .warning
        case "running", "queued": .active
        default: .neutral
        }
    }

    // MARK: - 待手动匹配

    private var unmatchedSection: some View {
        let visible = showsAllUnmatched ? unmatchedItems : Array(unmatchedItems.prefix(Self.unmatchedPreviewLimit))
        let canMatch = app.tmdb.isConfigured && app.fileLibrary.capabilities?.tmdbScraping == true
        return VStack(alignment: .leading, spacing: 10) {
            ManagementSectionTitle(title: "待手动匹配", count: unmatchedItems.count)
            VStack(alignment: .leading, spacing: 0) {
                if !app.tmdb.isConfigured {
                    Label("请先在设置中配置 TMDB API Key，再进行手动匹配。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.bottom, 10)
                }
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { ManagementInsetDivider(leading: 42) }
                    unmatchedRow(item, canMatch: canMatch)
                }
                if unmatchedItems.count > Self.unmatchedPreviewLimit {
                    ManagementInsetDivider()
                    Button {
                        withAnimation(.snappy) { showsAllUnmatched.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showsAllUnmatched ? "收起" : "显示全部 \(unmatchedItems.count) 项")
                            Image(systemName: showsAllUnmatched ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .managementCard()
        }
    }

    private func unmatchedRow(_ item: OcpFileLibrary.Item, canMatch: Bool) -> some View {
        let categoryName = libraries.first { $0.libraryId == item.libraryId }?.name ?? "分类"
        let kindLabel = item.kind == .movie ? "电影" : "电视剧"
        let yearText = item.year.map { " · \($0)" } ?? ""
        return HStack(spacing: 12) {
            ManagementIconTile(symbol: item.kind == .movie ? "film" : "tv", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.title)
                Text("\(categoryName) · \(kindLabel)\(yearText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("手动匹配") {
                matchingItem = item
            }
            .buttonStyle(ManagementChipButtonStyle())
            .disabled(!canMatch)
        }
        .padding(.vertical, 8)
    }

    // MARK: - 提示与底栏

    @ViewBuilder
    private var notices: some View {
        if let message = app.fileLibrary.scrapingError {
            ManagementNotice(text: message, symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
        if let error {
            ManagementNotice(text: error, symbol: "xmark.octagon.fill", tint: .red)
        }
        if let error = app.fileLibrary.progressError {
            ManagementNotice(text: error, symbol: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private var footerStatus: some View {
        HStack(spacing: 8) {
            if working {
                ProgressView().controlSize(.small)
                Text("正在处理…")
            } else {
                Image(systemName: "clock.arrow.circlepath")
                Text("扫描与刮削在后台进行，可随时关闭此窗口")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    // MARK: - 动作

    private func beginAppendingFolders(to library: OcpFileLibrary.Library) {
        if isLocalSource {
            appendingToLibrary = library
            pickingLocalFolders = true
        } else {
            app.addFileLibraryDraft = FileLibraryDraft(sourceID: sourceID, targetLibraryID: library.libraryId)
        }
    }

    private func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        do {
            async let loadedLibraries = app.fileLibrary.libraries(sourceID: sourceID)
            async let loadedJobs = app.fileLibrary.jobs(sourceID: sourceID)
            async let loadedScrapes = app.fileLibrary.scrapes(sourceID: sourceID)
            let result = try await (loadedLibraries, loadedJobs, loadedScrapes)
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            libraries = result.0
            jobs = result.1
            scrapes = result.2
            var unmatched: [OcpFileLibrary.Item] = []
            for lib in result.0 {
                if let page = try? await app.fileLibrary.page(.init(
                    sourceId: sourceID,
                    libraryId: lib.libraryId,
                    parentId: nil,
                    search: "",
                    startIndex: 0,
                    limit: 500,
                    sortBy: "name",
                    sortAscending: true
                )) {
                    guard !Task.isCancelled, generation == reloadGeneration else { return }
                    unmatched.append(contentsOf: page.items.filter {
                        ($0.kind == .movie || $0.kind == .series) && $0.matchStatus != "matched"
                    })
                }
            }
            guard !Task.isCancelled, generation == reloadGeneration else { return }
            unmatchedItems = unmatched
            app.fileLibrary.setUnmatchedCount(unmatched.count, for: sourceID)
            error = nil
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func appendLocalFolders(_ result: Result<[URL], Error>, to library: OcpFileLibrary.Library) async {
        working = true
        defer { working = false }
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            for folder in urls {
                _ = try await app.fileLibrary.addLocalRoot(
                    sourceID: sourceID,
                    libraryID: library.libraryId,
                    folder: folder
                )
            }
            error = nil
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func rename(_ library: OcpFileLibrary.Library, to newName: String) async {
        working = true
        defer { working = false }
        do {
            _ = try await app.fileLibrary.renameLibrary(sourceID: sourceID, libraryID: library.libraryId, name: newName)
            error = nil
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ library: OcpFileLibrary.Library) async {
        working = true
        defer { working = false }
        do {
            try await app.fileLibrary.deleteLibrary(sourceID: sourceID, libraryID: library.libraryId)
            error = nil
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeRoot(_ root: OcpFileLibrary.LibraryRoot, from library: OcpFileLibrary.Library) async {
        working = true
        defer { working = false }
        do {
            _ = try await app.fileLibrary.removeLibraryRoot(sourceID: sourceID, libraryID: library.libraryId, rootID: root.rootId)
            error = nil
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func scan(_ library: OcpFileLibrary.Library) async {
        do {
            try await app.fileLibrary.scan(sourceID: sourceID, libraryID: library.libraryId)
            error = nil
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func control(_ job: OcpFileLibrary.Job, _ action: OcpFileLibrary.ScanAction) async {
        do {
            try await app.fileLibrary.control(job, action: action)
            error = nil
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func scrape(_ library: OcpFileLibrary.Library) async {
        guard let key = app.tmdb.rawAPIKey else { return }
        working = true
        defer { working = false }
        do {
            try await app.fileLibrary.scrape(
                sourceID: sourceID,
                libraryID: library.libraryId,
                key: key,
                apiBase: app.fileLibraryAPIBase,
                language: app.tmdb.language,
                refresh: true
            )
            error = nil
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func controlScrape(_ run: OcpFileLibrary.ScrapeRun, _ action: OcpFileLibrary.ScrapeAction) async {
        working = true
        defer { working = false }
        do {
            if [.resume, .retry].contains(action), let key = app.tmdb.rawAPIKey {
                _ = try await app.fileLibrary.validate(
                    key: key,
                    apiBase: app.fileLibraryAPIBase,
                    draftID: "file-library-online",
                    language: app.tmdb.language
                )
            }
            try await app.fileLibrary.controlScrape(run, action: action)
            error = nil
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 首页顶部轻量状态条：仅在文件媒体库存在权限异常或扫描/刮削进行中时出现；
/// 平时完全不渲染，确保文件库首页与 Jellyfin/Emby 首页观感完全一致。
struct FileLibraryStatusBanner: View {
    @Environment(AppModel.self) private var app
    let sourceID: String

    private var permissionError: String? {
        app.fileLibrary.permissionErrors[sourceID]
    }

    private var activeJob: OcpFileLibrary.Job? {
        app.fileLibrary.jobsBySource[sourceID]?.first {
            ["enumerating", "running", "queued"].contains($0.status)
        }
    }

    private var activeScrape: OcpFileLibrary.ScrapeRun? {
        app.fileLibrary.scrapesBySource[sourceID]?.first {
            ["running", "queued", "waitingNetwork"].contains($0.status)
        }
    }

    private var unmatchedCount: Int {
        app.fileLibrary.unmatchedCountBySource[sourceID] ?? 0
    }

    private var message: (icon: String, tint: Color, text: String, actionTitle: String, isWorking: Bool)? {
        if let permissionError {
            return ("folder.badge.questionmark", .orange, permissionError, "重新授权", false)
        }
        if let job = activeJob {
            return ("magnifyingglass", .secondary, "正在扫描目录 · 已发现 \(job.filesFound) 个文件", "管理", true)
        }
        if let run = activeScrape {
            let progress = run.total > 0 ? "（\(run.completed)/\(run.total)）" : ""
            return ("sparkles", .secondary, "正在刮削 TMDB 元数据\(progress)", "管理", true)
        }
        if let scrapingError = app.fileLibrary.scrapingError {
            return ("exclamationmark.triangle", .orange, scrapingError, "管理", false)
        }
        if unmatchedCount > 0 {
            return ("questionmark.circle", .orange, "有 \(unmatchedCount) 个项目未能自动匹配 TMDB", "去手动匹配", false)
        }
        return nil
    }

    var body: some View {
        if let info = message {
            Button {
                if permissionError != nil {
                    app.isMediaSourcesPresented = true
                } else {
                    app.openFileLibraryManagement()
                }
            } label: {
                HStack(spacing: 8) {
                    if info.isWorking {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: info.icon)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(info.tint)
                    }
                    Text(info.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(info.actionTitle)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .liquidGlassCard(cornerRadius: 12)
            }
            .buttonStyle(.plain)
            .transition(.section)
        }
    }
}

extension OcpFileLibrary.Job {
    var fileLibrarySnapshotKey: String {
        "\(jobId):\(status):\(filesFound):\(directoriesDone):\(errorCount):\(lastError ?? "")"
    }

    var fileLibraryIsActive: Bool {
        ["enumerating", "running", "queued"].contains(status)
    }

    var fileLibraryStatusLabel: String {
        switch status {
        case "queued": "等待扫描"
        case "enumerating", "running": "扫描中"
        case "paused": "已暂停"
        case "interrupted": "扫描中断"
        case "waitingPermission": "等待目录授权"
        case "waitingCredentials": "等待凭据"
        case "waitingNetwork": "等待网络重试"
        case "completed": "扫描完成"
        case "cancelled": "已取消"
        case "failed": "扫描失败"
        default: status
        }
    }
}

extension OcpFileLibrary.ScrapeRun {
    var fileLibrarySnapshotKey: String {
        "\(runId):\(status):\(total):\(completed):\(unmatched):\(failed):\(lastError ?? ""):\(nextRetryAt ?? 0)"
    }

    var fileLibraryIsActive: Bool {
        ["running", "queued", "waitingNetwork"].contains(status)
    }

    var fileLibraryStatusLabel: String {
        switch status {
        case "queued": "等待刮削"
        case "running": total == 0 ? "等待目录扫描完成" : "刮削中"
        case "waitingNetwork": "等待网络重试"
        case "waitingCredentials": "等待有效 TMDB 凭据"
        case "paused": "已暂停"
        case "interrupted": "刮削中断"
        case "completed": "刮削完成"
        case "needsMatch": "部分条目需要手动匹配"
        case "partialFailure": "部分刮削失败"
        case "cancelled": "已取消"
        case "failed": "刮削失败"
        default: status
        }
    }
}

// MARK: - 管理面板视觉组件

private enum ManagementStatusTone {
    case neutral, active, success, warning

    var color: Color {
        switch self {
        case .neutral, .active: .secondary
        case .success: .green
        case .warning: .orange
        }
    }
}

private extension View {
    /// 与 `AppSheetSection` 同一套半透明分组底；传入 tint 时用于警示类卡片。
    func managementCard(tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background((tint ?? Color.primary).opacity(tint == nil ? 0.025 : 0.07), in: shape)
            .overlay {
                shape.strokeBorder((tint ?? Color.primary).opacity(tint == nil ? 0.06 : 0.22), lineWidth: 0.5)
            }
    }

    /// 卡片内的嵌套列表底（文件夹列表等）。
    func managementInset() -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return background(Color.primary.opacity(0.03), in: shape)
            .overlay { shape.strokeBorder(Color.primary.opacity(0.05), lineWidth: 0.5) }
    }
}

private struct ManagementIconTile: View {
    let symbol: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct ManagementSectionTitle: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))
            if let count, count > 0 {
                Text("\(count)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
        .padding(.horizontal, 4)
    }
}

private struct ManagementInsetDivider: View {
    var leading: CGFloat = 40

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
            .padding(.leading, leading)
    }
}

private struct ManagementStatusBadge: View {
    let text: String
    let tone: ManagementStatusTone

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tone.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tone.color.opacity(tone == .neutral ? 0.1 : 0.14), in: Capsule())
            .lineLimit(1)
    }
}

/// 扫描 / 刮削任务行：图标（进行中替换为转圈）、标题 + 状态徽标、明细、可选进度条与右侧操作。
private struct ManagementTaskRow<Actions: View>: View {
    let symbol: String
    let title: String
    let status: String
    let tone: ManagementStatusTone
    let detail: String
    var error: String?
    var isActive = false
    var progress: Double?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if isActive {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    ManagementStatusBadge(text: status, tone: tone)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                if let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.primary)
                        .padding(.top, 2)
                }
                if let error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) { actions() }
                .fixedSize()
        }
    }
}

private struct ManagementNotice: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .managementCard(tint: tint)
    }
}

/// 卡片内的小号胶囊按钮；prominent 为实底主操作。
private struct ManagementChipButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let solid = prominent && isEnabled
        return configuration.label
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 11)
            #if os(iOS)
            .frame(minHeight: 32)
            #else
            .frame(minHeight: 26)
            #endif
            .foregroundStyle(solid ? AppAccent.onSolid : (isEnabled ? Color.primary : Color.secondary))
            .background(solid ? AppAccent.solid : Color.primary.opacity(configuration.isPressed ? 0.1 : 0.05), in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(solid ? 0 : 0.08), lineWidth: 0.5)
            }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : (isEnabled ? 1 : 0.6))
    }
}

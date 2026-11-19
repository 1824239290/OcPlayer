import OcPlayerCore
import AppDesignKit
import SwiftUI

private enum FileLibraryRoute: Hashable {
    case catalog(libraryID: String, parentID: String?, title: String)
    case detail(itemID: String)
}

struct FileLibraryShellView: View {
    @Environment(AppModel.self) private var app
    let sourceID: String

    var body: some View {
        NavigationStack {
            FileLibraryHomeView(sourceID: sourceID)
                .navigationDestination(for: FileLibraryRoute.self) { route in
                    switch route {
                    case let .catalog(libraryID, parentID, title):
                        FileLibraryCatalogView(sourceID: sourceID, libraryID: libraryID, parentID: parentID, title: title)
                    case let .detail(itemID): FileLibraryDetailView(sourceID: sourceID, itemID: itemID)
                    }
                }
                .toolbar {
                    ToolbarItem { Button("媒体来源", systemImage: "externaldrive") { app.isMediaSourcesPresented = true } }
                    ToolbarItem { Button("添加分类", systemImage: "plus") { app.addFileLibraryDraft = .init(sourceID: sourceID) } }
                }
        }
        .id(sourceID)
        .task(id: app.fileLibraryCredentialRevision + app.tmdb.language + String(app.fileLibrary.configurationRevision)) {
            await app.fileLibrary.resumeOnlineWork(sourceID: sourceID, key: app.tmdb.rawAPIKey,
                                                   apiBase: app.fileLibraryAPIBase, language: app.tmdb.language)
        }
        .task {
            var checkpoint: String?
            while !Task.isCancelled {
                do {
                    async let jobs = app.fileLibrary.jobs(sourceID: sourceID)
                    async let scrapes = app.fileLibrary.scrapes(sourceID: sourceID)
                    let snapshots = try await (jobs, scrapes)
                    guard !Task.isCancelled, app.activeFileSourceID == sourceID else { return }
                    let latest = (snapshots.0.map(\.snapshotKey) + snapshots.1.map(\.snapshotKey)).joined(separator: "\0")
                    if checkpoint != latest { checkpoint = latest; app.fileLibrary.metadataDidChange() }
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError { return }
                catch { app.fileLibrary.taskObservationFailed(error); return }
            }
        }
    }
}

private struct FileLibraryHomeView: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    @State private var libraries: [OcpFileLibrary.Library] = []
    @State private var resume: [OcpFileLibrary.Item] = []
    @State private var jobs: [OcpFileLibrary.Job] = []
    @State private var scrapes: [OcpFileLibrary.ScrapeRun] = []
    @State private var working = false
    @State private var error: String?
    @State private var reloadGeneration = 0

    var body: some View {
        List {
            if let message = app.fileLibrary.permissionErrors[sourceID] {
                Section { Label(message, systemImage: "folder.badge.questionmark").foregroundStyle(.orange)
                    Button("重新授权目录") { app.isMediaSourcesPresented = true } }
            }
            if !resume.isEmpty {
                Section("继续观看") {
                    ForEach(resume) { item in
                        NavigationLink(value: FileLibraryRoute.detail(itemID: item.itemId)) { FileLibraryItemLabel(item: item) }
                    }
                }
            }
            Section("分类") {
                ForEach(libraries) { library in
                    NavigationLink(value: FileLibraryRoute.catalog(libraryID: library.libraryId, parentID: nil, title: library.name)) {
                        VStack(alignment: .leading) {
                            Label(library.name, systemImage: library.type == .movies ? "film" : "tv")
                            Text(library.type == .movies ? "电影" : "电视剧").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if libraries.isEmpty { Text("还没有分类，请添加电影或电视剧目录。") }
            }
            Section("目录扫描") {
                ForEach(libraries) { library in
                    Button("扫描「\(library.name)」") { Task { await scan(library) } }
                        .disabled(jobs.contains { $0.libraryId == library.libraryId && ["enumerating", "queued"].contains($0.status) })
                }
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(libraries.first { $0.libraryId == job.libraryId }?.name ?? "分类") · \(job.statusLabel)")
                        Text("发现 \(job.filesFound) 个文件 · 已扫描 \(job.directoriesDone) 个目录 · 错误 \(job.errorCount)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let message = job.lastError { Text(message).font(.caption).foregroundStyle(.orange) }
                        HStack {
                            if ["enumerating", "queued"].contains(job.status) { Button("暂停") { Task { await control(job, .pause) } } }
                            if ["paused", "interrupted", "waitingPermission", "waitingCredentials", "waitingNetwork"].contains(job.status) { Button("继续") { Task { await control(job, .resume) } } }
                            if !["completed", "cancelled", "failed"].contains(job.status) { Button("取消扫描") { Task { await control(job, .cancel) } } }
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            Section("TMDB 刮削") {
                if !app.tmdb.isConfigured {
                    Text("在线刮削已暂停。配置并验证 TMDB 凭据后可继续；已保存的详情和进度仍可使用。")
                    Button("配置 TMDB") { app.isMediaSourcesPresented = true }
                }
                ForEach(libraries) { library in
                    Button("刮削 / 刷新「\(library.name)」") { Task { await scrape(library) } }
                        .disabled(working || !app.tmdb.isConfigured || app.fileLibrary.capabilities?.tmdbScraping != true || scrapes.contains { $0.libraryId == library.libraryId && ["running", "queued", "waitingNetwork"].contains($0.status) })
                }
                ForEach(scrapes) { run in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(libraries.first { $0.libraryId == run.libraryId }?.name ?? "分类") · \(run.statusLabel)")
                        Text("完成 \(run.completed) / \(run.total) 项 · 待手动匹配 \(run.unmatched) 项 · 失败 \(run.failed) 项")
                            .font(.caption).foregroundStyle(.secondary)
                        if let message = run.lastError { Text(message).font(.caption).foregroundStyle(.orange) }
                        if let retry = run.nextRetryAt { Text("下次重试：\(Date(timeIntervalSince1970: retry).formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            if ["running", "queued", "waitingNetwork"].contains(run.status) { Button("暂停刮削") { Task { await controlScrape(run, .pause) } } }
                            if ["paused", "interrupted", "waitingCredentials"].contains(run.status) { Button("继续刮削") { Task { await controlScrape(run, .resume) } }.disabled(!app.tmdb.isConfigured) }
                            if ["partialFailure", "failed", "needsMatch"].contains(run.status) { Button("重试失败项") { Task { await controlScrape(run, .retry) } }.disabled(!app.tmdb.isConfigured) }
                            if ["running", "queued", "waitingNetwork", "paused"].contains(run.status) { Button("取消刮削") { Task { await controlScrape(run, .cancel) } } }
                        }.buttonStyle(.bordered).controlSize(.small).disabled(working)
                    }
                }
                Text("电影和整剧先匹配，再下载已有季、集的元数据。置信度不足的条目可在详情页手动匹配。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let message = app.fileLibrary.scrapingError { Section { Text(message).foregroundStyle(.orange) } }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if let error = app.fileLibrary.progressError { Section { Text(error).foregroundStyle(.orange) } }
        }
        .navigationTitle(app.fileLibrary.sources.first { $0.sourceId == sourceID }?.displayName ?? "文件媒体库")
        .refreshable { await reload() }
        .task(id: app.fileLibrary.catalogRevision) { await reload() }
    }

    private func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        do {
            async let loadedLibraries = app.fileLibrary.libraries(sourceID: sourceID)
            async let loadedResume = app.fileLibrary.resume(sourceID: sourceID)
            async let loadedJobs = app.fileLibrary.jobs(sourceID: sourceID)
            async let loadedScrapes = app.fileLibrary.scrapes(sourceID: sourceID)
            let result = try await (loadedLibraries, loadedResume, loadedJobs, loadedScrapes)
            guard !Task.isCancelled, generation == reloadGeneration, app.activeFileSourceID == sourceID else { return }
            libraries = result.0; resume = result.1; jobs = result.2; scrapes = result.3; error = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    private func scan(_ library: OcpFileLibrary.Library) async {
        do { try await app.fileLibrary.scan(sourceID: sourceID, libraryID: library.libraryId); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func control(_ job: OcpFileLibrary.Job, _ action: OcpFileLibrary.ScanAction) async {
        do { try await app.fileLibrary.control(job, action: action); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func scrape(_ library: OcpFileLibrary.Library) async {
        guard let key = app.tmdb.rawAPIKey else { return }
        working = true; defer { working = false }
        do { try await app.fileLibrary.scrape(sourceID: sourceID, libraryID: library.libraryId, key: key,
                                              apiBase: app.fileLibraryAPIBase, language: app.tmdb.language, refresh: true); error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func controlScrape(_ run: OcpFileLibrary.ScrapeRun, _ action: OcpFileLibrary.ScrapeAction) async {
        working = true; defer { working = false }
        do {
            if [.resume, .retry].contains(action), let key = app.tmdb.rawAPIKey {
                _ = try await app.fileLibrary.validate(key: key, apiBase: app.fileLibraryAPIBase, draftID: "file-library-online", language: app.tmdb.language)
            }
            try await app.fileLibrary.controlScrape(run, action: action); error = nil
        } catch { self.error = error.localizedDescription }
    }
}

private struct FileLibraryCatalogView: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    let libraryID: String
    let parentID: String?
    let title: String
    @State private var items: [OcpFileLibrary.Item] = []
    @State private var search = ""
    @State private var total: Int64 = 0
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadGeneration = 0

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210))], spacing: 20) {
                ForEach(items) { item in
                    NavigationLink(value: FileLibraryRoute.detail(itemID: item.itemId)) {
                        FileLibraryPoster(item: item)
                    }.buttonStyle(.plain)
                }
            }.padding()
            if isLoading { ProgressView().padding() }
            if let error { Text(error).foregroundStyle(.red).padding(); Button("重试") { Task { await load(reset: items.isEmpty) } } }
            if !isLoading, error == nil, items.isEmpty {
                ContentUnavailableView(search.isEmpty ? "暂时没有影片" : "没有搜索结果", systemImage: "film",
                                       description: Text(search.isEmpty ? "目录扫描完成后会显示影片；可以返回首页检查扫描状态。" : "试试其它片名。"))
            }
            if Int64(items.count) < total, !isLoading { Button("加载更多") { Task { await load(reset: false) } }.padding() }
        }
        .navigationTitle(title)
        .searchable(text: $search, prompt: "搜索当前分类")
        .task(id: search + "\0" + String(app.fileLibrary.metadataRevision)) {
            if !search.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            await load(reset: true)
        }
        .refreshable { await load(reset: true) }
    }

    private func load(reset: Bool) async {
        if !reset && isLoading { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        let term = search
        isLoading = true; error = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let page = try await app.fileLibrary.page(.init(sourceId: sourceID, libraryId: libraryID, parentId: parentID,
                                                           search: term, startIndex: reset ? 0 : Int64(items.count)))
            guard !Task.isCancelled, generation == loadGeneration, term == search, app.activeFileSourceID == sourceID else { return }
            items = reset ? page.items : items + page.items
            total = page.totalCount
        } catch { if !Task.isCancelled, generation == loadGeneration, term == search { self.error = error.localizedDescription } }
    }
}

private struct FileLibraryDetailView: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    let itemID: String
    @State private var detail: OcpFileLibrary.Detail?
    @State private var error: String?
    @State private var preparing = false
    @State private var matchingItem: OcpFileLibrary.Item?
    @State private var unbinding = false

    var body: some View {
        List {
            if let detail {
                Section { FileLibraryPoster(item: detail.item).frame(maxWidth: 220).frame(maxWidth: .infinity) }
                if let overview = detail.item.metadataString("overview"), !overview.isEmpty { Section("简介") { Text(overview) } }
                if [.series, .season].contains(detail.item.kind) {
                    Section {
                        NavigationLink(detail.item.kind == .series ? "查看季" : "查看剧集",
                                       value: FileLibraryRoute.catalog(libraryID: detail.item.libraryId, parentID: itemID, title: detail.item.title))
                    }
                }
                if !detail.assets.isEmpty {
                    Section("播放文件") {
                        ForEach(detail.assets) { asset in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(asset.relativePath).font(.callout).textSelection(.enabled)
                                if !asset.available { Text("文件已不可用").foregroundStyle(.orange) }
                                HStack {
                                    Button(detail.progress.map { !$0.completed && $0.positionSeconds > 0 } == true ? "继续播放" : "播放") {
                                        Task { await play(detail.item, asset: asset, fromStart: false) }
                                    }
                                    if detail.progress?.positionSeconds ?? 0 > 0 {
                                        Button("从头播放") { Task { await play(detail.item, asset: asset, fromStart: true) } }
                                    }
                                }.disabled(!asset.available || preparing)
                            }
                        }
                    }
                }
                Section("识别状态") {
                    Text(detail.item.matchStatus == "matched" ? "已匹配 TMDB" : "待匹配 TMDB")
                    if detail.item.kind == .unidentified { Text("无法确定季、集编号，已保留原文件。请检查文件命名。") }
                    if [.movie, .series].contains(detail.item.kind) {
                        Button("手动匹配 TMDB") { matchingItem = detail.item }.disabled(!app.tmdb.isConfigured || app.fileLibrary.capabilities?.tmdbScraping != true || unbinding)
                        if detail.item.matchStatus == "matched" {
                            Button("解除 TMDB 匹配", role: .destructive) { Task { await unbind(detail.item) } }.disabled(unbinding)
                        }
                    } else if let seriesID = detail.item.seriesId {
                        NavigationLink("前往整剧匹配", value: FileLibraryRoute.detail(itemID: seriesID))
                    }
                }
            } else if error == nil { ProgressView("正在读取详情…") }
            if preparing { ProgressView("正在准备播放…") }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(detail?.item.title ?? "详情")
        .sheet(item: $matchingItem) { item in FileLibraryMatchSheet(item: item) }
        .task(id: app.fileLibrary.catalogRevision) {
            do {
                let value = try await app.fileLibrary.detail(sourceID: sourceID, itemID: itemID)
                guard !Task.isCancelled, app.activeFileSourceID == sourceID else { return }
                detail = value; error = nil
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func play(_ item: OcpFileLibrary.Item, asset: OcpFileLibrary.Asset, fromStart: Bool) async {
        preparing = true; error = nil
        defer { preparing = false }
        do { try await app.playFileLibraryItem(item, asset: asset, fromStart: fromStart) }
        catch { self.error = error.localizedDescription }
    }
    private func unbind(_ item: OcpFileLibrary.Item) async {
        unbinding = true; defer { unbinding = false }
        do { try await app.fileLibrary.unbind(item: item); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private struct FileLibraryPoster: View {
    @Environment(AppModel.self) private var app
    @Environment(\.displayScale) private var displayScale
    let item: OcpFileLibrary.Item
    var body: some View {
        let _ = app.fileLibrary.metadataRevision
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: app.fileLibraryImageURL(path: item.metadataString("poster_path") ?? item.metadataString("still_path")),
                        cacheScope: "file-library:\(item.sourceId)", maxPixelSize: Int(220 * displayScale),
                        emptyIcon: item.kind == .movie ? "film" : "tv", scaling: .fit)
                .aspectRatio(2 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(item.title).font(.headline).lineLimit(2)
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FileLibraryItemLabel: View {
    let item: OcpFileLibrary.Item
    var body: some View {
        VStack(alignment: .leading) { Text(item.title); Text(item.subtitle).font(.caption).foregroundStyle(.secondary) }
    }
}

private extension OcpFileLibrary.Item {
    func metadataString(_ key: String) -> String? {
        guard case let .object(value) = metadata, case let .string(text) = value[key] else { return nil }
        return text
    }
    var subtitle: String {
        switch kind {
        case .movie: return year.map { "电影 · \($0)" } ?? "电影"
        case .series: return "电视剧"
        case .season: return seasonNumber == 0 ? "特别篇" : "第 \(seasonNumber ?? 0) 季"
        case .episode: return "S\(seasonNumber ?? 0) · E\(episodeNumber ?? 0)"
        case .unidentified: return "待识别文件"
        }
    }
}

private extension OcpFileLibrary.Job {
    var snapshotKey: String { "\(jobId):\(status):\(filesFound):\(directoriesDone):\(errorCount):\(lastError ?? "")" }
    var statusLabel: String {
        switch status {
        case "queued": "等待扫描"
        case "running": "扫描中"
        case "paused": "已暂停"
        case "interrupted": "扫描中断"
        case "waitingPermission": "等待目录授权"
        case "waitingCredentials": "等待 WebDAV 凭据"
        case "waitingNetwork": "等待网络重试"
        case "completed": "扫描完成"
        case "cancelled": "已取消"
        case "failed": "扫描失败"
        default: status
        }
    }
}

private extension OcpFileLibrary.ScrapeRun {
    var snapshotKey: String { "\(runId):\(status):\(total):\(completed):\(unmatched):\(failed):\(lastError ?? ""): \(nextRetryAt ?? 0)" }
    var statusLabel: String {
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

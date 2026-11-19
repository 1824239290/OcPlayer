import OcPlayerCore
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
    }
}

private struct FileLibraryHomeView: View {
    @Environment(AppModel.self) private var app
    let sourceID: String
    @State private var libraries: [OcpFileLibrary.Library] = []
    @State private var resume: [OcpFileLibrary.Item] = []
    @State private var jobs: [OcpFileLibrary.Job] = []
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
                        .disabled(jobs.contains { $0.libraryId == library.libraryId && ["running", "queued"].contains($0.status) })
                }
                ForEach(jobs) { job in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(libraries.first { $0.libraryId == job.libraryId }?.name ?? "分类") · \(job.statusLabel)")
                        Text("发现 \(job.filesFound) 个文件 · 已扫描 \(job.directoriesDone) 个目录 · 错误 \(job.errorCount)")
                            .font(.caption).foregroundStyle(.secondary)
                        if let message = job.lastError { Text(message).font(.caption).foregroundStyle(.orange) }
                        HStack {
                            if ["running", "queued"].contains(job.status) { Button("暂停") { Task { await control(job, .pause) } } }
                            if ["paused", "interrupted", "waitingPermission"].contains(job.status) { Button("继续") { Task { await control(job, .resume) } } }
                            if !["completed", "cancelled", "failed"].contains(job.status) { Button("取消扫描") { Task { await control(job, .cancel) } } }
                        }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
            if let error = app.fileLibrary.progressError { Section { Text(error).foregroundStyle(.orange) } }
        }
        .navigationTitle(app.fileLibrary.sources.first { $0.sourceId == sourceID }?.displayName ?? "文件媒体库")
        .refreshable { await reload() }
        .task(id: app.fileLibrary.catalogRevision) { await reload() }
        .task {
            while !Task.isCancelled {
                do {
                    let latest = try await app.fileLibrary.jobs(sourceID: sourceID)
                    guard !Task.isCancelled, app.activeFileSourceID == sourceID else { return }
                    // Updating only on a real checkpoint avoids invalidating the
                    // catalog every second while browsing a completed scan.
                    if latest.map(\.snapshotKey) != jobs.map(\.snapshotKey) {
                        jobs = latest
                        await reload()
                    }
                    try await Task.sleep(for: .seconds(1))
                } catch is CancellationError { return }
                catch { self.error = error.localizedDescription; return }
            }
        }
    }

    private func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        do {
            async let loadedLibraries = app.fileLibrary.libraries(sourceID: sourceID)
            async let loadedResume = app.fileLibrary.resume(sourceID: sourceID)
            let result = try await (loadedLibraries, loadedResume)
            guard !Task.isCancelled, generation == reloadGeneration, app.activeFileSourceID == sourceID else { return }
            libraries = result.0; resume = result.1; error = nil
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
        .task(id: search) {
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
                }
            } else if error == nil { ProgressView("正在读取详情…") }
            if preparing { ProgressView("正在准备播放…") }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(detail?.item.title ?? "详情")
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
}

private struct FileLibraryPoster: View {
    let item: OcpFileLibrary.Item
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                .aspectRatio(2 / 3.0, contentMode: .fit)
                .overlay { Image(systemName: item.kind == .movie ? "film" : "tv").font(.largeTitle).foregroundStyle(.secondary) }
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
        case "completed": "扫描完成"
        case "cancelled": "已取消"
        case "failed": "扫描失败"
        default: status
        }
    }
}

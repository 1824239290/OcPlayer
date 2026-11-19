import AppDesignKit
import OcPlayerCore
import SwiftUI

struct FileLibraryMatchSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    let item: OcpFileLibrary.Item
    // A one-time editable search seed; later catalog updates must not replace
    // what the user has typed while choosing a candidate.
    @State private var query: String
    @State private var results: OcpFileLibrary.MatchCandidates?
    @State private var searching = false
    @State private var binding = false
    @State private var error: String?
    @State private var generation = 0

    init(item: OcpFileLibrary.Item) { self.item = item; _query = State(initialValue: item.title) }

    var body: some View {
        NavigationStack {
            List {
                Section(item.kind == .movie ? "电影匹配" : "整剧匹配") {
                    Text(item.title).font(.headline)
                    TextField("搜索片名", text: $query).onSubmit { Task { await search() } }
                    Button("搜索 TMDB") { Task { await search() } }
                        .disabled(searching || binding || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !app.tmdb.isConfigured)
                    Text("选择后保存为手动匹配，目录重扫不会覆盖。季和集沿用整剧的匹配。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if searching { ProgressView("正在搜索 TMDB…") }
                if binding { ProgressView("正在下载并保存元数据…") }
                if let results {
                    Section("候选") {
                        ForEach(results.candidates) { candidate in
                            Button { Task { await bind(candidate, version: results.inputVersion) } } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    RemoteImage(url: app.fileLibraryImageURL(path: candidate.posterPath), cacheScope: "file-library:\(item.sourceId)",
                                                maxPixelSize: Int(110 * displayScale), emptyIcon: item.kind == .movie ? "film" : "tv", scaling: .fit)
                                        .frame(width: 65, height: 98)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(candidate.title ?? candidate.originalTitle ?? "未命名").font(.headline)
                                        if let year = candidate.year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
                                        if let original = candidate.originalTitle { Text(original).font(.caption).foregroundStyle(.secondary) }
                                        if let overview = candidate.overview { Text(overview).font(.caption).lineLimit(3) }
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(binding || searching)
                        }
                        if results.candidates.isEmpty { Text("没有找到候选，试试其它片名。") }
                    }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                Section { Text("本产品使用 TMDB API，但未获得 TMDB 认可或认证。").font(.caption).foregroundStyle(.secondary) }
            }
            .navigationTitle("手动匹配 TMDB")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() }.disabled(binding) } }
        }
        .interactiveDismissDisabled(binding)
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 600, minHeight: 500)
        #endif
    }

    private func search() async {
        guard !binding, let key = app.tmdb.rawAPIKey, app.activeFileSourceID == item.sourceId else { return }
        generation &+= 1
        let requestGeneration = generation
        let term = query
        searching = true; error = nil
        defer { if generation == requestGeneration { searching = false } }
        do {
            let result = try await app.fileLibrary.candidates(item: item, query: term, key: key, apiBase: app.fileLibraryAPIBase, language: app.tmdb.language)
            guard !Task.isCancelled, generation == requestGeneration, app.activeFileSourceID == item.sourceId else { return }
            results = result
        } catch { if !Task.isCancelled, generation == requestGeneration { self.error = error.localizedDescription } }
    }

    private func bind(_ candidate: OcpFileLibrary.MatchCandidate, version: String) async {
        guard !binding, app.activeFileSourceID == item.sourceId else { return }
        binding = true; error = nil
        defer { binding = false }
        do {
            try await app.fileLibrary.bind(item: item, inputVersion: version, tmdbID: candidate.id)
            dismiss()
        } catch { self.error = error.localizedDescription; results = nil }
    }
}

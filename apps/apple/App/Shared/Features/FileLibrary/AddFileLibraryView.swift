import OcPlayerCore
import SwiftUI
import UniformTypeIdentifiers

struct FileLibraryDraft: Identifiable {
    let id = UUID().uuidString
    let sourceID: String?
    init(sourceID: String? = nil) { self.sourceID = sourceID }
}

enum MediaLibrarySheet: Identifiable {
    case sources
    case add(FileLibraryDraft)
    var id: String {
        switch self { case .sources: "sources"; case let .add(draft): draft.id }
    }
}

struct AddFileLibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let draft: FileLibraryDraft
    @State private var keyInput = ""
    @State private var sourceName = "本地媒体库"
    @State private var name = "电影"
    @State private var type: OcpFileLibrary.LibraryType = .movies
    @State private var root: URL?
    @State private var subdirectory = ""
    @State private var selectingFolder = false
    @State private var isWorking = false
    @State private var verification: OcpFileLibrary.Validation?
    @State private var verifiedRevision: String?
    @State private var expiresAt: Date?
    @State private var error: String?

    private var source: OcpFileLibrary.Source? {
        app.fileLibrary.sources.first { $0.sourceId == draft.sourceID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("1. 验证 TMDB") {
                    SecureField("API Key 或 Read Access Token", text: $keyInput)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    if keyInput.isEmpty, app.tmdb.isConfigured {
                        Text("将验证已保存的凭据：\(app.tmdb.apiKeyDisplay)").font(.caption).foregroundStyle(.secondary)
                    }
                    Button(verification == nil ? "验证凭据" : "重新验证") { Task { await validate() } }
                        .disabled(isWorking || (keyInput.isEmpty && !app.tmdb.isConfigured))
                    if verification != nil { Label("TMDB 验证成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                    Text("文件夹媒体库共用这份 TMDB 凭据。首次添加前需要有效凭据；已有索引在清除凭据后仍可浏览和播放。")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("申请 TMDB API Key", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                }
                Section("2. 来源目录") {
                    if let source {
                        LabeledContent("来源", value: source.displayName)
                    } else {
                        TextField("来源名称", text: $sourceName)
                    }
                    Button(root == nil ? "选择文件夹…" : "重新选择文件夹…") { selectingFolder = true }
                        .disabled(isWorking || verification == nil)
                    if let root { Text(root.path).font(.caption).textSelection(.enabled) }
                    Text(source == nil ? "选择影片所在的根目录。一个来源内可以分别添加 Movies、TV 等分类目录。" : "为这个来源添加分类。选择原来的根目录，再填写分类的相对路径。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("3. 分类") {
                    Picker("内容类型", selection: $type) {
                        Text("电影").tag(OcpFileLibrary.LibraryType.movies)
                        Text("电视剧").tag(OcpFileLibrary.LibraryType.tvshows)
                    }
                    TextField("分类名称", text: $name)
                    TextField("分类目录（例如 Movies 或 TV，留空扫描根目录）", text: $subdirectory)
                        .autocorrectionDisabled()
                    Text("每个分类只选一种内容类型。电视剧按整剧、季、集浏览，特别篇保留为第 0 季。分类目录之间不能重叠。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                if isWorking { Section { ProgressView("正在处理…") } }
                Section {
                    Text("本产品使用 TMDB API，但未获得 TMDB 认可或认证。此版本先建立文件索引，在线刮削将在后续接入。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking)
            .navigationTitle("添加文件夹媒体库")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(isWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加并扫描") { Task { await create() } }
                        .disabled(isWorking || root == nil || verification == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .fileImporter(isPresented: $selectingFolder, allowedContentTypes: [.folder]) { result in
                do { root = try result.get(); error = nil }
                catch { self.error = error.localizedDescription }
            }
            .onChange(of: keyInput) { _, _ in verification = nil; verifiedRevision = nil }
            .onChange(of: type) { old, new in
                if name == (old == .movies ? "电影" : "电视剧") { name = new == .movies ? "电影" : "电视剧" }
            }
            .onChange(of: app.fileLibraryCredentialRevision) { _, _ in verification = nil; verifiedRevision = nil }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 620, idealHeight: 730)
        #endif
        .interactiveDismissDisabled(isWorking)
    }

    private func validate() async {
        isWorking = true; error = nil; verification = nil
        defer { isWorking = false }
        if !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            app.tmdb.setAPIKey(keyInput)
            keyInput = ""
        }
        guard let key = app.tmdb.rawAPIKey else { error = "请先填写 TMDB 凭据"; return }
        let revision = app.fileLibraryCredentialRevision
        let apiBase = app.fileLibraryAPIBase
        do {
            let receipt = try await app.fileLibrary.validate(key: key, apiBase: apiBase, draftID: draft.id)
            guard revision == app.fileLibraryCredentialRevision else { throw OcpCoreError(message: "TMDB 配置已变更，请重新验证") }
            verification = receipt; verifiedRevision = revision
            expiresAt = Date().addingTimeInterval(Double(receipt.expiresInSeconds))
        } catch { self.error = "TMDB 验证失败：\(error.localizedDescription)" }
    }

    private func create() async {
        guard let root, let verification, let revision = verifiedRevision else { return }
        guard revision == app.fileLibraryCredentialRevision, let expiresAt, expiresAt > Date() else {
            self.verification = nil; error = "验证已过期或配置已变更，请重新验证 TMDB"; return
        }
        isWorking = true; error = nil
        defer { isWorking = false }
        do {
            let result = try await app.fileLibrary.create(
                draftID: draft.id, verificationID: verification.verificationId, credentialRevision: revision,
                apiBase: app.fileLibraryAPIBase, source: source, root: root, subdirectory: subdirectory,
                sourceName: source?.displayName ?? sourceName, name: name, type: type)
            dismiss()
            await app.activateFileSource(result.library.sourceId)
        } catch { self.error = error.localizedDescription }
    }
}

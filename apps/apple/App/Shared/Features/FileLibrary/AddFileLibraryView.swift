import OcPlayerCore
import SwiftUI
import UniformTypeIdentifiers

struct FileLibraryDraft: Identifiable {
    let id = UUID().uuidString
    let sourceID: String?
    let connectionOnly: Bool
    init(sourceID: String? = nil, connectionOnly: Bool = false) { self.sourceID = sourceID; self.connectionOnly = connectionOnly }
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
    @State private var kind = "localFolder"
    @State private var webDAVURL = ""
    @State private var authType = "basic"
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var remoteAccess: OcpFileLibrary.Access?
    @State private var remoteDirectory: OcpFileLibrary.RemoteDirectory?
    @State private var accessRef = UUID().uuidString
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
                if source == nil {
                    Section("来源类型") {
                        Picker("类型", selection: $kind) {
                            Text("本地文件夹").tag("localFolder")
                            if app.fileLibrary.capabilities?.sourceKinds.contains("webdav") == true { Text("WebDAV").tag("webdav") }
                        }
                    }
                }
                if !draft.connectionOnly {
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
                    Text("文件媒体库共用这份 TMDB 凭据。首次添加前需要有效凭据；已有索引在清除凭据后仍可浏览和播放。")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("申请 TMDB API Key", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                }
                }
                Section(draft.connectionOnly ? "WebDAV 连接" : "2. 来源目录") {
                    if let source {
                        LabeledContent("来源", value: source.displayName)
                    } else {
                        TextField("来源名称", text: $sourceName)
                    }
                    if kind == "webdav" { webDAVConnection }
                    else {
                    Button(root == nil ? "选择文件夹…" : "重新选择文件夹…") { selectingFolder = true }
                        .disabled(isWorking || verification == nil)
                    if let root { Text(root.path).font(.caption).textSelection(.enabled) }
                    Text(source == nil ? "选择影片所在的根目录。一个来源内可以分别添加 Movies、TV 等分类目录。" : "为这个来源添加分类。选择原来的根目录，再填写分类的相对路径。")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if kind == "webdav", !draft.connectionOnly, let directory = remoteDirectory {
                    Section("选择分类目录") { remoteFolders(directory) }
                }
                if !draft.connectionOnly {
                Section("3. 分类") {
                    Picker("内容类型", selection: $type) {
                        Text("电影").tag(OcpFileLibrary.LibraryType.movies)
                        Text("电视剧").tag(OcpFileLibrary.LibraryType.tvshows)
                    }
                    TextField("分类名称", text: $name)
                    if kind == "localFolder" {
                        TextField("分类目录（例如 Movies 或 TV，留空扫描根目录）", text: $subdirectory).autocorrectionDisabled()
                    }
                    Text("每个分类只选一种内容类型。电视剧按整剧、季、集浏览，特别篇保留为第 0 季。分类目录之间不能重叠。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
                if isWorking { Section { ProgressView("正在处理…") } }
                Section {
                    Text("目录扫描后会自动从 TMDB 获取电影和电视剧元数据。未匹配的文件可在详情页手动选择。本产品使用 TMDB API，但未获得 TMDB 认可或认证。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(isWorking)
            .navigationTitle(draft.connectionOnly ? "更新 WebDAV 连接" : "添加文件媒体库")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(isWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.connectionOnly ? "保存连接" : "添加并扫描") { Task { await create() } }
                        .disabled(isWorking || (!draft.connectionOnly && (verification == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)) || (kind == "localFolder" ? root == nil : remoteAccess == nil))
                }
            }
            .fileImporter(isPresented: $selectingFolder, allowedContentTypes: [.folder]) { result in
                do { root = try result.get(); error = nil }
                catch { self.error = error.localizedDescription }
            }
            .task {
                if let source {
                    kind = source.kind; accessRef = source.accessRef ?? source.sourceId
                    if source.kind == "webdav" {
                        webDAVURL = source.rootPath
                        if let credential = app.fileLibrary.storedWebDAVCredential(for: source) {
                            authType = credential.type; username = credential.username ?? ""; password = credential.password ?? ""; token = credential.token ?? ""
                        }
                    }
                }
            }
            .onChange(of: kind) { _, new in
                root = nil; remoteAccess = nil; remoteDirectory = nil
                if source == nil { sourceName = new == "webdav" ? "WebDAV 媒体库" : "本地媒体库" }
            }
            .onChange(of: webDAVURL) { _, _ in resetRemoteAccess() }
            .onChange(of: credential) { _, _ in resetRemoteAccess() }
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

    private var credential: OcpFileLibrary.WebDAVCredential {
        switch authType {
        case "none": .none
        case "bearer": .bearer(token: token)
        default: .basic(username: username, password: password)
        }
    }
    private func resetRemoteAccess() { remoteAccess = nil; remoteDirectory = nil }
    @ViewBuilder private var webDAVConnection: some View {
        TextField("目录地址，例如 https://nas.example/dav/", text: $webDAVURL)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .disabled(source != nil)
        Picker("鉴权", selection: $authType) {
            Text("用户名和密码").tag("basic")
            Text("Bearer Token").tag("bearer")
            Text("无需鉴权").tag("none")
        }
        if authType == "basic" {
            TextField("用户名", text: $username).autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            SecureField("密码", text: $password)
        } else if authType == "bearer" { SecureField("Access Token", text: $token) }
        Button("验证连接并读取目录") { Task { await connectWebDAV() } }
            .disabled(isWorking || (!draft.connectionOnly && verification == nil) || webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if remoteAccess != nil { Label("WebDAV 连接成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        Text("填写 WebDAV 最终目录地址。更新已有来源时保留原地址，目录和观看进度仍属于原来源。")
            .font(.caption).foregroundStyle(.secondary)
    }
    @ViewBuilder private func remoteFolders(_ directory: OcpFileLibrary.RemoteDirectory) -> some View {
        Text("当前扫描目录：\(directory.relativePath.isEmpty ? "/" : directory.relativePath)")
            .font(.caption).textSelection(.enabled)
        if !directory.relativePath.isEmpty {
            Button("上一级") {
                let parent = directory.relativePath.split(separator: "/").dropLast().joined(separator: "/")
                Task { await browseWebDAV(parent) }
            }
        }
        ForEach(directory.entries.filter(\.isDirectory)) { entry in
            Button { Task { await browseWebDAV(entry.relativePath) } } label: {
                Label(entry.relativePath.split(separator: "/").last.map(String.init) ?? entry.relativePath, systemImage: "folder")
            }
        }
        Text("此目录下显示 \(directory.entries.filter { !$0.isDirectory }.count) 个文件。点击文件夹进入，添加时扫描当前目录及其子目录。")
            .font(.caption).foregroundStyle(.secondary)
    }
    private func connectWebDAV() async {
        isWorking = true; error = nil; resetRemoteAccess()
        defer { isWorking = false }
        do {
            let access = try await app.fileLibrary.prepareWebDAV(rootURL: webDAVURL.trimmingCharacters(in: .whitespacesAndNewlines), credential: credential, accessRef: accessRef)
            let directory = try await app.fileLibrary.browseWebDAV(accessID: access.accessId, relativePath: "")
            remoteAccess = access; remoteDirectory = directory
        } catch { self.error = error.localizedDescription }
    }
    private func browseWebDAV(_ relativePath: String) async {
        guard let access = remoteAccess else { return }
        isWorking = true; error = nil
        defer { isWorking = false }
        do { remoteDirectory = try await app.fileLibrary.browseWebDAV(accessID: access.accessId, relativePath: relativePath) }
        catch { self.error = error.localizedDescription }
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
            let receipt = try await app.fileLibrary.validate(key: key, apiBase: apiBase, draftID: draft.id, language: app.tmdb.language)
            guard revision == app.fileLibraryCredentialRevision else { throw OcpCoreError(message: "TMDB 配置已变更，请重新验证") }
            verification = receipt; verifiedRevision = revision
            expiresAt = Date().addingTimeInterval(Double(receipt.expiresInSeconds))
        } catch { self.error = "TMDB 验证失败：\(error.localizedDescription)" }
    }

    private func create() async {
        if draft.connectionOnly {
            guard let source, remoteAccess != nil else { return }
            isWorking = true; error = nil
            defer { isWorking = false }
            do { try await app.fileLibrary.restoreWebDAV(source: source, credential: credential); dismiss() }
            catch { self.error = error.localizedDescription }
            return
        }
        guard let verification, let revision = verifiedRevision else { return }
        guard revision == app.fileLibraryCredentialRevision, let expiresAt, expiresAt > Date() else {
            self.verification = nil; error = "验证已过期或配置已变更，请重新验证 TMDB"; return
        }
        isWorking = true; error = nil
        defer { isWorking = false }
        do {
            let result: OcpFileLibrary.Creation
            if kind == "webdav" {
                guard let access = remoteAccess, let category = remoteDirectory else { return }
                result = try await app.fileLibrary.createWebDAV(
                    draftID: draft.id, verificationID: verification.verificationId, credentialRevision: revision,
                    apiBase: app.fileLibraryAPIBase, source: source, access: access, category: category,
                    credential: credential, accessRef: accessRef, sourceName: source?.displayName ?? sourceName,
                    name: name, type: type)
            } else {
                guard let root else { return }
                result = try await app.fileLibrary.create(
                draftID: draft.id, verificationID: verification.verificationId, credentialRevision: revision,
                apiBase: app.fileLibraryAPIBase, source: source, root: root, subdirectory: subdirectory,
                sourceName: source?.displayName ?? sourceName, name: name, type: type)
            }
            dismiss()
            await app.activateFileSource(result.library.sourceId)
        } catch { self.error = error.localizedDescription }
    }
}

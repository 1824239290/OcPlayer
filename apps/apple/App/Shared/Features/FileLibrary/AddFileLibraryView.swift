import OcPlayerCore
import SwiftUI
import UniformTypeIdentifiers

struct FileLibraryDraft: Identifiable {
    let id = UUID().uuidString
    let sourceID: String?
    let targetLibraryID: String?
    let connectionOnly: Bool
    let localOnly: Bool
    let remoteOnly: Bool
    init(
        sourceID: String? = nil,
        targetLibraryID: String? = nil,
        connectionOnly: Bool = false,
        localOnly: Bool = false,
        remoteOnly: Bool = false
    ) {
        self.sourceID = sourceID
        self.targetLibraryID = targetLibraryID
        self.connectionOnly = connectionOnly
        self.localOnly = localOnly
        self.remoteOnly = remoteOnly
    }
}

enum MediaLibrarySheet: Identifiable {
    case sources
    case add(FileLibraryDraft)
    case manage(sourceID: String)
    var id: String {
        switch self {
        case .sources: "sources"
        case let .add(draft): draft.id
        case let .manage(sourceID): "manage:\(sourceID)"
        }
    }
}

private struct PendingCategoryDraft: Identifiable {
    let id = UUID().uuidString
    var targetLibraryID: String?
    var name: String
    var type: OcpFileLibrary.LibraryType
    var localFolders: [URL] = []
    var remoteFolders: [OcpFileLibrary.RemoteDirectory] = []

    var folderCount: Int { localFolders.count + remoteFolders.count }
}

struct AddFileLibraryView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let draft: FileLibraryDraft

    @State private var kind = "localFolder"
    @State private var remoteURL = ""
    @State private var authType = "basic"
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var domain = ""
    @State private var smbGuest = false
    @State private var requireSigning = true
    @State private var requireEncryption = false
    @State private var remoteAccess: OcpFileLibrary.Access?
    @State private var remoteDirectory: OcpFileLibrary.RemoteDirectory?
    @State private var accessRef = UUID().uuidString
    @State private var keyInput = ""
    @State private var sourceName = "本地媒体库"

    @State private var existingLibraries: [OcpFileLibrary.Library] = []
    @State private var pendingCategories: [PendingCategoryDraft] = []
    @State private var folderPickerTargetCategoryID: String?
    @State private var selectingFolders = false
    @State private var remoteAddTargetCategoryID: String?

    @State private var isWorking = false
    @State private var verification: OcpFileLibrary.Validation?
    @State private var verifiedRevision: String?
    @State private var expiresAt: Date?
    @State private var error: String?

    private var explicitSource: OcpFileLibrary.Source? {
        app.fileLibrary.sources.first { $0.sourceId == draft.sourceID }
    }

    /// 本地媒体库固定全局唯一：无论从哪个入口以 `localFolder` 添加，若已存在本地来源则始终复用它，不再新建第二个本地库。
    private var source: OcpFileLibrary.Source? {
        if let explicitSource { return explicitSource }
        if kind == "localFolder" { return app.fileLibrary.localSource }
        return nil
    }

    private var lockedTargetLibrary: OcpFileLibrary.Library? {
        guard let targetID = draft.targetLibraryID else { return nil }
        return existingLibraries.first { $0.libraryId == targetID }
    }

    /// 仅向已有分类追加文件夹时无需重新验证 TMDB；创建新来源或新分类时必须验证 TMDB。
    private var needsNewLibraryCreation: Bool {
        if draft.connectionOnly { return false }
        if lockedTargetLibrary != nil { return false }
        if source == nil { return true }
        if pendingCategories.isEmpty { return true }
        return pendingCategories.contains { $0.targetLibraryID == nil }
    }

    private var overlapConflictMessage: String? {
        var seen: [(label: String, path: String)] = []
        for lib in existingLibraries {
            for root in lib.allRoots {
                seen.append(("已有「\(lib.name)」", root.rootPath))
            }
        }
        for category in pendingCategories {
            let paths: [String] = kind == "localFolder"
                ? category.localFolders.map { Self.normalizedLocalPath($0) }
                : category.remoteFolders.map(\.rootPath)
            for path in paths {
                for existing in seen where Self.pathsOverlap(path, existing.path, isLocal: kind == "localFolder") {
                    return "目录重叠：「\(category.name)」的 \(path) 与 \(existing.label)（\(existing.path)）存在包含或重复关系，请移除其中一个。"
                }
                seen.append(("待添加「\(category.name)」", path))
            }
        }
        return nil
    }

    private var hasValidPendingFolders: Bool {
        guard !pendingCategories.isEmpty else { return false }
        return pendingCategories.allSatisfy { category in
            let trimmedName = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmedName.isEmpty && category.folderCount > 0
        }
    }

    private var canSubmit: Bool {
        if isWorking { return false }
        if draft.connectionOnly { return remoteAccess != nil }
        if needsNewLibraryCreation && verification == nil { return false }
        if kind != "localFolder" && remoteAccess == nil { return false }
        if !hasValidPendingFolders { return false }
        if overlapConflictMessage != nil { return false }
        return true
    }

    private var navigationTitleText: String {
        if draft.connectionOnly { return "更新远程连接" }
        if let target = lockedTargetLibrary { return "为「\(target.name)」添加文件夹" }
        if source != nil { return "添加分类或文件夹" }
        if draft.remoteOnly { return "添加远程文件来源" }
        if draft.localOnly || kind == "localFolder" { return "设置本地媒体库" }
        return "添加文件媒体库"
    }

    var body: some View {
        NavigationStack {
            Form {
                if explicitSource == nil && !draft.localOnly {
                    Section("来源类型") {
                        Picker("类型", selection: $kind) {
                            if !draft.remoteOnly && app.fileLibrary.localSource == nil {
                                Text("本地媒体库").tag("localFolder")
                            }
                            if app.fileLibrary.capabilities?.sourceKinds.contains("webdav") == true { Text("WebDAV").tag("webdav") }
                            if app.fileLibrary.capabilities?.sourceKinds.contains("smb") == true { Text("SMB").tag("smb") }
                        }
                    }
                }

                if needsNewLibraryCreation {
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
                        if verification != nil {
                            Label("TMDB 验证成功（本次添加的所有分类共用此验证）", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Text("文件媒体库共用这份 TMDB 凭据。首次添加前需要有效凭据；已有索引在清除凭据后仍可浏览和播放。")
                            .font(.caption).foregroundStyle(.secondary)
                        Link("申请 TMDB API Key", destination: URL(string: "https://www.themoviedb.org/settings/api")!)
                    }
                }

                Section(draft.connectionOnly ? "远程连接" : (needsNewLibraryCreation ? "2. 来源" : "来源")) {
                    if kind == "localFolder" {
                        LabeledContent("来源", value: "本地媒体库")
                        if let target = lockedTargetLibrary {
                            LabeledContent("目标分类", value: "\(target.name)（\(target.type == .movies ? "电影" : "电视剧")）")
                        }
                    } else if let source {
                        LabeledContent("来源", value: source.displayName)
                        if let target = lockedTargetLibrary {
                            LabeledContent("目标分类", value: "\(target.name)（\(target.type == .movies ? "电影" : "电视剧")）")
                        }
                    } else {
                        TextField("来源名称", text: $sourceName)
                    }
                    if kind == "webdav" {
                        webDAVConnection
                    } else if kind == "smb" {
                        smbConnection
                    } else {
                        Text("本地媒体库全局唯一，支持跨磁盘、跨目录一次选择或分次追加多个文件夹；不同文件夹既可以分别作为独立分类，也可以合并到同一个分类中。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if kind != "localFolder", !draft.connectionOnly, let directory = remoteDirectory {
                    Section("浏览远程目录") { remoteFolders(directory) }
                }

                if !draft.connectionOnly {
                    Section(needsNewLibraryCreation ? "3. 分类与文件夹" : "待添加文件夹") {
                        pendingCategoriesSection
                    }
                }

                if let conflict = overlapConflictMessage {
                    Section {
                        Label(conflict, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
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
            .navigationTitle(navigationTitleText)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(isWorking) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.connectionOnly ? "保存连接" : "添加并扫描") { Task { await create() } }
                        .disabled(!canSubmit)
                }
            }
            .fileImporter(
                isPresented: $selectingFolders,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: true
            ) { result in
                handlePickedLocalFolders(result)
            }
            .task {
                if explicitSource == nil {
                    if draft.remoteOnly || (!draft.localOnly && app.fileLibrary.localSource != nil) {
                        if app.fileLibrary.capabilities?.sourceKinds.contains("webdav") == true {
                            kind = "webdav"
                            sourceName = "WebDAV 媒体库"
                        } else if app.fileLibrary.capabilities?.sourceKinds.contains("smb") == true {
                            kind = "smb"
                            sourceName = "SMB 媒体库"
                        }
                    } else {
                        kind = "localFolder"
                        sourceName = "本地媒体库"
                    }
                }
                if let source {
                    kind = source.kind
                    accessRef = source.accessRef ?? source.sourceId
                    existingLibraries = (try? await app.fileLibrary.libraries(sourceID: source.sourceId)) ?? []
                    if let targetID = draft.targetLibraryID,
                       let target = existingLibraries.first(where: { $0.libraryId == targetID }),
                       pendingCategories.isEmpty {
                        let initial = PendingCategoryDraft(targetLibraryID: target.libraryId, name: target.name, type: target.type)
                        pendingCategories = [initial]
                        remoteAddTargetCategoryID = initial.id
                    }
                    if source.kind == "webdav" {
                        remoteURL = source.rootPath
                        if let credential = app.fileLibrary.storedWebDAVCredential(for: source) {
                            authType = credential.type; username = credential.username ?? ""; password = credential.password ?? ""; token = credential.token ?? ""
                        }
                    } else if source.kind == "smb" {
                        remoteURL = source.rootPath
                        if let credential = app.fileLibrary.storedSMBCredential(for: source) {
                            smbGuest = credential.type == "guest"; username = credential.username ?? ""; password = credential.password ?? ""; domain = credential.domain ?? ""
                            requireSigning = credential.requireSigning ?? true; requireEncryption = credential.requireEncryption ?? false
                        }
                    }
                }
            }
            .onChange(of: kind) { _, new in
                remoteAccess = nil; remoteDirectory = nil
                pendingCategories = []
                remoteAddTargetCategoryID = nil
                if explicitSource == nil {
                    sourceName = new == "webdav" ? "WebDAV 媒体库" : (new == "smb" ? "SMB 媒体库" : "本地媒体库")
                    if new == "localFolder", let local = app.fileLibrary.localSource {
                        Task { existingLibraries = (try? await app.fileLibrary.libraries(sourceID: local.sourceId)) ?? [] }
                    } else {
                        existingLibraries = []
                    }
                }
            }
            .onChange(of: remoteURL) { _, _ in resetRemoteAccess() }
            .onChange(of: credential) { _, _ in resetRemoteAccess() }
            .onChange(of: smbCredential) { _, _ in resetRemoteAccess() }
            .onChange(of: keyInput) { _, _ in verification = nil; verifiedRevision = nil }
            .onChange(of: app.fileLibraryCredentialRevision) { _, _ in verification = nil; verifiedRevision = nil }
        }
        #if os(macOS)
        .frame(minWidth: 600, idealWidth: 680, minHeight: 640, idealHeight: 760)
        #endif
        .interactiveDismissDisabled(isWorking)
    }

    @ViewBuilder
    private var pendingCategoriesSection: some View {
        if kind == "localFolder" {
            HStack(spacing: 12) {
                if let target = lockedTargetLibrary, let draftID = pendingCategories.first?.id {
                    Button {
                        folderPickerTargetCategoryID = draftID
                        selectingFolders = true
                    } label: {
                        Label("选择要加入「\(target.name)」的文件夹…", systemImage: "folder.badge.plus")
                    }
                } else {
                    Button {
                        folderPickerTargetCategoryID = nil
                        selectingFolders = true
                    } label: {
                        Label("添加文件夹（可多选）…", systemImage: "folder.badge.plus")
                    }
                    .disabled(isWorking || (needsNewLibraryCreation && verification == nil))
                }
            }
        }

        if pendingCategories.isEmpty {
            Text(kind == "localFolder"
                 ? "点击上方按钮选择一个或多个文件夹（支持跨磁盘）。也可先选一个，再给同一分类追加更多文件夹。"
                 : "先在上方验证远程连接并浏览到目标目录，再点击「加入待添加列表」。可连续添加多个目录。")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach($pendingCategories) { $category in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        if let existingID = category.targetLibraryID,
                           let existing = existingLibraries.first(where: { $0.libraryId == existingID }) {
                            Label("合并到已有分类：\(existing.name)", systemImage: existing.type == .movies ? "film" : "tv")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if lockedTargetLibrary == nil {
                                Button("改为新建分类") {
                                    category.targetLibraryID = nil
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                        } else {
                            TextField("分类名称", text: $category.name)
                                .textFieldStyle(.roundedBorder)
                            Picker("", selection: $category.type) {
                                Text("电影").tag(OcpFileLibrary.LibraryType.movies)
                                Text("电视剧").tag(OcpFileLibrary.LibraryType.tvshows)
                            }
                            .labelsHidden()
                            .frame(width: 96)
                        }

                        if lockedTargetLibrary == nil {
                            Button(role: .destructive) {
                                removeCategory(category.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("移除此分类")
                        }
                    }

                    if lockedTargetLibrary == nil && !existingLibraries.isEmpty && category.targetLibraryID == nil {
                        Menu("改为合并到已有分类…") {
                            ForEach(existingLibraries) { lib in
                                Button("\(lib.name)（\(lib.type == .movies ? "电影" : "电视剧")）") {
                                    category.targetLibraryID = lib.libraryId
                                    category.name = lib.name
                                    category.type = lib.type
                                }
                            }
                        }
                        .font(.caption)
                    }

                    if kind == "localFolder" {
                        ForEach(category.localFolders, id: \.path) { folder in
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                Text(folder.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    removeLocalFolder(folder, from: category.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("移除此文件夹")
                            }
                        }
                        if lockedTargetLibrary == nil {
                            Button {
                                folderPickerTargetCategoryID = category.id
                                selectingFolders = true
                            } label: {
                                Label("追加更多文件夹到此分类（合并显示）…", systemImage: "plus.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                        }
                    } else {
                        ForEach(category.remoteFolders, id: \.rootPath) { folder in
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                Text(folder.relativePath.isEmpty ? folder.rootPath : "/\(folder.relativePath)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                                Spacer()
                                Button {
                                    removeRemoteFolder(folder.rootPath, from: category.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("移除此远程目录")
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }

        if lockedTargetLibrary == nil {
            Text("同一分类可包含多个文件夹（如不同硬盘的电影）；同名同类型的分类项在提交时会自动合并为一个分类。分类目录之间不能互相包含或重复。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func handlePickedLocalFolders(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            error = nil
            if let targetID = folderPickerTargetCategoryID,
               let index = pendingCategories.firstIndex(where: { $0.id == targetID }) {
                for url in urls {
                    if !pendingCategories[index].localFolders.contains(where: { $0.path == url.path }) {
                        pendingCategories[index].localFolders.append(url)
                    }
                }
            } else {
                for url in urls {
                    let folderName = url.lastPathComponent.isEmpty ? "媒体库" : url.lastPathComponent
                    let guessed = Self.guessLibraryType(from: folderName)
                    pendingCategories.append(
                        PendingCategoryDraft(
                            targetLibraryID: nil,
                            name: folderName,
                            type: guessed,
                            localFolders: [url]
                        )
                    )
                }
            }
            folderPickerTargetCategoryID = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeCategory(_ id: String) {
        pendingCategories.removeAll { $0.id == id }
        if remoteAddTargetCategoryID == id { remoteAddTargetCategoryID = nil }
    }

    private func removeLocalFolder(_ folder: URL, from categoryID: String) {
        guard let index = pendingCategories.firstIndex(where: { $0.id == categoryID }) else { return }
        pendingCategories[index].localFolders.removeAll { $0.path == folder.path }
        if pendingCategories[index].localFolders.isEmpty && lockedTargetLibrary == nil {
            pendingCategories.remove(at: index)
        }
    }

    private func removeRemoteFolder(_ rootPath: String, from categoryID: String) {
        guard let index = pendingCategories.firstIndex(where: { $0.id == categoryID }) else { return }
        pendingCategories[index].remoteFolders.removeAll { $0.rootPath == rootPath }
        if pendingCategories[index].remoteFolders.isEmpty && lockedTargetLibrary == nil {
            pendingCategories.remove(at: index)
            if remoteAddTargetCategoryID == categoryID { remoteAddTargetCategoryID = nil }
        }
    }

    private var credential: OcpFileLibrary.WebDAVCredential {
        switch authType {
        case "none": .none
        case "bearer": .bearer(token: token)
        default: .basic(username: username, password: password)
        }
    }

    private func resetRemoteAccess() {
        remoteAccess = nil
        remoteDirectory = nil
        if kind != "localFolder" {
            for index in pendingCategories.indices {
                pendingCategories[index].remoteFolders.removeAll()
            }
            if lockedTargetLibrary == nil {
                pendingCategories.removeAll()
                remoteAddTargetCategoryID = nil
            }
        }
    }

    private var smbCredential: OcpFileLibrary.SMBCredential {
        smbGuest ? .guest : .password(username: username, password: password, domain: domain, requireSigning: requireSigning, requireEncryption: requireEncryption)
    }

    @ViewBuilder private var smbConnection: some View {
        TextField("共享地址，例如 smb://nas.example/Media/", text: $remoteURL)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .disabled(source != nil)
        Toggle("以访客身份连接", isOn: $smbGuest)
        if !smbGuest {
            TextField("用户名", text: $username).autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
            SecureField("密码", text: $password)
            TextField("域（可留空）", text: $domain).autocorrectionDisabled()
            Toggle("要求连接签名", isOn: $requireSigning)
            Toggle("要求 SMB3 加密", isOn: $requireEncryption)
        }
        Button("验证连接并读取目录") { Task { await connectRemote() } }
            .disabled(isWorking || (needsNewLibraryCreation && verification == nil) || remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if remoteAccess != nil { Label("SMB 连接成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        Text("填写共享名称后逐级浏览，可将多个电影或电视剧目录一并加入待添加列表。服务器需要支持 SMB2 或 SMB3。")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var webDAVConnection: some View {
        TextField("目录地址，例如 https://nas.example/dav/", text: $remoteURL)
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
        Button("验证连接并读取目录") { Task { await connectRemote() } }
            .disabled(isWorking || (needsNewLibraryCreation && verification == nil) || remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if remoteAccess != nil { Label("WebDAV 连接成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
        Text("填写 WebDAV 根目录地址后可浏览并将多个子目录加入待添加列表。")
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func remoteFolders(_ directory: OcpFileLibrary.RemoteDirectory) -> some View {
        Text("当前浏览目录：\(directory.relativePath.isEmpty ? "/" : "/\(directory.relativePath)")")
            .font(.caption).textSelection(.enabled)
        HStack(spacing: 10) {
            if !directory.relativePath.isEmpty {
                Button("上一级") {
                    let parent = directory.relativePath.split(separator: "/").dropLast().joined(separator: "/")
                    Task { await browseRemote(parent) }
                }
            }
            if let locked = lockedTargetLibrary, let draftID = pendingCategories.first?.id {
                Button {
                    addRemoteDirectory(directory, intoCategoryID: draftID)
                } label: {
                    Label("加入「\(locked.name)」", systemImage: "plus.circle.fill")
                }
            } else {
                Button {
                    addRemoteDirectory(directory, intoCategoryID: nil)
                } label: {
                    Label("作为新分类加入列表", systemImage: "folder.badge.plus")
                }
                if !pendingCategories.isEmpty {
                    Menu("合并到待添加分类…") {
                        ForEach(pendingCategories) { cat in
                            Button(cat.name) {
                                addRemoteDirectory(directory, intoCategoryID: cat.id)
                            }
                        }
                    }
                }
            }
        }
        ForEach(directory.entries.filter(\.isDirectory)) { entry in
            Button { Task { await browseRemote(entry.relativePath) } } label: {
                Label(entry.relativePath.split(separator: "/").last.map(String.init) ?? entry.relativePath, systemImage: "folder")
            }
        }
        Text("此目录下有 \(directory.entries.filter { !$0.isDirectory }.count) 个文件。点击文件夹进入，可连续将多个目录加入下方列表。")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func addRemoteDirectory(_ directory: OcpFileLibrary.RemoteDirectory, intoCategoryID targetID: String?) {
        error = nil
        if let targetID, let index = pendingCategories.firstIndex(where: { $0.id == targetID }) {
            if !pendingCategories[index].remoteFolders.contains(where: { $0.rootPath == directory.rootPath }) {
                pendingCategories[index].remoteFolders.append(directory)
            }
            return
        }
        let defaultName = directory.relativePath.split(separator: "/").last.map(String.init)
            ?? (source?.displayName ?? "媒体库")
        let guessed = Self.guessLibraryType(from: defaultName)
        pendingCategories.append(
            PendingCategoryDraft(
                targetLibraryID: nil,
                name: defaultName,
                type: guessed,
                remoteFolders: [directory]
            )
        )
    }

    private func connectRemote() async {
        isWorking = true; error = nil; resetRemoteAccess()
        defer { isWorking = false }
        do {
            let address = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let access = kind == "smb"
                ? try await app.fileLibrary.prepareSMB(rootURL: address, credential: smbCredential, accessRef: accessRef)
                : try await app.fileLibrary.prepareWebDAV(rootURL: address, credential: credential, accessRef: accessRef)
            let directory = kind == "smb"
                ? try await app.fileLibrary.browseSMB(accessID: access.accessId, relativePath: "")
                : try await app.fileLibrary.browseWebDAV(accessID: access.accessId, relativePath: "")
            remoteAccess = access; remoteDirectory = directory
        } catch { self.error = error.localizedDescription }
    }

    private func browseRemote(_ relativePath: String) async {
        guard let access = remoteAccess else { return }
        isWorking = true; error = nil
        defer { isWorking = false }
        do {
            remoteDirectory = kind == "smb"
                ? try await app.fileLibrary.browseSMB(accessID: access.accessId, relativePath: relativePath)
                : try await app.fileLibrary.browseWebDAV(accessID: access.accessId, relativePath: relativePath)
        } catch { self.error = error.localizedDescription }
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
            do {
                if kind == "smb" { try await app.fileLibrary.restoreSMB(source: source, credential: smbCredential) }
                else { try await app.fileLibrary.restoreWebDAV(source: source, credential: credential) }
                dismiss()
            } catch { self.error = error.localizedDescription }
            return
        }

        if needsNewLibraryCreation {
            guard verification != nil, let revision = verifiedRevision,
                  revision == app.fileLibraryCredentialRevision,
                  let expiresAt, expiresAt > Date() else {
                self.verification = nil
                error = "验证已过期或配置已变更，请重新验证 TMDB"
                return
            }
        }

        isWorking = true; error = nil
        defer { isWorking = false }

        do {
            let mergedCategories = Self.coalescePendingCategories(pendingCategories)
            var activeSource = source
            var finalSourceID = source?.sourceId
            var newCategoryIndex = 0

            for category in mergedCategories {
                let categoryName = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let existingLibraryID = category.targetLibraryID, let currentSource = activeSource {
                    if kind == "localFolder" {
                        for folder in category.localFolders {
                            _ = try await app.fileLibrary.addLocalRoot(
                                sourceID: currentSource.sourceId,
                                libraryID: existingLibraryID,
                                folder: folder
                            )
                        }
                    } else if let access = remoteAccess {
                        for remoteFolder in category.remoteFolders {
                            _ = try await app.fileLibrary.addRemoteRoot(
                                source: currentSource,
                                libraryID: existingLibraryID,
                                access: access,
                                category: remoteFolder,
                                webDAVCredential: kind == "webdav" ? credential : nil,
                                smbCredential: kind == "smb" ? smbCredential : nil
                            )
                        }
                    }
                    finalSourceID = currentSource.sourceId
                    continue
                }

                guard let verification, let revision = verifiedRevision else {
                    throw OcpCoreError(message: "请先验证 TMDB 凭据")
                }
                let batchDraftID = "\(draft.id):\(newCategoryIndex)"
                newCategoryIndex += 1

                if kind == "smb" {
                    guard let access = remoteAccess, let first = category.remoteFolders.first else { continue }
                    let created = try await app.fileLibrary.createSMB(
                        draftID: batchDraftID,
                        verificationID: verification.verificationId,
                        credentialRevision: revision,
                        apiBase: app.fileLibraryAPIBase,
                        source: activeSource,
                        access: access,
                        category: first,
                        credential: smbCredential,
                        accessRef: accessRef,
                        sourceName: activeSource?.displayName ?? sourceName,
                        name: categoryName,
                        type: category.type
                    )
                    finalSourceID = created.library.sourceId
                    activeSource = app.fileLibrary.sources.first { $0.sourceId == created.library.sourceId }
                    if let currentSource = activeSource {
                        for extra in category.remoteFolders.dropFirst() {
                            _ = try await app.fileLibrary.addRemoteRoot(
                                source: currentSource,
                                libraryID: created.library.libraryId,
                                access: access,
                                category: extra,
                                smbCredential: smbCredential
                            )
                        }
                    }
                } else if kind == "webdav" {
                    guard let access = remoteAccess, let first = category.remoteFolders.first else { continue }
                    let created = try await app.fileLibrary.createWebDAV(
                        draftID: batchDraftID,
                        verificationID: verification.verificationId,
                        credentialRevision: revision,
                        apiBase: app.fileLibraryAPIBase,
                        source: activeSource,
                        access: access,
                        category: first,
                        credential: credential,
                        accessRef: accessRef,
                        sourceName: activeSource?.displayName ?? sourceName,
                        name: categoryName,
                        type: category.type
                    )
                    finalSourceID = created.library.sourceId
                    activeSource = app.fileLibrary.sources.first { $0.sourceId == created.library.sourceId }
                    if let currentSource = activeSource {
                        for extra in category.remoteFolders.dropFirst() {
                            _ = try await app.fileLibrary.addRemoteRoot(
                                source: currentSource,
                                libraryID: created.library.libraryId,
                                access: access,
                                category: extra,
                                webDAVCredential: credential
                            )
                        }
                    }
                } else {
                    guard let first = category.localFolders.first else { continue }
                    let created = try await app.fileLibrary.create(
                        draftID: batchDraftID,
                        verificationID: verification.verificationId,
                        credentialRevision: revision,
                        apiBase: app.fileLibraryAPIBase,
                        source: activeSource,
                        root: first,
                        subdirectory: "",
                        sourceName: activeSource?.displayName ?? "本地媒体库",
                        name: categoryName,
                        type: category.type
                    )
                    finalSourceID = created.library.sourceId
                    activeSource = app.fileLibrary.sources.first { $0.sourceId == created.library.sourceId }
                    for extra in category.localFolders.dropFirst() {
                        _ = try await app.fileLibrary.addLocalRoot(
                            sourceID: created.library.sourceId,
                            libraryID: created.library.libraryId,
                            folder: extra
                        )
                    }
                }
            }

            dismiss()
            if let finalSourceID {
                await app.activateFileSource(finalSourceID)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 合并同名同类型（或指向同一已有分类）的待添加行，使同分类多文件夹自动归并。
    private static func coalescePendingCategories(_ items: [PendingCategoryDraft]) -> [PendingCategoryDraft] {
        var result: [PendingCategoryDraft] = []
        for item in items {
            let trimmed = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let targetID = item.targetLibraryID,
               let index = result.firstIndex(where: { $0.targetLibraryID == targetID }) {
                for folder in item.localFolders where !result[index].localFolders.contains(where: { $0.path == folder.path }) {
                    result[index].localFolders.append(folder)
                }
                for folder in item.remoteFolders where !result[index].remoteFolders.contains(where: { $0.rootPath == folder.rootPath }) {
                    result[index].remoteFolders.append(folder)
                }
                continue
            }
            if item.targetLibraryID == nil,
               let index = result.firstIndex(where: {
                   $0.targetLibraryID == nil
                       && $0.type == item.type
                       && $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmed) == .orderedSame
               }) {
                for folder in item.localFolders where !result[index].localFolders.contains(where: { $0.path == folder.path }) {
                    result[index].localFolders.append(folder)
                }
                for folder in item.remoteFolders where !result[index].remoteFolders.contains(where: { $0.rootPath == folder.rootPath }) {
                    result[index].remoteFolders.append(folder)
                }
                continue
            }
            result.append(item)
        }
        return result
    }

    private static func guessLibraryType(from folderName: String) -> OcpFileLibrary.LibraryType {
        let lower = folderName.lowercased()
        let tvHints = ["tv", "show", "series", "anime", "drama", "season", "episode", "剧", "番", "动漫", "动画", "综艺", "美剧", "日剧", "韩剧", "国剧", "连续剧"]
        return tvHints.contains(where: { lower.contains($0) }) ? .tvshows : .movies
    }

    private static func normalizedLocalPath(_ url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let resolved = realpath(url.path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return url.standardizedFileURL.path
    }

    private static func pathsOverlap(_ a: String, _ b: String, isLocal: Bool) -> Bool {
        if isLocal {
            let lhs = a.hasSuffix("/") && a.count > 1 ? String(a.dropLast()) : a
            let rhs = b.hasSuffix("/") && b.count > 1 ? String(b.dropLast()) : b
            if lhs == rhs { return true }
            return lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
        }
        let lhs = a.hasSuffix("/") ? a : a + "/"
        let rhs = b.hasSuffix("/") ? b : b + "/"
        return lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }
}

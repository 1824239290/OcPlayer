import JellyfinKit
import OcPlayerCore
import SwiftUI
import UniformTypeIdentifiers

/// All saved profiles share one switch. The app displays exactly one source.
/// 本地媒体库固定全局唯一（内部可包含任意多分类、多磁盘多文件夹）；WebDAV / SMB 可按需添加多个远程来源。
struct MediaSourcesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var reauthorizing: OcpFileLibrary.Source?
    @State private var importing = false
    @State private var pendingDeleteSource: OcpFileLibrary.Source?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section("本地媒体库") {
                    if let local = app.fileLibrary.localSource {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("本地媒体库", systemImage: "folder.fill")
                                Text("固定唯一 · 支持跨磁盘添加多个分类与多个文件夹")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let message = app.fileLibrary.permissionErrors[local.sourceId] {
                                    Text(message).font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if local.sourceId == app.activeFileSourceID {
                                Text("使用中").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("切换") {
                                    dismiss()
                                    Task { await app.activateFileSource(local.sourceId) }
                                }
                            }
                            Button("管理分类") {
                                app.mediaLibrarySheet = .manage(sourceID: local.sourceId)
                            }
                            if app.fileLibrary.permissionErrors[local.sourceId] != nil {
                                Button("授权目录") { reauthorizing = local; importing = true }
                            }
                        }

                        // 若升级前残留了多余的本地媒体库来源，仅允许清理移除，不再允许继续新建。
                        ForEach(app.fileLibrary.extraLocalSources) { extra in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label("\(extra.displayName)（旧重复本地库）", systemImage: "folder")
                                    Text(extra.rootPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if extra.sourceId == app.activeFileSourceID {
                                    Text("使用中").font(.caption).foregroundStyle(.secondary)
                                } else {
                                    Button("切换") {
                                        dismiss()
                                        Task { await app.activateFileSource(extra.sourceId) }
                                    }
                                }
                                Button("移除", role: .destructive) {
                                    pendingDeleteSource = extra
                                }
                            }
                        }
                    } else {
                        Button {
                            app.addFileLibraryDraft = FileLibraryDraft(localOnly: true)
                        } label: {
                            Label("设置本地媒体库…", systemImage: "folder.badge.plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(app.fileLibrary.capabilities == nil)
                        Text("本地媒体库全局唯一，可自由添加多个电影/剧集分类以及跨磁盘合并多个文件夹。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = app.fileLibrary.availabilityError { Text(error).font(.caption).foregroundStyle(.orange) }
                }

                Section("远程文件来源（WebDAV / SMB）") {
                    ForEach(app.fileLibrary.remoteSources) { source in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(source.displayName, systemImage: "network")
                                Text(source.rootPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if let message = app.fileLibrary.permissionErrors[source.sourceId] {
                                    Text(message).font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if source.sourceId == app.activeFileSourceID {
                                Text("使用中").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("切换") {
                                    dismiss()
                                    Task { await app.activateFileSource(source.sourceId) }
                                }
                            }
                            Button("管理") {
                                app.mediaLibrarySheet = .manage(sourceID: source.sourceId)
                            }
                            Button("更新连接") {
                                app.addFileLibraryDraft = FileLibraryDraft(sourceID: source.sourceId, connectionOnly: true)
                            }
                            Button(role: .destructive) {
                                pendingDeleteSource = source
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除此远程来源")
                        }
                    }
                    if app.fileLibrary.capabilities?.sourceKinds.contains(where: { $0 == "webdav" || $0 == "smb" }) == true {
                        Button {
                            app.addFileLibraryDraft = FileLibraryDraft(remoteOnly: true)
                        } label: {
                            Label("添加 WebDAV / SMB 来源…", systemImage: "externaldrive.badge.plus")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Jellyfin / Emby") {
                    ForEach(app.store.profiles) { profile in
                        HStack {
                            Label(profile.serverName, systemImage: "server.rack")
                            Spacer()
                            if app.server?.profile.id == profile.id { Text("使用中").font(.caption).foregroundStyle(.secondary) }
                            else {
                                Button("切换") {
                                    dismiss()
                                    Task { await app.switchToServer(profile) }
                                }
                            }
                        }
                    }
                    Button { dismiss(); app.reconnectFlow() } label: {
                        Label("连接服务器…", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }.buttonStyle(.plain)
                }

                Section {
                    Text("一次浏览一个来源。切换后首页、搜索、详情和观看进度都使用选中的来源。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section { NavigationLink("TMDB 设置") { TMDbSettingsView() } }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("媒体来源")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
                do {
                    if let source = reauthorizing { try app.fileLibrary.authorize(source: source, root: result.get()) }
                    error = nil
                } catch { self.error = error.localizedDescription }
                reauthorizing = nil
            }
            .alert(
                "删除媒体来源？",
                isPresented: Binding(
                    get: { pendingDeleteSource != nil },
                    set: { if !$0 { pendingDeleteSource = nil } }
                ),
                presenting: pendingDeleteSource
            ) { target in
                Button("取消", role: .cancel) { pendingDeleteSource = nil }
                Button("删除", role: .destructive) {
                    pendingDeleteSource = nil
                    Task {
                        do {
                            try await app.deleteFileSource(target.sourceId)
                            error = nil
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
            } message: { target in
                Text("将移除「\(target.displayName)」的所有分类索引和观看记录，不会删除你的视频文件。")
            }
            .task { try? await app.fileLibrary.setup() }
        }
        #if os(macOS)
        .frame(minWidth: 580, idealWidth: 660, minHeight: 460, idealHeight: 600)
        #endif
    }
}

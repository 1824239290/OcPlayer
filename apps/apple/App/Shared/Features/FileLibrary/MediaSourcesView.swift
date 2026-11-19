import JellyfinKit
import OcPlayerCore
import SwiftUI
import UniformTypeIdentifiers

/// All saved profiles share one switch. The app displays exactly one source.
struct MediaSourcesView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var reauthorizing: OcpFileLibrary.Source?
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section("文件夹媒体库") {
                    ForEach(app.fileLibrary.sources) { source in
                        HStack {
                            VStack(alignment: .leading) {
                                Label(source.displayName, systemImage: "folder")
                                Text(source.rootPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                if let message = app.fileLibrary.permissionErrors[source.sourceId] {
                                    Text(message).font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if source.sourceId == app.activeFileSourceID { Text("使用中").font(.caption).foregroundStyle(.secondary) }
                            else {
                                Button("切换") {
                                    dismiss()
                                    Task { await app.activateFileSource(source.sourceId) }
                                }
                            }
                            if app.fileLibrary.permissionErrors[source.sourceId] != nil {
                                Button("授权目录") { reauthorizing = source; importing = true }
                            }
                        }
                    }
                    Button {
                        app.addFileLibraryDraft = FileLibraryDraft()
                    } label: {
                        Label("添加文件夹媒体库…", systemImage: "folder.badge.plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(app.fileLibrary.capabilities == nil)
                    if let error = app.fileLibrary.availabilityError { Text(error).font(.caption).foregroundStyle(.orange) }
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
                Section { Text("一次浏览一个来源。切换后首页、搜索、详情和观看进度都使用选中的来源。")
                    .font(.caption).foregroundStyle(.secondary) }
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
            .task { try? await app.fileLibrary.setup() }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 560)
        #endif
    }
}

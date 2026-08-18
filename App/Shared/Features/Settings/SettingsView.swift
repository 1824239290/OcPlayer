import SwiftUI
import UniformTypeIdentifiers

/// 设置页：服务器与账号信息、首页轮播来源、本地播放入口、关于信息。
/// 外观 / 播放细节设置 M4 再进；弹幕设置随 M3（使用者暂缓）。
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    @State private var isImporting = false
    @State private var isEnteringURL = false

    var body: some View {
        Form {
            Section("服务器") {
                row("名称", app.server?.profile.serverName ?? "—")
                row("地址", app.server?.profile.baseURL.absoluteString ?? "—")
                row("版本", app.server?.profile.serverVersion ?? "—")
                row("用户", app.currentUserLabel)
            }

            Section("首页") {
                Toggle("首页轮播图", isOn: Binding(
                    get: { app.isHeroCarouselEnabled },
                    set: { app.setHeroCarouselEnabled($0) }
                ))

                if app.isHeroCarouselEnabled {
                    Picker("轮播来源", selection: Binding(
                        get: { app.heroSource },
                        set: { app.setHeroSource($0) }
                    )) {
                        ForEach(AppModel.HeroSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("「我的收藏」为空时会自动回落为最近添加。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("播放") {
                Button {
                    isImporting = true
                } label: {
                    Label("打开本地视频文件…", systemImage: "folder")
                }
                Button {
                    isEnteringURL = true
                } label: {
                    Label("打开直连链接…", systemImage: "link")
                }
                Text("直连播放 token 只走请求头；本地文件不上传任何信息。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Section("关于") {
                row("播放内核", "Erika v0.1.6（Rust · FFmpeg · libass）")
                row("直连策略", "优先直连直解（DirectPlay），播放前经 PlaybackInfo 选择媒体源；不支持直连的源回退直连流（DirectStream）")
                row("弹幕", "弹弹play 开放平台（暂缓接入）")
            }

            Section {
                Button(role: .destructive) {
                    app.signOut()
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("设置")
        .formStyle(.grouped)
        .fileImporter(isPresented: $isImporting,
                      allowedContentTypes: Self.playableTypes) { result in
            if case .success(let url) = result { openLocal(url) }
        }
        .sheet(isPresented: $isEnteringURL) {
            URLEntrySheet { uri, token in
                openDirect(uri, token: token)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func openLocal(_ url: URL) {
        app.presentLocalFile(url)
    }

    private func openDirect(_ uri: String, token: String?) {
        app.presentRequest(PlaybackController.request(uri: uri, jellyfinToken: token))
    }

    private static var playableTypes: [UTType] {
        [.audiovisualContent, .movie, .video, .mpeg4Movie, .quickTimeMovie]
            + [UTType("org.matroska.mkv")].compactMap { $0 }
    }
}

/// 直连链接入口（M0 验证 `open_with_headers` 用，现在挂在设置页和播放页）。
struct URLEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var uri = ""
    @State private var token = ""
    let onSubmit: (String, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("打开直连链接").font(.headline)
            TextField("http://…/Videos/{id}/stream?static=true", text: $uri)
                .textFieldStyle(.roundedBorder)
            SecureField("Jellyfin AccessToken（可留空）", text: $token)
                .textFieldStyle(.roundedBorder)
            Text("token 只作为请求头发给内核，不写进 URL、不落日志。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("播放") {
                    onSubmit(uri.trimmingCharacters(in: .whitespacesAndNewlines),
                             token.isEmpty ? nil : token)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

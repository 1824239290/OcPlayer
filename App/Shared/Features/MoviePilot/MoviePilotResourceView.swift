import MoviePilotKit
import SwiftUI

/// 某个媒体的站点资源列表：种子按做种数排序，一键添加下载。
/// 下载完成后由 MoviePilot 服务端自动整理入库——这里不做任何入库追踪。
struct MoviePilotResourceView: View {
    @Environment(AppModel.self) private var app

    let media: MPMediaInfo

    @State private var torrents: [MPTorrent] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var notice: String?
    @State private var isNoticeError = false
    @State private var addingDownloadID: String?

    var body: some View {
        List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 4)
            }

            Section("站点资源") {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在搜索各站点资源，可能需要几十秒…")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                } else if let loadError {
                    Text(loadError)
                        .foregroundStyle(.red)
                        .font(.callout)
                    Button("重试") {
                        Task { await load() }
                    }
                } else if torrents.isEmpty {
                    Text("没有搜到资源。换个关键词、或稍后再试（部分站点需要 Cookie）。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(torrents) { torrent in
                        torrentRow(torrent)
                    }
                }
            }

            if let notice {
                Section {
                    Label(notice, systemImage: isNoticeError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(isNoticeError ? .red : .green)
                        .font(.callout)
                }
            }
        }
        .navigationTitle(media.title ?? "站点资源")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 12) {
            RemoteImage(url: media.posterURL, authHeader: nil)
                .frame(width: 72, height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                Text(media.title ?? "未知条目")
                    .font(.title3.weight(.semibold))
                Text(media.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let overview = media.overview {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        }
    }

    // MARK: - 种子行

    private func torrentRow(_ torrent: MPTorrent) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(torrent.title ?? "未命名资源")
                    .font(.callout)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let site = torrent.siteName {
                        badge(site, tint: .blue)
                    }
                    if torrent.isFree {
                        badge("免费", tint: .green)
                    }
                    Text(torrent.sizeText)
                    if let seeders = torrent.seeders {
                        Label("\(seeders)", systemImage: "arrow.up")
                            .foregroundStyle(seeders >= 5 ? .green : .secondary)
                    }
                    if let elapsed = torrent.dateElapsed ?? torrent.pubdate {
                        Text(elapsed)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                addDownload(torrent)
            } label: {
                if addingDownloadID == torrent.id {
                    ProgressView().controlSize(.small)
                } else {
                    Label("下载", systemImage: "arrow.down.circle")
                }
            }
            .disabled(addingDownloadID != nil)
        }
        .padding(.vertical, 2)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(tint)
    }

    // MARK: - 动作

    private func load() async {
        isLoading = true
        loadError = nil
        notice = nil
        do {
            let found = try await MoviePilotAPIClient.shared.searchTorrents(for: media, season: media.season)
            torrents = found.sorted { ($0.seeders ?? 0) > ($1.seeders ?? 0) }
        } catch {
            loadError = (error as? MoviePilotError)?.userMessage ?? "\(error)"
        }
        isLoading = false
    }

    private func addDownload(_ torrent: MPTorrent) {
        addingDownloadID = torrent.id
        notice = nil
        Task {
            do {
                try await MoviePilotAPIClient.shared.addDownload(media: media, torrent: torrent)
                notice = "已添加下载；完成后 MoviePilot 会自动整理入库到 Jellyfin"
                isNoticeError = false
            } catch {
                notice = (error as? MoviePilotError)?.userMessage ?? "\(error)"
                isNoticeError = true
            }
            addingDownloadID = nil
        }
    }
}

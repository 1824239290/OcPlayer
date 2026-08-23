import MoviePilotKit
import SwiftUI

/// MoviePilot 分区首页：关键词搜媒体（多源聚合）→ 点开搜站点资源下载。
/// 未配置 / 未登录时整页换成引导态。
struct MoviePilotHomeView: View {
    @Environment(AppModel.self) private var app

    @State private var keyword = ""
    @State private var isSearching = false
    @State private var results: [MPMediaInfo] = []
    @State private var searchError: String?
    @State private var searchGeneration = 0

    var body: some View {
        Group {
            if !app.moviepilot.store.isConfigured {
                gate("未配置 MoviePilot", icon: "arrow.down.circle",
                     hint: "在 设置 → MoviePilot 填写服务器地址与账号")
            } else if !app.moviepilot.isAuthenticated {
                gate("未登录", icon: "person.crop.circle.badge.exclamationmark",
                     hint: "在 设置 → MoviePilot 登录后即可搜索下载")
            } else {
                searchContent
            }
        }
        .navigationTitle("找片")
    }

    // MARK: - 门控

    private func gate(_ title: String, icon: String, hint: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(hint)
        } actions: {
            Button("去设置") { app.selectedSection = .settings }
        }
    }

    // MARK: - 搜索

    private var searchContent: some View {
        Group {
            if isSearching && results.isEmpty {
                ProgressView("正在搜索…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let searchError, results.isEmpty {
                ContentUnavailableView {
                    Label("搜索失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(searchError)
                } actions: {
                    Button("重试", action: search)
                }
            } else if results.isEmpty {
                if keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "搜索媒体资源",
                        systemImage: "magnifyingglass",
                        description: Text("输入片名搜索，来源聚合 TMDB / 豆瓣 / Bangumi，搜索后可一键挑站点下载。")
                    )
                } else {
                    ContentUnavailableView.search(text: keyword)
                }
            } else {
                List {
                    if isSearching {
                        Section {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.small)
                                Text("正在更新搜索结果…")
                                    .foregroundStyle(.secondary)
                                    .font(.callout)
                            }
                        }
                    } else if let searchError {
                        Section {
                            Text(searchError)
                                .foregroundStyle(.red)
                                .font(.callout)
                        }
                    }

                    Section("媒体结果 (\(results.count))") {
                        ForEach(results) { media in
                            NavigationLink {
                                MoviePilotResourceView(media: media)
                                    .id(media.id)
                            } label: {
                                resultRow(media)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .searchable(text: $keyword, prompt: Text("片名 / 关键词"))
        .onSubmit(of: .search, search)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    MoviePilotDownloadsView()
                } label: {
                    Label("下载管理", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    private func resultRow(_ media: MPMediaInfo) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: media.posterURL, authHeader: nil, maxPixelSize: 300)
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(media.title ?? "未知条目")
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(media.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let overview = media.overview {
                    Text(overview)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func search() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSearching else { return }
        searchGeneration += 1
        let generation = searchGeneration
        isSearching = true
        searchError = nil
        Task {
            do {
                let found = try await MoviePilotAPIClient.shared.searchMedia(title: trimmed)
                guard generation == searchGeneration else { return }
                results = found
            } catch {
                guard generation == searchGeneration else { return }
                searchError = (error as? MoviePilotError)?.userMessage ?? "\(error)"
            }
            if generation == searchGeneration {
                isSearching = false
            }
        }
    }
}

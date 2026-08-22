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
        List {
            Section {
                HStack(spacing: 8) {
                    TextField("片名 / 关键词", text: $keyword)
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        #endif
                        .onSubmit(search)
                    Button("搜索", action: search)
                        .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                }
                .listRowBackground(Color.clear)
                .padding(.vertical, 2)
            }

            Section {
                if isSearching {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在搜索…")
                            .foregroundStyle(.secondary)
                    }
                } else if let searchError {
                    Text(searchError)
                        .foregroundStyle(.red)
                        .font(.callout)
                } else if results.isEmpty {
                    Text("输入片名开始搜索，来源聚合 TMDB / 豆瓣 / Bangumi。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
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
            } header: {
                if !results.isEmpty || isSearching || searchError != nil {
                    Text("媒体结果")
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    MoviePilotDownloadsView()
                } label: {
                    Label("下载中", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    private func resultRow(_ media: MPMediaInfo) -> some View {
        HStack(spacing: 12) {
            RemoteImage(url: media.posterURL, authHeader: nil)
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

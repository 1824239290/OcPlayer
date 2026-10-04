import AppDesignKit
import CoreModel
import MetadataKit
import SwiftUI

/// 手动 TMDb 匹配面板。
///
/// ## 为什么需要它
///
/// 自动匹配刻意**只在置信度 ≥ 0.85 时落库**——错误的匹配（别人的剧情简介、别人的海报）
/// 比没有匹配更糟。代价是总有一部分条目匹配不上：冷门番、译名差异大、服务端没有
/// `ProviderIds` 又搜不到。没有这个面板，那些条目就永远只能空着，而用户明明知道
/// 正确的 TMDb 条目是哪一个。
///
/// ## 交互
///
/// 打开即用条目标题搜一次（用户多半只需要从候选里挑一个），也能改词重搜。
/// 选中即绑定（`source: .manual`）并立刻拉数据——**手动选择不会被自动匹配覆盖**。
struct TMDbMatchSheet: View {
    let item: MediaItem

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var results: [TMDbSearchResult] = []
    @State private var isSearching = false
    @State private var errorText: String?
    @State private var currentLink: TMDbLink?
    @State private var isBinding = false

    /// 只有电影与剧能手动匹配（TMDb 的 movie/tv 端点；季/集靠父剧推导）。
    private var mediaType: TMDbMediaType {
        item.kind == .movie ? .movie : .tv
    }

    private var canMatch: Bool { item.kind == .movie || item.kind == .series }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            content
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420, idealHeight: 520)
        .task {
            query = item.name
            await reloadLink()
            await search()
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TMDb 匹配")
                    .font(.headline)
                Spacer()
                // 匹配错了必须能取消：没有这个出口的话，一个错误的自动匹配会永远
                // 顶在那儿（而且它还会阻止重新自动匹配）。
                if currentLink != nil {
                    Button("解除匹配", role: .destructive) {
                        Task { await unbind() }
                    }
                    .disabled(isBinding)
                }
            }
            Text(item.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let link = currentLink {
                HStack(spacing: 6) {
                    Label("已匹配：\(link.entityKey.storageKey)", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text("（\(link.source.displayName)）")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Label("尚未匹配", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("片名 / 剧名", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await search() } }
            Button("搜索") { Task { await search() } }
                .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            if isSearching { ProgressView().controlSize(.small) }
        }
        .padding(12)
    }

    // MARK: - 结果

    @ViewBuilder
    private var content: some View {
        if !canMatch {
            unavailable
        } else if let errorText {
            VStack(spacing: 8) {
                Label(errorText, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                // 「搜不到」与「搜索失败」是两回事：失败要能重试。
                Button("重试") { Task { await search() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if results.isEmpty && !isSearching {
            Text("没有搜到候选。试试用原名（日文 / 英文）再搜一次。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results, id: \.id) { result in
                        resultRow(result)
                        Divider()
                    }
                }
            }
        }
    }

    private var unavailable: some View {
        Text("只有电影与剧集可以手动匹配。季与分集的数据由所属剧集推导。")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
    }

    private func resultRow(_ result: TMDbSearchResult) -> some View {
        let isCurrent = currentLink?.entityKey == entityKey(for: result)
        return Button {
            Task { await bind(result) }
        } label: {
            HStack(spacing: 12) {
                RemoteImage(
                    url: TMDbImageSize.url(path: result.posterPath, requestedWidth: 92),
                    authHeader: nil,
                    maxPixelSize: 92
                )
                .frame(width: 46, height: 69)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.title ?? "（无标题）")
                        .font(.body)
                        .lineLimit(1)
                    if let original = result.originalTitle,
                       original != result.title, !original.isEmpty {
                        Text(original)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        if let year = result.year { Text(String(year)) }
                        Text(result.mediaType == .movie ? "电影" : "剧集")
                        if let popularity = result.popularity, popularity > 0 {
                            Text("热度 \(Int(popularity))")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if isCurrent {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if isBinding {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBinding)
    }

    // MARK: - 动作

    private func entityKey(for result: TMDbSearchResult) -> TMDbEntityKey {
        result.mediaType == .movie ? .movie(result.id) : .tv(result.id)
    }

    private func reloadLink() async {
        currentLink = await app.tmdbLink(for: item)
    }

    private func search() async {
        guard canMatch else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        errorText = nil
        do {
            results = try await app.tmdbSearchCandidates(
                query: trimmed, mediaType: mediaType, year: item.year)
        } catch {
            // 失败要如实说，而不是显示「没搜到」——那会让用户以为 TMDb 上没有。
            errorText = "搜索失败：\(TMDbCoordinator.message(for: error as? TMDbError) ?? "\(error)")"
            results = []
        }
        isSearching = false
    }

    private func bind(_ result: TMDbSearchResult) async {
        isBinding = true
        await app.tmdbBind(itemID: item.id, entityKey: entityKey(for: result))
        await reloadLink()
        isBinding = false
    }

    /// 解除匹配。**不清已下载的实体数据**（那可能还被别的条目用着，且过期会被清理），
    /// 只删这条对应——下次进详情页会重新自动匹配。
    private func unbind() async {
        isBinding = true
        await app.tmdbUnbind(itemID: item.id)
        await reloadLink()
        isBinding = false
    }
}

extension TMDbLinkSource {
    /// 设置页/面板展示用（说明这条对应是怎么来的）。
    var displayName: String {
        switch self {
        case .providerID: "来自媒体库"
        case .search: "自动匹配"
        case .manual: "手动选择"
        }
    }
}

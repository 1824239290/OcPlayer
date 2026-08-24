import CoreModel
import MoviePilotKit
import SwiftUI

/// 详情页内嵌的 MoviePilot 下载区块（与 BangumiChapterSection 同级同款头）。
///
/// - 条目带 TmdbId：直接按 tmdb 源拼出媒体键，免匹配直达资源列表
/// - 没有 TmdbId：按标题搜一次元数据兜底匹配（优先年份吻合的结果）
/// - 下载之后什么都不做：整理 / 刮削 / 入库 Jellyfin 全部归 MoviePilot 服务端
///
/// 未登录 MoviePilot 时整块不出现，详情页不弹引导。
struct MoviePilotResourceSection: View {
    @Environment(MoviePilotCoordinator.self) private var moviepilot
    @Environment(\.contentLeading) private var contentLeading

    let item: MediaItem

    @State private var fallbackMedia: MPMediaInfo?
    @State private var isMatching = false
    @State private var errorText: String?
    @State private var matchGeneration: UInt64 = 0

    var body: some View {
        if moviepilot.isAuthenticated {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 26)
                    .padding(.bottom, 12)
                sectionBody
                    .padding(.bottom, 4)
            }
            .padding(.horizontal, contentLeading)
            .task(id: item.id) { fallbackMedia = nil; errorText = nil }
        }
    }

    // MARK: - 头

    private var header: some View {
        HStack(spacing: 10) {
            Text("MoviePilot")
                .font(.title3.weight(.bold))
            if let title = resolvedMedia?.title, title != item.name {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    // MARK: - 主体

    private var resolvedMedia: MPMediaInfo? {
        directMedia ?? fallbackMedia
    }

    /// TmdbId 直连：一次网络都不用，天然可信。
    private var directMedia: MPMediaInfo? {
        guard let tmdb = item.tmdbID, let id = Double(tmdb) else { return nil }
        var raw: [String: JSONValue] = [
            "media_source": .string("tmdb"),
            "media_id": .string("tmdb:\(tmdb)"),
            "tmdb_id": .number(id),
            "title": .string(item.name),
            "type": .string(item.kind == .movie ? "电影" : "电视剧"),
        ]
        if let year = item.year {
            raw["year"] = .string(String(year))
            raw["title_year"] = .string(String(year))
        }
        return MPMediaInfo(raw: raw)
    }

    @ViewBuilder
    private var sectionBody: some View {
        if let media = resolvedMedia {
            NavigationLink {
                MoviePilotResourceView(media: media)
                    .id(media.id)
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("搜索站点资源并下载")
                            .font(.callout.weight(.medium))
                        Text("按标题搜、可选站点；下载完成后 MoviePilot 自动整理入库，稍后出现在媒体库")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            // 兜底匹配出来的结果允许换（TmdbId 直连不提供——它就是这条目本身）。
            if fallbackMedia != nil {
                Button("匹配得不对？重新匹配") {
                    fallbackMedia = nil
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .padding(.top, 6)
            }
        } else if isMatching {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在按标题匹配 MoviePilot 条目…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    Task { await matchByTitle() }
                } label: {
                    Label("在 MoviePilot 找资源", systemImage: "magnifyingglass")
                        .font(.callout.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                Text("这个条目没有 Tmdb 编号，先按标题匹配一次。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: - 兜底匹配

    private func matchByTitle() async {
        matchGeneration &+= 1
        let generation = matchGeneration
        isMatching = true
        errorText = nil
        defer { if generation == matchGeneration { isMatching = false } }
        do {
            let results = try await MoviePilotAPIClient.shared.searchMedia(title: item.name)
            guard generation == matchGeneration else { return }
            guard !results.isEmpty else {
                errorText = "没有按「\(item.name)」搜到条目，去「MoviePilot」页换个关键词试试。"
                return
            }
            // 优先年份吻合；都没有就取第一个（多源聚合的第一名通常是最佳猜测）。
            fallbackMedia = results.first { media in
                media.year == item.year.map(String.init)
            } ?? results.first
        } catch {
            guard generation == matchGeneration else { return }
            errorText = (error as? MoviePilotError)?.userMessage ?? "\(error)"
        }
    }
}

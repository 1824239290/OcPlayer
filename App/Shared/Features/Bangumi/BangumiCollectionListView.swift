import AppDesignKit
import BangumiKit
import SwiftUI

/// 完整收藏列表：segmented 切换收藏类型 + 分页行。
/// 分页状态机走共享的 `PagedListLoader`（代次守卫/追加去重/hasMore 都在里面）。
struct BangumiCollectionListView: View {
    let subjectType: BangumiSubjectType

    @Environment(BangumiCoordinator.self) private var bangumi
    @State private var collectionType: BangumiCollectionType = .collect
    @State private var counts: [BangumiCollectionType: Int] = [:]
    /// 懒建一次；fetch 闭包读的 @State 是存储引用，切类型时读到的是当前值。
    @State private var loader: PagedListLoader<BangumiSubjectDTO>?

    private static let pageSize = 20

    var body: some View {
        Group {
            if let loader {
                content(loader)
            } else {
                ProgressView("正在加载…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("我的\(subjectType.description)")
        .safeAreaInset(edge: .top) {
            collectionTypePicker
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
        }
        .task(id: subjectType.rawValue) {
            if loader == nil {
                loader = PagedListLoader(pageSize: Self.pageSize) { offset, limit in
                    let items = try await bangumi.context.fetchCollectionSubjects(
                        subjectType: subjectType, collectionType: collectionType,
                        limit: limit, offset: offset)
                    return .init(items: items)
                } errorMessage: { error in
                    (error as? BangumiError)?.userMessage ?? "\(error)"
                }
            }
            async let countsFetch: () = refreshCounts()
            await loader?.loadInitial()
            await countsFetch
        }
        .onChange(of: collectionType) { _, _ in
            // 切收藏类型 = 整份重取；loader 的代次守卫会丢掉在途旧翻页。
            Task { await loader?.loadInitial() }
        }
    }

    @ViewBuilder
    private func content(_ loader: PagedListLoader<BangumiSubjectDTO>) -> some View {
        if loader.isLoading && loader.items.isEmpty {
            ProgressView("正在加载…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = loader.loadError, loader.items.isEmpty {
            EmptyState(failure: error) {
                Task { await loader.loadInitial() }
            }
        } else {
            List {
                ForEach(loader.items) { subject in
                    NavigationLink(value: AppModel.Route.bangumiSubject(subjectID: subject.id)) {
                        CollectionRow(subject: subject)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if subject.id == loader.items.last?.id {
                            Task { await loader.loadMore() }
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var collectionTypePicker: some View {
        Picker("收藏类型", selection: $collectionType) {
            ForEach(BangumiCollectionType.allTypes()) { type in
                Text("\(type.description(subjectType))(\(counts[type, default: 0]))")
                    .tag(type)
            }
        }
        .pickerStyle(.segmented)
    }

    private func refreshCounts() async {
        counts = (try? await bangumi.context.fetchCollectionCounts(subjectType: subjectType)) ?? [:]
    }
}

/// 收藏列表行：封面 + 标题 + 评分/吐槽摘要。
private struct CollectionRow: View {
    let subject: BangumiSubjectDTO

    var body: some View {
        HStack(spacing: 12) {
            MediaArtwork(
                url: coverURL,
                shape: .poster,
                width: 48,
                cornerRadius: 6,
                maxPixelSize: 240
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(subject.nameCN.isEmpty ? subject.name : subject.nameCN)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                if !subject.nameCN.isEmpty, subject.name != subject.nameCN {
                    Text(subject.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let interest = subject.interest {
                    HStack(spacing: 6) {
                        if interest.rate > 0 {
                            Text(String(repeating: "★", count: min(max(interest.rate, 0), 10)))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if interest.type == .doing, subject.eps > 0 {
                            Text("\(interest.epStatus)/\(subject.eps) 话")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            if let interest = subject.interest, !interest.comment.isEmpty {
                Text(interest.comment)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }

    private var coverURL: URL? {
        guard let image = subject.images?.large else { return nil }
        return URL(string: BangumiURL.imageURLString(from: image))
    }
}

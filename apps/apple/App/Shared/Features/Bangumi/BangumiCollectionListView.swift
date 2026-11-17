import AppDesignKit
import BangumiKit
import SwiftUI

/// 与观影空间共用灰白控件、氛围底和玻璃海报卡的完整片单。
struct BangumiCollectionListView: View {
    let subjectType: BangumiSubjectType

    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(AppModel.self) private var app
    @Environment(\.contentLeading) private var contentLeading
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var collectionType: BangumiCollectionType = .collect
    @State private var counts: [BangumiCollectionType: Int] = [:]
    @State private var loader: PagedListLoader<BangumiSubjectDTO>?
    @State private var loaderKey: String?

    private static let pageSize = 20
    private var isCompact: Bool { horizontalSizeClass == .compact }
    private var accountKey: String {
        "\(bangumi.profile?.id ?? 0):\(bangumi.profile?.username ?? ""):" +
        "\(bangumi.isAuthenticated):\(bangumi.isDatabaseReady):\(subjectType.rawValue)"
    }
    private var loadKey: String { "\(accountKey):\(collectionType.rawValue)" }
    private var columns: [GridItem] {
        dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible(), alignment: .top)] : PosterGrid.columns(compact: isCompact)
    }

    init(subjectType: BangumiSubjectType, initialCollection: BangumiCollectionType = .collect) {
        self.subjectType = subjectType
        _collectionType = State(initialValue: initialCollection)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                pageHeading
                if let loader, loaderKey == loadKey {
                    content(loader)
                } else {
                    loadingState
                }
            }
            .padding(.horizontal, contentLeading)
            .padding(.top, 20)
            .padding(.bottom, 32)
            .frame(maxWidth: 1120, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .id(collectionType)
        .navigationTitle("\(subjectType.description)片单")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .safeAreaInset(edge: .top, spacing: 0) {
            collectionTypePicker
                .padding(.horizontal, contentLeading)
                .padding(.vertical, 10)
                .frame(maxWidth: 1120)
                .frame(maxWidth: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新片单")
                .help("刷新片单")
                .disabled(loader?.isLoading == true)
            }
        }
        .refreshable { await refresh() }
        .task(id: loadKey) {
            // 每种片单固定自己的查询条件；旧请求只能更新已离开页面的分页器。
            let selectedType = collectionType
            let next = PagedListLoader<BangumiSubjectDTO>(pageSize: Self.pageSize) { offset, limit in
                let items = try await bangumi.context.fetchCollectionSubjects(
                    subjectType: subjectType, collectionType: selectedType,
                    limit: limit, offset: offset)
                return .init(items: items)
            } errorMessage: { error in
                (error as? BangumiError)?.userMessage ?? "\(error)"
            }
            loader = next
            loaderKey = loadKey
            await next.loadInitial()
        }
        .task(id: accountKey) {
            counts = [:]
            await refreshCounts()
        }
    }

    private func title(for type: BangumiCollectionType) -> String {
        subjectType == .anime && type == .wish ? "待看" : type.description(subjectType)
    }

    private var pageHeading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(title(for: collectionType))片单")
                .font(.largeTitle.weight(.bold))
            HStack(spacing: 6) {
                Text("Bangumi")
                if let count = counts[collectionType] {
                    Text("·")
                    Text("\(count) 部\(subjectType.description)").monospacedDigit()
                }
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var collectionTypePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(BangumiCollectionType.allTypes()) { type in
                    let selected = collectionType == type
                    Button { collectionType = type } label: {
                        HStack(spacing: 7) {
                            Text(title(for: type))
                            Text(counts[type].map(String.init) ?? "—")
                                .monospacedDigit().opacity(selected ? 0.75 : 0.6)
                        }
                        .font(.subheadline.weight(selected ? .semibold : .medium))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .foregroundStyle(selected ? AppAccent.onSolid : Color.primary)
                        .background(selected ? AppAccent.solidTint : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title(for: type))，\(counts[type].map(String.init) ?? "数量待获取")")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(5)
            .glassEffect(.regular, in: Capsule())
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func content(_ loader: PagedListLoader<BangumiSubjectDTO>) -> some View {
        if loader.isLoading && loader.items.isEmpty {
            loadingState
        } else if let error = loader.loadError, loader.items.isEmpty {
            EmptyState(failure: error) { Task { await loader.loadInitial() } }
                .frame(maxWidth: .infinity, minHeight: 340)
        } else if loader.items.isEmpty {
            EmptyState(empty: "还没有\(title(for: collectionType))的条目", systemImage: "rectangle.stack",
                       message: "在 Bangumi 条目详情中加入收藏后，会出现在这里。")
                .frame(maxWidth: .infinity, minHeight: 340)
        } else {
            GlassEffectContainer(spacing: 18) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: isCompact ? 16 : 22) {
                    ForEach(loader.items) { subject in
                        DetailTransitionCard(list: "bangumi.collection.\(collectionType.rawValue)",
                                             position: String(subject.id),
                                             action: { source in app.openBangumiSubject(id: subject.id, source: source) }) { open in
                            Button(action: open) {
                                BangumiCollectionPosterCard(subject: subject)
                            }
                            .buttonStyle(.plain)
                        }
                        .onAppear {
                            if subject.id == loader.items.last?.id {
                                Task { await loader.loadMore() }
                            }
                        }
                    }
                }
            }
            if loader.hasMore {
                HStack {
                    Spacer()
                    if loader.isLoadingMore {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("加载更多") { Task { await loader.loadMore() } }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
            }
        }
    }

    private var loadingState: some View {
        ProgressView("正在加载片单…")
            .frame(maxWidth: .infinity, minHeight: 340)
    }

    private func refresh() async {
        async let countsFetch: () = refreshCounts()
        await loader?.loadInitial()
        await countsFetch
    }

    private func refreshCounts() async {
        let key = accountKey
        guard let updated = try? await bangumi.context.fetchCollectionCounts(subjectType: subjectType),
              !Task.isCancelled, key == accountKey else { return }
        counts = updated
    }
}

private struct BangumiCollectionPosterCard: View {
    let subject: BangumiSubjectDTO

    private var title: String { subject.nameCN.isEmpty ? subject.name : subject.nameCN }
    private var originalTitle: String { subject.nameCN.isEmpty || subject.name == subject.nameCN ? "" : subject.name }
    private var coverURL: URL? {
        guard let images = subject.images,
              let image = [images.large, images.common, images.medium].first(where: { !$0.isEmpty }) else { return nil }
        return URL(string: BangumiURL.imageURLString(from: image))
    }
    private var metadata: String {
        var parts: [String] = []
        if subject.airtime.year > 0 { parts.append(String(subject.airtime.year)) }
        if subject.eps > 0 {
            if let interest = subject.interest, interest.type == .doing {
                parts.append("\(interest.epStatus)/\(subject.eps) 话")
            } else {
                parts.append("\(subject.eps) 话")
            }
        }
        return parts.isEmpty ? subject.type.description : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MediaArtwork(url: coverURL, shape: .poster, cornerRadius: 10,
                         emptyIcon: "film", aspectRatio: 2.0 / 3.0, scaling: .fill)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold))
                    .lineLimit(2, reservesSpace: true)
                Text(originalTitle.isEmpty ? " " : originalTitle)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityHidden(originalTitle.isEmpty)
                HStack(spacing: 5) {
                    Text(metadata).lineLimit(1)
                    Spacer(minLength: 2)
                    if subject.rating.score.isFinite, subject.rating.score > 0 {
                        Label(subject.rating.score.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
                if let interest = subject.interest, interest.rate > 0 {
                    Text("我的评分 \(interest.rate)/10").font(.caption2).foregroundStyle(.secondary)
                }
                if let comment = subject.interest?.comment, !comment.isEmpty {
                    Text(comment).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.primary)
        .liquidGlassCard(isInteractive: true)
        .contentShape(.rect(cornerRadius: Metrics.glassCardRadius))
        .accessibilityElement(children: .combine)
    }
}

import BangumiKit
import SwiftUI

/// 完整收藏列表：segmented 切换收藏类型 + 分页行。
struct BangumiCollectionListView: View {
    let subjectType: BangumiSubjectType

    @Environment(BangumiCoordinator.self) private var bangumi
    @State private var collectionType: BangumiCollectionType = .collect
    @State private var counts: [BangumiCollectionType: Int] = [:]
    @State private var subjects: [BangumiSubjectDTO] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var reloader = false
    /// 列表代次：load() 重置列表时自增，作废在途旧翻页，防止旧类型数据混进新列表。
    @State private var listGeneration = 0

    private let pageSize = 20

    var body: some View {
        Group {
            if isLoading && subjects.isEmpty {
                ProgressView("正在加载…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError, subjects.isEmpty {
                ContentUnavailableView {
                    Label(UIStrings.loadFailed, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button(UIStrings.retry) {
                        reloader.toggle()
                    }
                }
            } else {
                List {
                    ForEach(subjects) { subject in
                        NavigationLink(value: AppModel.Route.bangumiSubject(subjectID: subject.id)) {
                            CollectionRow(subject: subject)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if subject.id == subjects.last?.id {
                                Task { await loadMore() }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("我的\(subjectType.description)")
        .safeAreaInset(edge: .top) {
            collectionTypePicker
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.bar)
        }
        .task(id: "\(subjectType.rawValue)-\(collectionType.rawValue)-\(reloader)") {
            await load()
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

    private func load() async {
        listGeneration += 1
        let generation = listGeneration
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            counts = (try? await bangumi.context.fetchCollectionCounts(subjectType: subjectType)) ?? [:]
            let firstPage = try await bangumi.context.fetchCollectionSubjects(
                subjectType: subjectType, collectionType: collectionType,
                limit: pageSize, offset: 0)
            guard generation == listGeneration else { return }
            subjects = firstPage
        } catch let error as BangumiError {
            loadError = error.userMessage
        } catch {
            loadError = "\(error)"
        }
    }

    private func loadMore() async {
        guard !isLoading else { return }
        let generation = listGeneration
        isLoading = true
        defer { isLoading = false }
        if let more = try? await bangumi.context.fetchCollectionSubjects(
            subjectType: subjectType, collectionType: collectionType,
            limit: pageSize, offset: subjects.count) {
            // 期间切了收藏类型（generation 已自增）就丢弃，append 会污染新列表。
            guard generation == listGeneration else { return }
            subjects.append(contentsOf: more)
        }
    }
}

/// 收藏列表行：封面 + 标题 + 评分/吐槽摘要。
private struct CollectionRow: View {
    let subject: BangumiSubjectDTO

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: coverURL, authHeader: nil, maxPixelSize: 240)
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(width: 48, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))
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

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

    private let pageSize = 20

    var body: some View {
        Group {
            if isLoading && subjects.isEmpty {
                ProgressView("正在加载…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError, subjects.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("重试") {
                        reloader.toggle()
                    }
                }
            } else {
                List {
                    ForEach(subjects) { subject in
                        CollectionRow(subject: subject)
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
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            counts = (try? await bangumi.context.fetchCollectionCounts(subjectType: subjectType)) ?? [:]
            subjects = try await bangumi.context.fetchCollectionSubjects(
                subjectType: subjectType, collectionType: collectionType,
                limit: pageSize, offset: 0)
        } catch let error as BangumiError {
            loadError = error.userMessage
        } catch {
            loadError = "\(error)"
        }
    }

    private func loadMore() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        if let more = try? await bangumi.context.fetchCollectionSubjects(
            subjectType: subjectType, collectionType: collectionType,
            limit: pageSize, offset: subjects.count) {
            subjects.append(contentsOf: more)
        }
    }
}

/// 收藏列表行：封面 + 标题 + 评分/吐槽摘要。
private struct CollectionRow: View {
    let subject: BangumiSubjectDTO

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: coverURL, authHeader: nil)
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

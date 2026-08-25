import BangumiKit
import CoreModel
import SwiftUI

/// 关联选择器：搜索 Bangumi 条目并手动关联。
struct BangumiLinkPicker: View {
    let item: MediaItem
    var season: MediaItem? = nil
    var onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keyword: String
    @State private var results: [BangumiSlimSubjectDTO] = []
    @State private var isSearching = false
    @State private var searchError: String?

    init(item: MediaItem, season: MediaItem? = nil, onSelect: @escaping (Int) -> Void) {
        self.item = item
        self.season = season
        self.onSelect = onSelect

        let seriesName = item.seriesName ?? item.name
        let seasonNumber = season?.seasonNumber ?? item.seasonNumber
        let seasonName = season?.name ?? item.seasonName
        let initialKeyword: String
        if let seasonName, !seasonName.isEmpty, season != nil {
            initialKeyword = "\(seriesName) \(seasonName)"
        } else if let seasonNumber, seasonNumber > 1 {
            initialKeyword = "\(seriesName) 第\(seasonNumber)季"
        } else {
            initialKeyword = seriesName
        }
        _keyword = State(initialValue: initialKeyword)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("关联 Bangumi 条目")
                    .font(.headline)
                Spacer()
                Button("取消") { dismiss() }
            }
            .padding(16)

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索条目（支持中文名）", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("搜索") { Task { await search() } }
                    .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            if isSearching {
                ProgressView("搜索中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let searchError {
                ContentUnavailableView {
                    Label(UIStrings.searchFailed, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(searchError)
                }
            } else if results.isEmpty {
                ContentUnavailableView {
                    Label("搜索 Bangumi 条目", systemImage: "magnifyingglass")
                } description: {
                    Text("输入名称搜索，选择后完成关联。")
                }
            } else {
                List(results) { subject in
                    Button {
                        onSelect(subject.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            RemoteImage(url: coverURL(subject), authHeader: nil, maxPixelSize: 120)
                                .aspectRatio(2 / 3, contentMode: .fill)
                                .frame(width: 34, height: 48)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(subject.nameCN.isEmpty ? subject.name : subject.nameCN)
                                    .font(.body)
                                    .lineLimit(1)
                                if !subject.nameCN.isEmpty, subject.name != subject.nameCN {
                                    Text(subject.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(subject.type.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .task {
            if results.isEmpty && !keyword.trimmingCharacters(in: .whitespaces).isEmpty {
                await search()
            }
        }
    }

    private func search() async {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        searchError = nil
        defer { isSearching = false }
        do {
            results = try await BangumiMatcher.search(trimmed)
        } catch let error as BangumiError {
            searchError = error.userMessage
        } catch {
            searchError = "\(error)"
        }
    }

    private func coverURL(_ subject: BangumiSlimSubjectDTO) -> URL? {
        guard let image = subject.images?.large else { return nil }
        return URL(string: BangumiURL.imageURLString(from: image))
    }
}

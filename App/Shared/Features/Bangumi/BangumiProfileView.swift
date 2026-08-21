import BangumiKit
import SwiftUI

/// 个人主页：头像/昵称/签名 + 按条目类型的收藏分区（chips 计数 + 横向条）。
struct BangumiProfileView: View {
    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let profile = bangumi.profile {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ProfileHeader(profile: profile)
                        ForEach(BangumiSubjectType.allTypes) { type in
                            CollectionSection(subjectType: type)
                        }
                    }
                    .padding(20)
                }
                .navigationTitle("我的")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await bangumi.signOut() }
                        } label: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                        }
                        .help("退出 Bangumi 登录")
                    }
                }
            } else {
                BangumiLoginView()
                    .navigationTitle("我的")
            }
        }
    }
}

/// 用户信息头：头像 + 昵称 + @username + 签名。
private struct ProfileHeader: View {
    let profile: BangumiProfile

    var body: some View {
        HStack(spacing: 14) {
            RemoteImage(url: avatarURL, authHeader: nil)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name)
                    .font(.title2.weight(.semibold))
                Text("@\(profile.username)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !profile.sign.isEmpty {
                    Text(profile.sign)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
    }

    private var avatarURL: URL? {
        guard let avatar = profile.avatar?.large else { return nil }
        return URL(string: BangumiURL.imageURLString(from: avatar))
    }
}

/// 一个条目类型的收藏分区：标题 + chips + 横向条。
private struct CollectionSection: View {
    let subjectType: BangumiSubjectType

    @Environment(BangumiCoordinator.self) private var bangumi
    @Environment(AppModel.self) private var app
    @State private var counts: [BangumiCollectionType: Int] = [:]
    @State private var selected: BangumiCollectionType = .collect
    @State private var subjects: [BangumiSubjectDTO] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                app.path.append(.bangumiCollectionList(subjectType))
            } label: {
                HStack {
                    Text("我的\(subjectType.description)")
                        .font(.headline)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            chips

            if subjects.isEmpty {
                if loaded {
                    Text("暂无收藏")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 6)
                } else {
                    ProgressView().controlSize(.small).padding(.vertical, 6)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(subjects) { subject in
                            CollectionTile(subject: subject)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .task(id: "\(subjectType.rawValue)-\(selected.rawValue)") {
            await load()
        }
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(BangumiCollectionType.allTypes()) { type in
                let count = counts[type, default: 0]
                Button {
                    selected = type
                } label: {
                    Text("\(type.description(subjectType))(\(count))")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            selected == type ? Color.accentColor.opacity(0.2) : .clear,
                            in: Capsule())
                        .overlay(Capsule().strokeBorder(.separator))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func load() async {
        counts = (try? await bangumi.context.fetchCollectionCounts(subjectType: subjectType)) ?? [:]
        // 默认选中「在看」，其次「看过」（有数据的类型优先）。
        if let preferred = BangumiCollectionType.preferredAvailableType(in: counts) {
            selected = preferred
        }
        subjects = (try? await bangumi.context.fetchCollectionSubjects(
            subjectType: subjectType, collectionType: selected, limit: 12, offset: 0)) ?? []
        loaded = true
    }
}

/// 收藏横向条里的单张封面卡。
private struct CollectionTile: View {
    let subject: BangumiSubjectDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(url: coverURL, authHeader: nil)
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(width: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(subject.nameCN.isEmpty ? subject.name : subject.nameCN)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 84, alignment: .leading)
        }
    }

    private var coverURL: URL? {
        guard let image = subject.images?.large else { return nil }
        return URL(string: BangumiURL.imageURLString(from: image))
    }
}

extension BangumiCollectionType {
    /// 收藏列表默认优先「在看」，其次「看过」，再兜底任意有数据的类型。
    static func preferredAvailableType(in counts: [BangumiCollectionType: Int]) -> BangumiCollectionType? {
        for type in timelineTypes() where counts[type, default: 0] > 0 {
            return type
        }
        return allTypes().first { counts[$0, default: 0] > 0 }
    }
}

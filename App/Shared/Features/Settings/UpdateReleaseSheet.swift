import SwiftUI

/// 发现新版本时展示的更新说明弹窗
struct UpdateReleaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let release: GitHubRelease
    var onIgnore: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // 头部版本与日期
                    HStack(spacing: 14) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 32))
                            .foregroundStyle(.tint)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(release.name?.isEmpty == false ? release.name! : "发现新版本 \(release.tagName)")
                                .font(.title3.weight(.bold))

                            HStack(spacing: 8) {
                                Text("版本 \(release.tagName)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                if let date = release.publishedAt {
                                    Text("·")
                                        .foregroundStyle(.tertiary)
                                    Text(date, format: .dateTime.year().month().day())
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)

                    Divider()

                    // 更新日志内容
                    VStack(alignment: .leading, spacing: 8) {
                        Text("更新日志")
                            .font(.headline)

                        if let body = release.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(LocalizedStringKey(body))
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text("作者未提供详细更新日志。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 16)
                }
                .padding(20)
            }
            .navigationTitle("版本更新")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    HStack(spacing: 12) {
                        Button("忽略此版本") {
                            AppUpdateChecker.shared.ignoreVersion(release.tagName)
                            onIgnore?()
                            dismiss()
                        }
                        .foregroundStyle(.secondary)

                        Button("稍后再说") {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        openURL(release.htmlURL)
                        dismiss()
                    } label: {
                        Label("前往 GitHub 下载", systemImage: "arrow.down.circle.fill")
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        #if os(macOS)
        .frame(width: 540, height: 430)
        #endif
    }
}

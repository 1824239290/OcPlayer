import SwiftUI

/// 自动更新提示与关于页共用的版本说明窗口。
struct UpdateReleaseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    let release: GitHubRelease
    var onIgnore: (() -> Void)? = nil

    private var releaseTitle: String {
        if let name = release.name, !name.isEmpty { return name }
        return "发现新版本 \(release.tagName)"
    }

    var body: some View {
        VStack(spacing: 0) {
            AppSheetHeader(title: "版本更新", symbol: "sparkles", subtitle: releaseTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 8) {
                        Text("版本 \(release.tagName)")
                        if let date = release.publishedAt {
                            Text("·")
                            Text(date, format: .dateTime.year().month().day())
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    AppSheetDivider()
                    Text("更新日志").font(.callout.weight(.medium))
                    if let body = release.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(verbatim: body)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("作者未提供详细更新日志。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
            AppSheetDivider()
            AppSheetFooter {
                Button("忽略此版本") {
                    AppUpdateChecker.shared.ignoreVersion(release.tagName)
                    onIgnore?()
                    dismiss()
                }
                .buttonStyle(AppSheetButtonStyle())
            } actions: {
                Button {
                    openURL(release.htmlURL)
                    dismiss()
                } label: {
                    Label("前往下载", systemImage: "arrow.down.circle")
                }
                .buttonStyle(AppSheetButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .help("前往 GitHub 下载此版本")
            }
        }
        .appSheetSurface()
    }
}

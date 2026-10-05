import AppDesignKit
import SwiftUI

/// 设置 → 关于：版本、检查更新、开源许可证。
///
/// 开源许可证是**叶子页**（不再下推别的页面），保留
/// `navigationDestination(isPresented:)` + `coveredByPresented` 的呈现式写法。
struct AboutSettingsView: View {
    @Environment(AppModel.self) private var app
    /// 单例是引用类型，不需要 @State 的存储语义；let 即可（@Observable 变化照常驱动刷新）。
    private let updateChecker = AppUpdateChecker.shared
    @State private var presentedRelease: GitHubRelease?
    @State private var showLicenses = false

    var body: some View {
        Form {
            Section {
                KeyValueRow(label: "版本", value: AppVersion.displayString)
                UpdateCheckRow(
                    checker: updateChecker,
                    onShowRelease: { release in
                        presentedRelease = release
                    }
                )
                Button {
                    app.pushPresented { showLicenses = true }
                } label: {
                    LabeledContent(
                        "开源许可证",
                        value: "\(OpenSourceLicenseCatalog.componentCount) 个项目"
                    )
                }
                .buttonStyle(.plain)
            }
            .settingsRowBackground()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
        .navigationDestination(isPresented: $showLicenses) {
            OpenSourceLicensesView()
                .appShellBackChrome(title: "开源许可证", presented: $showLicenses)
                .pageEntrance()
        }
        // 呈现式页面不在 path 上，CoveredPageHider 看不见这层覆盖：落地期间
        // 本页整页隐去，别透过半透的许可证页漏出（见 coveredByPresented）。
        .coveredByPresented($showLicenses)
        .sheet(item: $presentedRelease) { release in
            UpdateReleaseSheet(release: release)
        }
        .task {
            if updateChecker.state == .idle {
                await updateChecker.checkForUpdates()
            }
        }
    }
}

// MARK: - 检查更新行

private struct UpdateCheckRow: View {
    let checker: AppUpdateChecker
    let onShowRelease: (GitHubRelease) -> Void

    var body: some View {
        HStack {
            Text("检查更新")
            Spacer()

            switch checker.state {
            case .idle:
                Button("检查") {
                    Task { await checker.checkForUpdates(isUserInitiated: true) }
                }

            case .checking:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检查…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

            case .upToDate:
                HStack(spacing: 8) {
                    Text("已是最新")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("重新检查") {
                        Task { await checker.checkForUpdates(isUserInitiated: true) }
                    }
                    .font(.callout)
                }

            case .updateAvailable(let release):
                HStack(spacing: 6) {
                    Button {
                        onShowRelease(release)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill")
                                .foregroundStyle(.tint)
                            Text(checker.ignoredVersion == release.tagName ? "发现新版本 \(release.tagName) (已忽略)" : "发现新版本 \(release.tagName)")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.tint)
                        }
                    }
                    .buttonStyle(.borderless)
                }

            case .failed(let message):
                HStack(spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                    Button("重试") {
                        Task { await checker.checkForUpdates(isUserInitiated: true) }
                    }
                    .font(.callout)
                }
            }
        }
    }
}

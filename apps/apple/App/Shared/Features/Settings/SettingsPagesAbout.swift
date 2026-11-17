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
        // 2026-10-22（B 方案）：设置页整体脱离 `Form`，改成 `ScrollView` + 玻璃卡片流
        // ——与 MoviePilot 下载页同一套承载；一段 = 一张 `SettingsGlassSection`。
        // 本页只有一段（版本 / 检查更新 / 开源许可证），段标题留空。
        SettingsGlassPage {
            SettingsGlassSection {
                KeyValueRow(label: "版本", value: AppVersion.displayString)
                SettingsGlassDivider()
                UpdateCheckRow(
                    checker: updateChecker,
                    onShowRelease: { release in
                        presentedRelease = release
                    }
                )
                SettingsGlassDivider()
                // 「标题 + 行尾值 + 可整行点」——`SettingsActionRow` 表达不了行尾值，
                // 所以自己拼一行：`HStack` + `Spacer` 保住「标签左 / 值右」的读法，
                // `maxHeight: .infinity` 让热区吃掉整行高（脱离 `Form` 后没有系统行底兜底）。
                Button {
                    app.pushPresented { showLicenses = true }
                } label: {
                    HStack(spacing: 8) {
                        Text("开源许可证")
                        Spacer(minLength: 8)
                        Text("\(OpenSourceLicenseCatalog.componentCount) 个项目")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationDestination(isPresented: $showLicenses) {
            OpenSourceLicensesView()
                .appShellBackChrome(title: "开源许可证", presented: $showLicenses)
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
            // 自动化深链（Debug-only）：`OCPLAYER_START_ROUTE=settings.about.licenses`
            // 的标记由宿主页（本页）消费并展开，走与手动点击同一条 pushPresented。
            if app.pendingPresentedLeaf == .licenses {
                app.pendingPresentedLeaf = nil
                app.pushPresented { showLicenses = true }
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

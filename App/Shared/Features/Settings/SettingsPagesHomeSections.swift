import SwiftUI

/// 设置 → 首页栏目：首页各栏的顺序与显隐。
struct HomeSectionsSettingsView: View {
    /// 原始串经 `HomeSectionPreference` 编解码；@AppStorage 可观察，
    /// 改完首页即时生效。
    @AppStorage(SettingsKeys.homeSections) private var homeSectionsRaw = HomeSectionPreference.defaultRaw
    private var homeSections: [HomeSection] { HomeSectionPreference.decode(homeSectionsRaw) }

    var body: some View {
        Form {
            Section {
                ForEach(homeSections) { section in
                    homeSectionRow(section)
                }
            } footer: {
                Text("拖动条目或用上下按钮调整顺序，开关控制显示与隐藏。")
            }
            .settingsRowBackground()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }

    // MARK: - 栏目行

    /// 一行：栏目名 + 上移/下移 + 显隐开关。用按钮排序而不是 List.onMove：
    /// grouped Form 里 onMove 要 iOS 的编辑态，macOS 没有对应入口，按钮双端一致。
    ///
    /// 上下按钮热区 44×44：原来挤在 2pt 间距里，iPhone 上误触率高。
    private func homeSectionRow(_ section: HomeSection) -> some View {
        let index = homeSections.firstIndex(of: section)
        return HStack(spacing: 14) {
            Label(section.title, systemImage: Self.sectionIcon(section))

            Spacer(minLength: 8)

            HStack(spacing: 0) {
                Button {
                    moveHomeSection(section, offset: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(index == 0)
                .accessibilityLabel("上移\(section.title)")

                Button {
                    moveHomeSection(section, offset: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(index == homeSections.count - 1)
                .accessibilityLabel("下移\(section.title)")
            }
            .buttonStyle(.borderless)

            Toggle("", isOn: sectionEnabledBinding(section))
                .labelsHidden()
                .accessibilityLabel("显示\(section.title)")
        }
    }

    private func moveHomeSection(_ section: HomeSection, offset: Int) {
        var sections = homeSections
        guard let index = sections.firstIndex(of: section) else { return }
        let target = index + offset
        guard sections.indices.contains(target) else { return }
        sections.swapAt(index, target)
        homeSectionsRaw = HomeSectionPreference.encode(sections)
    }

    /// 显隐开关：开启 = 追加到列表末尾（用上下按钮再挪位置），关闭 = 移出列表。
    private func sectionEnabledBinding(_ section: HomeSection) -> Binding<Bool> {
        Binding(
            get: { homeSections.contains(section) },
            set: { on in
                var sections = homeSections
                if on {
                    guard !sections.contains(section) else { return }
                    sections.append(section)
                } else {
                    // 全关掉首页只剩空态，是用户的明确选择，不拦。
                    sections.removeAll { $0 == section }
                }
                homeSectionsRaw = HomeSectionPreference.encode(sections)
            }
        )
    }

    private static func sectionIcon(_ section: HomeSection) -> String {
        switch section {
        case .resume: "play.circle"
        case .nextUp: "arrow.right.circle"
        case .latest: "clock"
        case .libraries: "square.stack"
        }
    }
}

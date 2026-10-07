import SwiftUI

/// 设置 → 首页栏目：首页各栏的顺序与显隐。
///
/// **列表永远列出全部栏目**（`layout.order` 含已关闭的）——关闭只是「首页不
/// 渲染」，行留在原位置、开关可随时再打开；`visible` 只用于首页与值预览。
/// 曾经这里是 `ForEach(存下来的栏目)`，于是关掉 = 行没了、再也打不开
/// （用户报的「关了就直接消失」），且顺序一起丢（重开只能追加到末尾）。
struct HomeSectionsSettingsView: View {
    /// 原始串经 `HomeSectionPreference` 编解码；@AppStorage 可观察，
    /// 改完首页即时生效。
    @AppStorage(SettingsKeys.homeSections) private var homeSectionsRaw = HomeSectionPreference.defaultRaw
    private var layout: HomeSectionLayout { HomeSectionPreference.decode(homeSectionsRaw) }

    var body: some View {
        Form {
            Section {
                ForEach(layout.order) { section in
                    homeSectionRow(section)
                }
            } footer: {
                Text("上下按钮调整顺序；开关只控制首页是否显示，关掉的栏目会留在这里，随时可以再打开（位置不变）。")
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
    /// 排序作用于**全序**（含已关闭的栏目）：关掉的行照样能上下移，先把位置排好
    /// 再打开。换位不改变其余条目的相对顺序，所以移动已关闭的行不影响首页观感。
    ///
    /// 上下按钮热区 44×44：原来挤在 2pt 间距里，iPhone 上误触率高。
    private func homeSectionRow(_ section: HomeSection) -> some View {
        let index = layout.order.firstIndex(of: section)
        let isVisible = layout.isVisible(section)
        return HStack(spacing: 14) {
            Label(section.title, systemImage: Self.sectionIcon(section))
                // 关掉的压暗：一眼看出「它还在，只是首页不显示」。
                .foregroundStyle(isVisible ? Color.primary : Color.secondary)

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
                .disabled(index == layout.order.count - 1)
                .accessibilityLabel("下移\(section.title)")
            }
            .buttonStyle(.borderless)

            Toggle("", isOn: sectionVisibilityBinding(section))
                .labelsHidden()
                .accessibilityLabel("在首页显示\(section.title)")
        }
    }

    private func moveHomeSection(_ section: HomeSection, offset: Int) {
        homeSectionsRaw = HomeSectionPreference.encode(layout.moving(section, by: offset))
    }

    /// 显隐开关：只切 `hidden`，**不挪位置**——关掉再打开回到原位置。
    ///
    /// set 里现取 `layout`（@AppStorage 每次都读盘），所以连着拨两个开关不会
    /// 拿旧快照互相覆盖。
    private func sectionVisibilityBinding(_ section: HomeSection) -> Binding<Bool> {
        Binding(
            get: { layout.isVisible(section) },
            set: { homeSectionsRaw = HomeSectionPreference.encode(layout.setting(section, visible: $0)) }
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

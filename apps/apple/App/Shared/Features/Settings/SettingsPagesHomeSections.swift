import AppDesignKit
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
        // `P2-14`：`layout` 是 computed property，**每次访问都完整 decode 一遍**
        // （`HomeSectionPreference.decode`：trim / split / 逐 token / Set 构造 /
        // `allCases.filter`）。原先这一屏在同一次 body 里读了它 **≥17 次**
        // （ForEach 一次 + 每行 `firstIndex`/`isVisible`/`count` 各一次）。
        //
        // 这里 hoist 成局部常量：一次 body 只 decode **一次**，各行共用。
        // ⚠️ **只 hoist 读路径**：写路径（`moveHomeSection` / 开关的 `set`）必须
        // 保留「现读现取」—— 那是防「连着拨两个开关时拿旧快照互相覆盖」的
        // （见 `sectionVisibilityBinding` 的注释）。
        let layout = layout
        // 2026-10-22（B 方案）：设置页整体脱离 `Form`，改成 `ScrollView` + 玻璃卡片流
        // ——与 MoviePilot 下载页同一套承载；一段 = 一张 `SettingsGlassSection`。
        return SettingsGlassPage {
            SettingsGlassSection {
                ForEach(Array(layout.order.enumerated()), id: \.element) { index, section in
                    if index > 0 { SettingsGlassDivider() }
                    homeSectionRow(section, layout: layout)
                }
            } footer: {
                Text("上下按钮调整顺序；开关只控制首页是否显示，关掉的栏目会留在这里，随时可以再打开（位置不变）。")
            }
        }
    }

    // MARK: - 栏目行

    /// 一行：栏目名 + 上移/下移 + 显隐开关。用按钮排序而不是 List.onMove：
    /// grouped Form 里 onMove 要 iOS 的编辑态，macOS 没有对应入口，按钮双端一致。
    ///
    /// 排序作用于**全序**（含已关闭的栏目）：关掉的行照样能上下移，先把位置排好
    /// 再打开。换位不改变其余条目的相对顺序，所以移动已关闭的行不影响首页观感。
    ///
    /// 上下按钮热区 44×44：原来挤在 2pt 间距里，iPhone 上误触率高。
    private func homeSectionRow(_ section: HomeSection, layout: HomeSectionLayout) -> some View {
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

            Toggle("", isOn: sectionVisibilityBinding(section, current: layout))
            .neutralSwitch()
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
    private func sectionVisibilityBinding(
        _ section: HomeSection,
        current: HomeSectionLayout
    ) -> Binding<Bool> {
        Binding(
            // `get` 用本次 body hoist 的那份（与显示一致，且省一次 decode）。
            get: { current.isVisible(section) },
            // `set` **必须现读**：`@AppStorage` 每次都读盘，写回时基于最新值才不会
            // 拿旧快照覆盖另一个刚被拨动的开关。换成 hoist 的 `current` 就会重新引入
            // 「连拨两个开关互相覆盖」的 bug。
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

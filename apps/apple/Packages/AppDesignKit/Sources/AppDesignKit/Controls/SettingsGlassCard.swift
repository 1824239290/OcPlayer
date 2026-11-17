import SwiftUI

// MARK: - 设置页的玻璃卡片流（B 方案）
//
// 这个文件提供**两件事**，读之前先分清：
//   ① `SettingsGlassCard`：一张玻璃卡 + 卡内行高模型（`SettingsCardRowLayout`）；
//   ② `SettingsGlassPage` / `SettingsGlassSection`：设置页的**承载**——`ScrollView`
//      卡片流，与 MoviePilot 下载页同一套。
//
// ## 为什么设置页整体脱离了 `Form`（而不是留在 Form 里换卡底）
//
// 两条路都实测过（2026-10-22 工装，macOS 26.6 + iOS 26.3 模拟器），结论是
// **`Form` 里做不出「一整段一张玻璃卡」**：
//
// * **逐行 `.listRowBackground(glass)`**：macOS 的 grouped `Form` 根本不执行这个修饰符
//   ——连不透明品红都不画（诊断页 A 组与纯 Form 对照组逐像素相同、全帧 98.6% 像素相等；
//   这也是仓库里 `settingsCard()` 当年只能写 `#if os(iOS)` 的真正原因）。iOS 能画，但
//   **逐行各画一块**：行界出 3px 暗线（luma 233.5 → 216.6）、圆角缝里透出原始氛围底、
//   系统分隔线压在玻璃上。玻璃不能取样玻璃，相邻两行的独立玻璃拼不回「一张卡」。
// * **一段塞成一行**（`Section { SettingsGlassCard { … } }`）：玻璃能画出来，iOS 上与
//   下载页卡片逐像素等价；但 **macOS 的 `Form` 自己给 section 加 13–14pt 侧缩进**，
//   卡比目标窄 26pt，负 padding 会裁字、负 `listRowInsets` 被接受但不生效。
//
// 两条都做不到「两端一致的整段玻璃」→ 设置页整体换承载（`SettingsGlassPage`），
// 这也是用户在看到第一版实机效果后拍板的方向（「现在效果太差了，你上方案 B 吧」）。
// `SettingsGlassCard` 上仍保留 `listRowInsets` / `listRowBackground` / `listRowSeparator`
// 三个修饰符：在 `ScrollView` 里它们是 no-op，留着是为了这个「卡」原语在 `Form` 里也能
// 直接放（未迁移的页面或将来的 sheet 可以用）。
//
// ## 行高从哪来（`SettingsCardRowLayout`）
//
// 卡片里不再是 List 的行，系统那套「行内边距 + 行最小高」全没了，行会挤成自然高度
// （`Toggle` 只有 ~22pt），行距从 58 掉到 22——既难看也丢热区。
//
// 逐个调用点补 `.settingsRow()` 是可行的，但设置页有 11 个页面、29 个分段、几十个
// 控件行，逐个补既容易漏（漏一处就那一行矮一截），也把「行高」这件承载层的事散进
// 业务代码。这里改用自定义 `Layout`：**每个直接子视图自动获得行最小高与行内边距**，
// 只有显式声明排布角色（`settingsCardCompact()` / `settingsCardInline()`）的子视图例外。
//
// 于是调用点只写内容，行高由承载层统一给——`SettingsNavRow` 里那个 `settingsRow()`
// 仍然有用（它给 `Button` 的 frame = 热区），两者叠加后的行距：
// **iOS 44 + 7×2 = 58**（对照产品 Rex 实测 57.8）、**macOS 30 + 6×2 = 42**
// （`Form` 时代实测 28，玻璃卡里 42 才有下载页那种量感）。

// MARK: - 紧凑子视图标记

/// 卡内子视图的排布角色。
enum SettingsCardRole: Equatable {
    /// 操作行：抬到最小行高（= 热区）并在上下各留 `rowVerticalInset`。
    case row
    /// 附注（说明小字）：不抬高度、上下各留一档小间距（贴住它所解释的那一行）。
    case note
    /// 分隔线等零间隙件：不抬高度、不留间距。
    case inline

    var verticalPadding: CGFloat {
        switch self {
        case .row: SettingsMetrics.rowVerticalInset
        case .note: SettingsMetrics.cardNoteVerticalPadding
        case .inline: 0
        }
    }
}

private struct SettingsCardRoleKey: LayoutValueKey {
    static let defaultValue = SettingsCardRole.row
}

public extension View {
    /// 声明本子视图在 `SettingsGlassCard` 里是**附注**：不抬到最小行高，上下只留 4pt。
    ///
    /// 只给**不是操作行**的东西：`SettingsNote` 那种说明小字、`notice(...)` 这类提示。
    /// 操作行（Toggle / Picker / 导航行 / 按钮）**不要**加。
    func settingsCardCompact() -> some View {
        layoutValue(key: SettingsCardRoleKey.self, value: SettingsCardRole.note)
    }

    /// 分隔线等零间隙件（`SettingsGlassDivider` 自己会用）。
    func settingsCardInline() -> some View {
        layoutValue(key: SettingsCardRoleKey.self, value: SettingsCardRole.inline)
    }
}

// MARK: - 行布局

/// 玻璃卡内部的纵向行布局：逐行按「最小行高 + 上下行内边距」排布。
///
/// 只做两件事：① 每行高度 = `max(自然高, cardRowMinHeight) + 2 × 行角色内边距`
/// （row 档 iOS 58 / macOS 42；note 档只留 4pt；inline 档 0）；
/// ② 宽度吃满提案，行内容在行框内按角色对齐。
///
/// 为什么不用 `VStack(spacing: 0)` + 逐行 `.settingsRow()`：见文件头——行高是承载层
/// 的职责，散到 11 个页面的几十个调用点上必然漏；`Layout` 能一次性给所有子视图，
/// 且紧凑件可以用 `LayoutValueKey` 精确豁免。
struct SettingsCardRowLayout: Layout {
    /// 行内容最小高（iOS 44 = HIG 热区 / macOS 30）。
    private var minHeight: CGFloat { SettingsMetrics.cardRowMinHeight }
    /// 行上下内边距（iOS 7 / macOS 6），与最小高合成行距（iOS 58 / macOS 42）。
    private var verticalInset: CGFloat { SettingsMetrics.rowVerticalInset }

    private func naturalSize(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    /// 一行的内容高：操作行抬到最小行高（= 热区），附注/分隔线不抬。
    private func contentHeight(_ size: CGSize, role: SettingsCardRole) -> CGFloat {
        role == .row ? max(size.height, minHeight) : size.height
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 宽度无界时（ScrollView 横向 / 理想尺寸探测）不能当成 0，否则整张卡会塌——
        // 退回「取各子视图理想宽的最大值」。
        let width = proposal.width ?? subviews
            .map { $0.sizeThatFits(.unspecified).width }
            .max() ?? 0
        // **零行时高度必须是 0**：否则卡上那层 `cardContentVerticalInset`（上下各 6）
        // 会留下一条 12pt 的玻璃空条（`ServersView` 的 profiles 为空时会走到）。
        guard !subviews.isEmpty else { return .zero }
        var height: CGFloat = 0
        for subview in subviews {
            let role = subview[SettingsCardRoleKey.self]
            let content = contentHeight(naturalSize(subview, width: width), role: role)
            height += content + role.verticalPadding * 2
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var y = bounds.minY
        for subview in subviews {
            let role = subview[SettingsCardRoleKey.self]
            let padding = role.verticalPadding
            let content = contentHeight(naturalSize(subview, width: bounds.width), role: role)
            // **锚点必须是 `.leading`（垂直居中），不是 `.topLeading`**。
            //
            // 2026-10-22 review 抓出的真 bug：`place(proposal:)` 里的 height 只是**提案**，
            // 不强制子视图尺寸——`Text` / `Toggle` / 没显式 frame 的 `Button` 一律按自己的
            // 自然高绘制。所以 `anchor: .topLeading` 会把行内容**贴在行顶**：`Toggle`
            // 自然高 ~22pt、行内容高 iOS 44 / macOS 30，于是它在 iOS 上偏上 11pt、
            // 分隔线看起来贴着下一行。hub 那 10 行因为 `SettingsNavRow` 自带
            // `settingsRow()`（minHeight = 行内容高）恰好填满，把这个 bug 掩盖了——
            // 所以只有渲染过子页（有 Toggle / Picker）才看得出来。
            subview.place(
                at: CGPoint(x: bounds.minX, y: y + padding + content / 2),
                anchor: .leading,
                proposal: ProposedViewSize(width: bounds.width, height: content)
            )
            y += content + padding * 2
        }
    }
}

// MARK: - 卡容器

/// 设置页的玻璃分段卡：`Section` 里放**一个**它，它内部装该段的所有行。
///
/// 用法（行间分隔线用 `SettingsGlassDivider()`，附注用 `SettingsNote`）：
///
/// ```swift
/// Section("服务") {
///     SettingsGlassCard {
///         SettingsNavRow(title: "媒体服务器", …) { }
///         SettingsGlassDivider()
///         SettingsNavRow(title: "Bangumi", …) { }
///     }
/// }
/// ```
///
/// 行高（最小高 44 + 上下各 7）由 `SettingsCardRowLayout` 自动施加，调用点不用管。
public struct SettingsGlassCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        // **调用点要给非空内容**：卡本体挂着 `cardContentVerticalInset` 与玻璃，
        // 零行时仍会画出一条 12pt 高的全宽玻璃条。`Layout` 侧已让零子视图的尺寸归零，
        // 但 padding + glassEffect 还在，所以**必须由调用点判空**（`ServersView` 的
        // profiles 为空那段就是这么处理的）。这里不做「悄悄变 EmptyView」的兜底：
        // 那样会让「明明写了内容却没显示」变成静默失败，比一条空条更难查。
        SettingsCardRowLayout {
            content
        }
        .padding(.horizontal, SettingsMetrics.cardContentInset)
        .padding(.vertical, SettingsMetrics.cardContentVerticalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        // **开关形态**：`Toggle` 的默认样式是**平台相关**的——iOS 是开关，macOS 却是
        // **复选框**。改造前设置页在 `Form` 里，Form 会把 macOS 的 Toggle 呈现成行尾开关；
        // 现在脱离 Form，不显式指定就会退回「✓ 标签」的复选框，与系统设置观感完全不同。
        .settingsToggleStyle()
        .liquidGlassCard(cornerRadius: SettingsMetrics.cardCornerRadius)
        // 仍保留这三个修饰符：A 方案（Form 承载）下它们是必需的行剥离；B 方案
        // （ScrollView 承载）下它们是 no-op。留着是为了让「卡」这一个原语在两种
        // 承载里都能直接放（未迁移的页面还能继续用 Form）。
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// 卡内行间分隔线：停在**文字左缘**（图标列 + 图标文字间距之后），
/// 与改造前 `separatorLeading` 的口径一致（改造前实测分隔线起点 = 卡缘 16 + 行内缩
/// 16 + 图标列 22 + 间距 15 = 69pt）。
///
/// **不用 `Divider()`**：`Divider` 的取向由**父栈**决定（纵向栈里画横线、横向栈里画
/// 竖线），而这里的父级是自定义 `Layout`，它不向子视图暴露取向——`Divider` 在
/// `Layout` 里会退化成零尺寸或竖线。所以自己画一条 1 物理像素的横线。
public struct SettingsGlassDivider: View {
    @Environment(\.displayScale) private var displayScale

    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(height: 1 / max(displayScale, 1))
            .padding(.leading, SettingsMetrics.iconColumnWidth + SettingsMetrics.iconLabelSpacing)
            .settingsCardInline()
    }
}

// MARK: - 分段（B 方案：ScrollView + 玻璃卡片流，与 MoviePilot 下载页同一承载）
//
// A 方案（保留 `Form`，一段塞成一个 List 行）在 macOS 上实测不可接受：grouped Form
// 自己给 section 加约 13–14pt 侧缩进、卡比目标窄 26pt，行距也塌（28pt 档），
// 观感与下载页的卡片差得远。用户 2026-10-22 拍板改 B：设置页整体脱离 `Form`，
// 换成 `ScrollView` + 卡片流——**和下载页一模一样的承载**，卡宽、行距、卡间距
// 全部由我们控制，两端观感一致。

/// 设置页的一段：可选段标题 + 一整块玻璃卡 + 可选段脚。
public struct SettingsGlassSection<Content: View, Footer: View>: View {
    private let title: String?
    private let content: Content
    private let footer: Footer

    public init(
        _ title: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.title = title
        self.content = content()
        self.footer = footer()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.sectionHeaderSpacing) {
            if let title, !title.isEmpty {
                // **段标题用 `.primary` 而不是 `.secondary`**（2026-10-22 真机实测改）：
                // 段标题不在卡上，直接压在**氛围照片**上。`.secondary` 是「实色底上 60%
                // 前景色」，落在中等亮度的照片上对比度不够（iPhone 真机「网络缓冲」那几行
                // 实测字与底只差 ~2 luma，等于消失）。本仓其它压在氛围图上的标题
                // （首页、MoviePilot 的栏标题）一律用 `.primary`，这里对齐。
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, SettingsMetrics.sectionHeaderInset)
            }

            SettingsGlassCard {
                content
            }

            footer
                .font(.caption)
                // 段脚也压在玻璃上，理由同 `SettingsNote`（那里有详细实测说明）。
                .foregroundStyle(.primary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SettingsMetrics.sectionHeaderInset)
        }
    }
}

public extension SettingsGlassSection where Footer == EmptyView {
    /// 无段脚的段（大多数设置段）。
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, content: content) { EmptyView() }
    }
}

// MARK: - 卡内行件（B 方案重写 Form 专有行形态）
//
// 脱离 `Form` 后，`Picker` / `TextField` 这些控件不再有系统那套「行尾值 + 车">"」的
// 行形态（Form 会给它们套 `.menu` 行 + trailing 布局）。这里把「标题 + 尾部控件」
// 这一形态显式写出来，各页直接用，避免每个调用点自己拼 HStack 拼出十来种偏差。

/// 通用「标题 + 尾部控件」行：标题左对齐、控件贴右，行高由承载层给。
public struct SettingsRow<Label: View, Trailing: View>: View {
    private let label: Label
    private let trailing: Trailing

    public init(
        @ViewBuilder label: () -> Label,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.label = label()
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 12) {
            label
            Spacer(minLength: 8)
            trailing
        }
    }
}

public extension SettingsRow where Label == Text {
    /// 文本标题 + 尾部控件的便捷构造。
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.init(label: { Text(title) }, trailing: trailing)
    }
}

/// 菜单选择行：标题 + 行尾下拉菜单（`Picker` 的 `.menu` 形态）。
public struct SettingsPickerRow<Value: Hashable, Content: View>: View {
    private let title: String
    @Binding private var selection: Value
    private let content: Content

    public init(
        _ title: String,
        selection: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self._selection = selection
        self.content = content()
    }

    public var body: some View {
        SettingsRow(title) {
            Picker(title, selection: $selection) {
                content
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            // 值预览在窄屏下不把标题挤没：菜单按钮自己可以缩，标题留在左边。
            .layoutPriority(1)
        }
    }
}

/// 文本输入行：标题 + 行尾输入框（密码行自动用 `SecureField`）。
public struct SettingsTextRow: View {
    private let title: String
    private let prompt: String
    @Binding private var text: String
    private let isSecure: Bool

    public init(_ title: String, text: Binding<String>, prompt: String = "", isSecure: Bool = false) {
        self.title = title
        self._text = text
        self.prompt = prompt
        self.isSecure = isSecure
    }

    public var body: some View {
        SettingsRow(title) {
            field
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: SettingsMetrics.cardTrailingFieldMaxWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var field: some View {
        if isSecure {
            SecureField(prompt, text: $text)
        } else {
            TextField(prompt, text: $text)
        }
    }
}

/// 自定义字段行：标题 + 行尾任意输入控件。
///
/// 给「输入框需要自己的链式修饰」的场景（`textContentType` / `autocorrectionDisabled` /
/// macOS `.roundedBorder` 之类，`SettingsTextRow` 包不住）。字段被限宽并右对齐，
/// 与 `SettingsPickerRow` 的行尾形态一致；输入框自己不要加 `.frame(maxWidth:)`。
public struct SettingsFieldRow<Field: View>: View {
    private let title: String
    private let field: Field

    public init(_ title: String, @ViewBuilder field: () -> Field) {
        self.title = title
        self.field = field()
    }

    public var body: some View {
        SettingsRow(title) {
            field
                // 与 `SettingsTextRow` 同口径：长值从**头部**溢出（尾部可见）——
                // 输入 URL / API Key 时尾部才是用户在核对的那截。
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: SettingsMetrics.cardTrailingFieldMaxWidth, alignment: .trailing)
        }
    }
}

/// 操作行：整行可点的一颗按钮（原 Form 里的 `Button { } label: { Label(…) }`）。
public struct SettingsActionRow: View {
    private let title: String
    private let icon: String?
    private let role: ButtonRole?
    private let action: () -> Void

    public init(
        _ title: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = systemImage
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SettingsMetrics.iconLabelSpacing) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: SettingsMetrics.iconGlyphSize, weight: .regular))
                        .frame(width: SettingsMetrics.iconColumnWidth, alignment: .center)
                }
                Text(title)
                Spacer(minLength: 8)
            }
            // **整行热区**：`Button` 的 frame 就是点击范围。承载层给的是「行内容高」
            // （iOS 44 / macOS 30）的提案，但提案**不强制**尺寸——必须自己写
            // `maxHeight: .infinity` 才会吃掉整行高，否则热区只有文字那 16–22pt
            // （2026-10-22 review 抓出：只写 `contentShape` 是不够的）。
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
        .accessibilityAddTraits(.isButton)
    }
}


// MARK: - 页面承载（B 方案：ScrollView，脱离 Form）

/// 设置页的**页面承载**：`ScrollView` + 竖向卡片流，与 MoviePilot 下载页同一套。
///
/// ## 为什么设置页要脱离 `Form`
///
/// A 方案（保留 `Form`、把一段塞成一行）在 macOS 上实测不可接受：grouped `Form`
/// 自己给 section 加约 13–14pt 侧缩进（卡比目标窄 26pt，负 padding 会裁字、
/// 负 `listRowInsets` 不生效），行距也被系统行内边距拿走，观感与下载页的卡片差很远。
/// B 方案把承载整个换掉：卡宽、卡间距、行距全部由我们控制，两端一致。
///
/// ## 代价（认下来的）
///
/// 丢掉的是 `Form` 自带的这些能力：`Toggle` / `Picker` / `TextField` 的**行尾布局**
/// （改由 `SettingsRow` / `SettingsPickerRow` / `SettingsTextRow` 显式给出）、
/// `Section` 的 header/footer 排版（改由 `SettingsGlassSection`）、List 的键盘与焦点
/// 漫游、`DisclosureGroup` 的展开动画（仍可用，只是样式不同）。
/// 无障碍方面每行仍是原生控件，读屏照旧；只是不再是 List 的行分组语义。
///
/// 用法：
/// ```swift
/// SettingsGlassPage {
///     SettingsGlassSection("服务") {
///         SettingsNavRow(…) { … }
///         SettingsGlassDivider()
///         SettingsNavRow(…) { … }
///     }
///     SettingsGlassSection("应用") { … }
/// }
/// ```
public struct SettingsGlassPage<Content: View>: View {
    private let content: Content
    /// 内容最大宽度：窗口再宽也不让卡片横铺到满屏——设置页是一列文字行，
    /// 一行拉到 1300pt 会读不动（改造前 `Form` 的居中窄列也正是这个原因）。
    private let maxContentWidth: CGFloat

    public init(
        maxContentWidth: CGFloat = SettingsMetrics.pageMaxContentWidth,
        @ViewBuilder content: () -> Content
    ) {
        self.maxContentWidth = maxContentWidth
        self.content = content()
    }

    @Environment(\.contentLeading) private var contentLeading

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing + 8) {
                content
            }
            .padding(.horizontal, contentLeading)
            .padding(.top, SettingsMetrics.pageTopInset)
            .padding(.bottom, SettingsMetrics.pageBottomInset)
            .frame(maxWidth: maxContentWidth, alignment: .leading)
            // 居中：宽窗口里卡片列居中（与改造前 Form 的窄列同一观感）。
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - 卡内开关形态（macOS 行尾开关）

/// macOS 的**行尾开关**样式：标签在左、开关贴右。
///
/// 为什么需要它：`Toggle` 的 `.switch` 样式在 macOS 上是「标签 + 开关紧挨着」的一颗
/// 短控件，只有塞进 `Form` 的行里才会被 Form 拉开成「标签靠左、开关靠右」——
/// 设置页改 B 方案后不再有 Form 那层容器，直接用就会变成「开关贴着文字」，
/// 与改造前和系统设置的观感都不一样（实测截图见 `/tmp/planb-playback.png`）。
///
/// iOS 不需要：iOS 的 `.switch` 样式本来就是整行排布（标签左、开关右），
/// 所以那边 `.settingsToggleStyle()` 是 no-op。
public struct SettingsSwitchToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            Toggle(isOn: configuration.$isOn) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

public extension View {
    /// 设置卡片流里的开关行形态（macOS 行尾开关 / iOS 原样）。
    /// 在 `SettingsGlassCard` 上挂一次即可，卡内所有 `Toggle` 都会跟随。
    @ViewBuilder
    func settingsToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(SettingsSwitchToggleStyle())
        #else
        self
        #endif
    }
}

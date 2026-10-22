import SwiftUI

// MARK: - 设置页的行原语
//
// 与 `KeyValueRow` 同一层级：设置页里重复出现的行身/行件，抽出来共用。
// 铁律不变——**只吃纯值**（String / 闭包），不 import 任何域模型。

/// 设置行的图标来源：SF Symbol 或品牌图（imageset 里的矢量资产）。
///
/// 品牌图这一支是 2026-10-13 加的（用户口径：「bangumi 的图标改成和 tabview 一样用 SVG、
/// moviepilot 也一样、tmdb 也是」）。**只吃资产名字符串**，不 import 任何域模型——
/// 资产解析走主 bundle（`Image(_:)` 的默认语义），包本身不知道资产在哪，
/// 这条与「本包只吃纯值」的铁律一致（同 `AppShellChrome` 的 `.brand`）。
public enum SettingsRowIconSource: Hashable, Sendable {
    /// SF Symbol 名。跟随 `.primary` 单色、按 `iconGlyphSize` 字号渲染。
    case symbol(String)
    /// 资产目录里的图像名（矢量 SVG）。`aspect` = 内容宽高比，用来在图标框里
    /// **保比例缩放**——字标（如 TMDB 的 TMDB wordmark，2.33:1）与方形 logo 必须
    /// 分别按宽 / 按高约束，否则要么溢出图标列、要么被压扁。
    case brand(name: String, aspect: CGFloat)
}

/// 行首图标：**单色** glyph，固定宽列。
///
/// 三件事：
/// * **单色**。改前用 `Label(_, systemImage:)`，图标吃的是系统强调色（蓝）。
///   对照产品 Rex 的行图标是白色单色（实测：glyph 亮到 254，而同一行卡内只有 79），
///   用户口径里「显得粗糙」最直接的一处就是这排蓝图标。这里固定 `.primary`，
///   跟随外观（日间深、夜间白）。
/// * **固定列宽**。SF Symbol 宽度随符号差很多，交给 `Label` 自动排版时文字 leading
///   会跟着图标宽度走；固定列宽后每行的文字左缘严格一致，分隔线的对齐位
///   （`SettingsMetrics.separatorLeading`）也才有确定的含义。
/// * **品牌图按框缩放**。资产自成一体（不受 `.primary` 约束的那几种是官方配色，
///   改色等于改品牌标识），所以只约束**外接框**：框 = `iconColumnWidth` ×
///   `iconGlyphSize`，图在里面保比例居中。
public struct SettingsRowIcon: View {
    public let source: SettingsRowIconSource

    public init(_ source: SettingsRowIconSource) {
        self.source = source
    }

    /// 便捷构造：SF Symbol。
    public init(symbol: String) {
        self.source = .symbol(symbol)
    }

    public var body: some View {
        Group {
            switch source {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: SettingsMetrics.iconGlyphSize))
                    .foregroundStyle(.primary)
            case .brand(let name, let aspect):
                BrandIcon(name: name, aspect: aspect)
            }
        }
        .frame(width: SettingsMetrics.iconColumnWidth, height: SettingsMetrics.iconGlyphSize)
        // 纯装饰：行义全在标题文字里，而 SF Symbol 自带无障碍描述
        // （`tv` → "TV"、`server.rack` → "Server rack"），不隐藏的话读屏会把
        // 「TV, Bangumi」连读一遍图标名。改前走 `Label` 时这一层是系统给的，
        // 换成手写 `Image` 就得自己声明。品牌图同理（`Image("bangumi-logo")`
        // 的默认描述是资产名本身，读出来更莫名其妙）。
        .accessibilityHidden(true)
    }

    /// 品牌图在图标框里的尺寸（保比例、按更紧的一维约束）。
    ///
    /// 抽成独立子视图而不是内联在 `body` 的 `switch` 里：那个位置既有
    /// `ViewBuilder` 的内联 `let`、又有连缀的 `frame`/`renderingMode`，
    /// 实测会让整个 `Group` 的类型推断塌掉（报 `generic parameter 'Content'
    /// could not be inferred`、并被当成 `TableColumn` 去匹配）。拆出来后推断
    /// 只在 6 行里发生，稳定。
    private struct BrandIcon: View {
        let name: String
        let aspect: CGFloat

        var body: some View {
            // 保比例地塞进图标框（几何见 `fittedSize(aspect:in:)`）。
            let box = CGSize(
                width: SettingsMetrics.iconColumnWidth,
                height: SettingsMetrics.iconGlyphSize
            )
            let fitted = SettingsRowIcon.fittedSize(aspect: aspect, in: box)
            return Image(name)
                // **`.renderingMode` 必须紧跟 `Image`**：它是 `Image` 自己的方法
                // （返回 `Image`），一旦先走 `.resizable()` / `.scaledToFit()`，
                // 类型就擦成 `some View` 了，再调会报
                // 「value of type 'some View' has no member 'renderingMode'」。
                //
                // **行图标一律单色**，品牌图也不例外（2026-10-13 用户口径：
                // 「把 tmdb 元数据补充的那个 logo 改成和 bangumi、moviepilot
                // 的一样的颜色」）。
                //
                // 显式写 `.template` 而不是「靠资产自己声明」：Bangumi / MoviePilot
                // 的 imageset 带 `template-rendering-intent`，TMDB 那份**没有**
                // （它是官方彩色渐变字标，资产层要保持原样给详情页与页脚署名用）。
                // 靠资产声明的话，「行图标必须单色」这条不变量就散落在
                // Contents.json 里——加第四个品牌图时谁也不会记得去改 JSON。
                //
                // 反过来说：**品牌配色只出现在它该出现的地方**——详情页
                // 「在 TMDB 打开」与设置页页脚署名走 `.original`，那两处是
                // 品牌标识展示，不归本视图管。
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: fitted.width, height: fitted.height)
                .foregroundStyle(.primary)
        }
    }

    /// 把 `aspect`（宽÷高）的图保比例塞进 `box`。
    /// 纯函数、可单测——两个 logo 的宽高比差 2.7 倍（bangumi 0.94 / tmdb 2.33），
    /// 「按哪一维约束」必须算准，否则字标会溢出图标列、把标题挤走。
    public static func fittedSize(aspect: CGFloat, in box: CGSize) -> CGSize {
        guard aspect > 0, box.width > 0, box.height > 0 else { return box }
        let byHeight = CGSize(width: box.height * aspect, height: box.height)
        if byHeight.width <= box.width { return byHeight }
        return CGSize(width: box.width, height: box.width / aspect)
    }
}

/// 行尾值预览（iOS 设置的行内值口径）：窄屏下中间截断，不换行。
/// 改前这段内联在 `SettingsView.hubRow` 里，子页要用只能再抄一份。
public struct SettingsRowValue: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// 行尾箭头（导航行用）。字号/色阶与改前一致，抽出来只是为了让「值 + 箭头」这一对
/// 在 hub 与子页里不会再各写一份。
public struct SettingsRowChevron: View {
    public init() {}

    public var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            // 箭头只是「这行可进入」的视觉提示，语义已由 `Button` 的 `isButton`
            // trait 表达；不隐藏的话读屏会多念一句 "chevron right"。
            .accessibilityHidden(true)
    }
}

/// 设置导航行：图标 + 标题 +（可选）值 + 箭头，整行可点。
///
/// **分隔线对齐**：`.alignmentGuide(.listRowSeparatorLeading)` 挂在标题文字自己的
/// `.leading` 上。**实测口径要说清楚**：iOS 16 起系统本来就按「行内首个文字的左缘」
/// 对齐分隔线，所以这个导轨与系统默认**落点完全相同**（2026-10-13 在 iPhone 17 Pro 上
/// 量过：去掉导轨后分隔线起点仍是 69pt，一字不差）。它留在这里是**把意图写成代码**
/// ——行内容将来若改成「图标不是第一个元素」或「标题不是首个文字」，系统会去对齐那个
/// 新的首个文字，而导轨保证它始终停在标题上。**它不是当下生效的修复**，别在别处引用
/// 它来解释分隔线位置；真正钉住位置的是
/// `AppTests/SettingsLayoutTests.testSeparatorStopsAtLabelLeading`。
public struct SettingsNavRow: View {
    public let title: String
    public let icon: SettingsRowIconSource
    public var value: String?
    public var action: () -> Void

    public init(
        title: String,
        icon: SettingsRowIconSource,
        value: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.value = value
        self.action = action
    }

    /// 便捷构造：SF Symbol 图标的行（绝大多数行都是这一种）。
    public init(
        title: String,
        systemImage: String,
        value: String? = nil,
        action: @escaping () -> Void
    ) {
        self.init(title: title, icon: .symbol(systemImage), value: value, action: action)
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SettingsMetrics.iconLabelSpacing) {
                SettingsRowIcon(icon)
                Text(title)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                Spacer(minLength: 8)
                if let value, !value.isEmpty {
                    SettingsRowValue(value)
                }
                SettingsRowChevron()
            }
            .settingsRow()
            // 行内那段 `Spacer` 的空档默认**不是**点击热区（`.buttonStyle(.plain)`
            // 只把热区给内容），点行中间会没反应——那正是「整行可点」这句注释
            // 想说的话。`.contentShape` 把热区铺满整行。
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // 行内边距自己声明：把「内容高 44（热区）」与「视觉行距 58」解耦，
        // 见 `settingsRowInsets()`。**必须挂在 Button 这一层**（行的直接子视图），
        // 挂进 label 里会被当成内容尺寸。
        .settingsRowInsets()
        // 值预览念成**值**而不是「标题后面拖一个词」：读屏读作
        // 「Jellyfin，jumusu，按钮」——标题是 label、值进 value，中间有自然的停顿，
        // 也是 iOS 系统设置里「设置项 + 当前值」的读法。图标与箭头已在各自原语里
        // `accessibilityHidden`，不会混进来。
        .accessibilityValue(value ?? "")
    }
}

/// 设置页的**说明行**：挂在某个控件下面的一小段解释文字。
///
/// 两件事与裸 `Text` 不同：
/// * **分隔线不切它**——说明是上一行的附属，中间横一条线会读成「另一项」；
/// * **leading 内缩到文字列**（`SettingsMetrics.separatorLeading`），于是它在视觉上
///   与上一行的标题对齐，「这一行控件 + 这行说明」是一组。
///
/// 判据（`Docs` 与注释同源的心智模型）：**解释某一行的**用它；
/// **解释整段的**放到 `Section(footer:)` 去——那是 iOS 设置的标准位置，
/// 卡片下方、段与段之间的留白里。
public struct SettingsNote: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.caption)
            // **玻璃上说明小字的对比度**（2026-10-22 真机实测，iPhone 17 Pro 播放页最明显）：
            // 改造前它压在 `Form` 的实色行底上，`.tertiary` 也读得清；换成玻璃后底色变成
            // 会透出氛围图的半透面、且玻璃自己会把底提亮，`.tertiary`（前景色 ~30%）
            // 直接糊成一片。改到 `.secondary`（~60%）仍然偏淡——于是这里用**显式不透明度
            // 而不是语义层级**：`primary` 的 0.82 在合成后的绝对差明显高于 `.secondary`，
            // 而且深浅两种外观下方向都对（深色=白 82%、浅色=黑 82%）。
            // 判据是「看不看得清」，不是「语义层级听起来对不对」。
            .foregroundStyle(.primary.opacity(0.82))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, SettingsMetrics.separatorLeading)
            .listRowSeparator(.hidden)
            // 卡内（`SettingsGlassCard`）是附注不是操作行：不抬最小行高、不加行内边距。
            .settingsCardCompact()
    }
}

// MARK: - 行身

public extension View {
    /// 设置页**复合行**（导航行 / 控件行）的行身。
    ///
    /// 施加的是**内容最小高**（`rowContentMinHeight`），不是行距——行距 = 内容高 +
    /// 行内边距，两者不是一回事。把「行距」当 minHeight 用会渲染出 88pt 的行
    /// （第一版就是这么错的，见 `rowContentMinHeight` 的注释）。
    ///
    /// **内容最小高就是按钮的热区**：`Button` 的 frame 即点击范围，所以这里取 44
    /// （HIG 最小点击区）。行距由 `settingsRowInsets()` 声明的纵向内边距压回 58pt
    /// ——「看着高」与「点得着」是两件事，两者都要满足。
    ///
    /// 逐行施加、而不是在 `Form` 上挂 `.environment(\.defaultMinListRowHeight,)`：
    /// 后者会把说明性的 caption 行一起抬起来，而 caption 是挂在控件下面的小字，
    /// 抬起来就成了一格空行。行高只给「真的是一行操作」的行。
    ///
    /// **2026-10-22（玻璃卡片流，B 方案）**：卡内那一行不再是 List 的行，
    /// `settingsRowInsets()` 声明的 `listRowInsets` 变成 no-op，行距改由承载层
    /// `SettingsGlassCard` 施加。这里给**内容最小高 = 整行热区**（iOS 44 / macOS 30，
    /// 见 `cardRowMinHeight`）；两者叠加后行距是 iOS 58 / macOS 42。
    func settingsRow() -> some View {
        frame(minHeight: SettingsMetrics.cardRowMinHeight)
    }

    /// 设置页复合行的**行内边距**：与 `settingsRow()` 配对使用，负责把内容高与
    /// 视觉行距解耦。
    ///
    /// 声明 `listRowInsets` 会把**系统的一整套行内边距整体替换**（横向也在内），
    /// 所以水平值必须照抄系统那档（`rowLeadingInset` = 16pt）——实测过：横向对齐
    /// 与改前逐像素一致。纵向那 7pt 是我们自己的旋钮，与内容高 44 相加得到 58 的行距。
    ///
    /// 与 `settingsRow()` 分开两个修饰符而不是合成一个：`.listRowInsets` 必须挂在
    /// **行自己**（`Section` 内的直接子视图）上，而 `settingsRow()` 是行内容自己调用的
    /// frame——两者作用对象不同，不能合。
    @ViewBuilder
    func settingsRowInsets() -> some View {
        #if os(iOS)
        listRowInsets(
            EdgeInsets(
                top: SettingsMetrics.rowVerticalInset,
                leading: SettingsMetrics.rowLeadingInset,
                bottom: SettingsMetrics.rowVerticalInset,
                trailing: SettingsMetrics.rowLeadingInset
            )
        )
        #else
        self
        #endif
    }
}

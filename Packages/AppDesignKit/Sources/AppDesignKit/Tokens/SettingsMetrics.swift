import SwiftUI

// MARK: - 设置页令牌（对照 Rex 的逐像素实测）
//
// 取值不是拍脑袋定的：2026-10-13 拿用户给的两张截图（Rex 的设置页 602×1308、
// 我们的设置页 359×782）逐像素量出来的。Rex 那张按 401pt 逻辑宽折算 = 1.5 px/pt，
// 我们那张按 402pt 逻辑宽折算 = 0.893 px/pt；两边的结论都另外用「占屏宽百分比」
// 交叉核对过（文字 leading 19.1% vs 18.7%，同一个位置），所以**比例可靠**，
// 绝对 pt 值有 ±1pt 量级的折算误差。
//
// 量到的差异只有四处（字号 / 文字 leading / 图标-文字间距 / 分隔线对齐**本来就一致**）：
//   ① 分段容器：Rex 每段一张圆角卡，填充 ≈ 白 10% 叠在氛围图上（页面 lum 49.7 →
//      卡内 71.6，Δ≈22，反解 α≈0.098）；我们**完全没有**（行底被设成全透）；
//   ② 行距（行心→行心）：Rex 57.8pt（卡高 173.3pt ÷ 3 行），我们 49.8pt；
//   ③ 图标：Rex 是**白色单色** glyph，且卡上没有色块 tile（实测无字形列 lum 77.3
//      ≈ 卡底 79.0）；我们用的是系统强调色蓝；
//   ④ 分段：Rex 三段（使用偏好 / 服务 / App）段段有标题，我们四段且最后一段没标题。
public enum SettingsMetrics {
    /// **iOS 档位的真值，与平台无关地写在这里。**
    ///
    /// 为什么不让下面的计算属性直接内联字面量：包测试在 CI 里只以
    /// `swift test --package-path` 跑在 macOS 上，`#if os(macOS)` 之外的分支**根本
    /// 不执行**——把 iOS 档位内联进 `#if`，改坏它 macOS 侧的测试毫无反应
    /// （独立复核实测：`rowContentMinHeight` 的 iOS 分支改成 0，78 条包用例全绿）。
    /// 拆出来之后，**改这几个常量在 macOS 上就会红**，CI 能拦住。
    public static let iOSRowContentMinHeight: CGFloat = 44
    public static let iOSRowVerticalInset: CGFloat = 7
    public static let iOSRowLeadingInset: CGFloat = 16

    /// 行**内容**的最小高度——注意这**不是**用户看到的行距。
    ///
    /// 行距 = 内容高 + 行内边距（见 `rowPitch`）。这条关系是 2026-10-13 在
    /// iPhone 17 Pro 模拟器上用探针量出来的（当时内边距还是系统那 30pt）：
    ///
    /// | 内容 minHeight | 实测行距 |
    /// | --- | --- |
    /// | 不加（自然高 22.3） | 52.3pt |
    /// | 58 | 88.0pt |
    /// | 28 | 58.0pt |
    /// | 44 + 自声明内边距 7×2 | 58.0pt ← 现值 |
    ///
    /// **第一版把「行距」直接当 minHeight 用（58），渲染出来是 88pt**——比对照产品
    /// 高出一半，一屏只剩五行。所以 token 的语义必须是「内容高」。
    ///
    /// **第二版（内容 28）解决了高度、留下一个真问题**：多出来的 30pt 是**系统的行
    /// 内边距、不属于按钮**，于是「看着 58pt 高、只有中间 28pt 点得着」——独立复核
    /// 实测热区只有 28pt，而当时的用例却拿行距去断言「满足 44pt 最小点击区」。
    ///
    /// **现在（内容 44）**：内容自己占满 HIG 的最小点击区（`Button` 的 frame 即热区），
    /// 同时**由我们自己声明行内边距**（`rowVerticalInset` 7×2）把它压回 58pt 总行距
    /// ——**行距不变、热区变对**。横向则照抄系统那档（`rowLeadingInset` 16pt），
    /// 因为声明 `listRowInsets` 会把横向一起替换（实测照抄后横向逐像素一致）。
    public static var rowContentMinHeight: CGFloat {
        #if os(macOS)
        // macOS 走原生分组表单的密度，不跟着手机抬。设置页改玻璃卡片流（B 方案）后，
        // 卡内行高由 `cardRowMinHeight` 给，这里保持 0 让仍在 `Form` 里的页面不变。
        0
        #else
        // HIG 最小点击区：低于此值会出现「行看着很高、点在空白处没反应」。
        iOSRowContentMinHeight
        #endif
    }

    /// 我们自己声明的行内边距（纵向），用来把 `rowContentMinHeight` 压回目标行距。
    ///
    /// 代价与收益：一旦声明 `listRowInsets`，**系统的行内边距就被整体替换**
    /// （横向也在内），所以水平值必须照抄系统那档（`rowLeadingInset`）。收益是
    /// 「内容高 ↔ 内边距」可以互相置换——同样 58pt 的总行距，能把 44pt 给热区。
    ///
    /// **2026-10-22（B 方案）macOS 从 0 改成 6**：设置页脱离 `Form` 后没有系统行内边距，
    /// macOS 的卡内行距完全由这里决定（30 + 6×2 = 42）。全仓已无 `Form` 页面消费这两个
    /// 令牌，所以这次改动不会带偏别处。
    public static var rowVerticalInset: CGFloat {
        #if os(macOS)
        // B 方案（2026-10-22）：设置页脱离 `Form` 后，卡内行不再有系统那套行内边距，
        // 行距完全由这里定。30（内容高）+ 6×2 = 42pt——改造前 macOS 分组表单实测
        // 行距 28pt 在玻璃卡里偏挤，42 才有下载页那种「一行」的量感。
        6
        #else
        iOSRowVerticalInset
        #endif
    }

    /// 行内容距卡片左缘（横向内边距）。**实测值**：卡片左缘距屏缘 16pt、
    /// 行内容再内缩 16pt（分隔线 69 = 16 + 16 + 图标列 22 + 间距 15）。
    /// 声明 `listRowInsets` 时必须照抄这一档，否则横向对齐会整体位移。
    public static var rowLeadingInset: CGFloat {
        #if os(macOS)
        0
        #else
        16
        #endif
    }

    /// `.insetGrouped` 行**自带**的上下内边距合计（iOS 26 实测 30pt：上 15 + 下 15）。
    ///
    /// **现在只作历史与对照用**：声明 `rowVerticalInset` 之后系统这 30pt 已被替换，
    /// 真正决定行距的是「内容高 + 我们声明的内边距」。留着它是为了记下「置换前是什么样」，
    /// 以及让「为什么改用 44+14」这件事有据可查（44 + 14 = 58 = 28 + 30，行距分毫未动）。
    public static let systemRowInsets: CGFloat = 30

    /// 卡内**操作行**的行距（行心 → 行心）。iOS 44 + 7×2 = **58**（对照产品 Rex 实测
    /// 57.8pt）；macOS 30 + 6×2 = **42**。
    ///
    /// 注意它是由「内容高 + 上下内边距」算出来的**模型值**，两侧同源、单看它恒真——
    /// 真正钉住渲染结果的是 `AppTests/SettingsLayoutTests.testRowPitchMatchesReferenceRhythm`
    /// （iOS，量真像素）与 `SettingsGlassMetricsTests.testMacRowModelMatchesTheDocumentedNumbers`
    /// （macOS，钉常量绝对值）。别再拿这条算式当「已验证」的证据。
    public static var rowPitch: CGFloat { cardRowMinHeight + rowVerticalInset * 2 }

    /// 图标列宽与图标-文字间距。
    ///
    /// 两者之和 = 文字 leading 距行内容左缘的距离，也是分隔线的对齐位（Rex 实测：
    /// 卡左缘 20pt、图标 ink 中心 30pt、文字 leading 76.7pt → 相对值 10 / 56.7）。
    /// 我们的行内容左缘同样在 20pt（`insetGrouped` 默认），所以文字 leading 定在
    /// 57pt 时屏幕绝对位置与 Rex 重合（实测我们现值 75.0pt、Rex 76.7pt）。
    ///
    /// 列宽给 22 而不是 20：SF Symbol 宽度随符号差很多（`server.rack` 18pt 字号下
    /// 就有 23.5pt 宽），列太窄会让宽符号左右溢出、贴到旁边那一列上。22 + 15 仍然是
    /// 37，文字 leading 与分隔线位置不受影响。
    public static var iconColumnWidth: CGFloat {
        #if os(macOS)
        16
        #else
        22
        #endif
    }

    public static var iconLabelSpacing: CGFloat {
        #if os(macOS)
        8
        #else
        15
        #endif
    }

    /// 分隔线的 leading 对齐位（相对行内容左缘）。
    /// 与「图标列 + 间距」同源，改一个另一个跟着走——分隔线必须停在文字左缘，
    /// 而不是图标左缘（那是 iOS 的默认口径，也是我们改前被量到的那一种）。
    public static var separatorLeading: CGFloat { iconColumnWidth + iconLabelSpacing }

    /// 图标 glyph 字号（SF Symbol 的 point size）。Rex 图标 ink 18.7 × 20.7pt。
    /// macOS 走原生表单的密度，不跟着手机抬。
    public static var iconGlyphSize: CGFloat {
        #if os(macOS)
        13
        #else
        18
        #endif
    }

    /// 段间距：上一张卡底 → 段标题 ink 顶的目标（Rex 实测 40.7pt）。
    /// 由 `listSectionSpacing` 施加，只在 hub 上收紧；子页保持系统默认。
    public static let sectionSpacing: CGFloat = 28

    // MARK: - 玻璃分段卡 / 卡片流（2026-10-22，B 方案）

    /// 玻璃卡**内部内容**距卡缘的横向缩进（卡内左右留白）。
    /// 16 与 MoviePilot 下载任务卡的内边距同档，也与改造前 iOS 行内容距卡缘的 16 一致。
    public static var cardContentInset: CGFloat { 16 }

    /// 玻璃卡内容区距卡顶/卡底的纵向留白（行自己已带上下内边距，这里补一档呼吸位）。
    public static var cardContentVerticalInset: CGFloat { 6 }

    /// 玻璃卡圆角——直接用全站统一 token（`Metrics.glassCardRadius` = 16），
    /// 不再单独维护一个值：用户口径「与下载页同一套玻璃」的第一层落点就是圆角一致。
    public static var cardCornerRadius: CGFloat { Metrics.glassCardRadius }

    /// 卡内**操作行**的内容最小高（也就是整行热区）：iOS 44（HIG 最小点击区）、
    /// macOS 30（比原状表单行 28 略松，玻璃卡里太密会显得脏）。
    /// 行距 = 它 + 上下各 `rowVerticalInset` = iOS 58 / macOS 42。
    public static var cardRowMinHeight: CGFloat {
        #if os(macOS)
        30
        #else
        iOSRowContentMinHeight
        #endif
    }

    /// 卡内**附注**（说明小字）的上下留白：比操作行小得多，让附注读起来是「上一行的注解」
    /// 而不是独立一格。
    public static var cardNoteVerticalPadding: CGFloat { 4 }

    /// 段标题 → 卡片顶的间距（iOS 设置口径 ≈8pt）。
    public static var sectionHeaderSpacing: CGFloat { 8 }

    /// 段标题 / 段脚相对卡缘的横向余量（标题比卡内文字再外扩一点点，读起来是「段的标题」）。
    public static var sectionHeaderInset: CGFloat { 4 }

    /// 设置页（ScrollView 卡片流）滚动内容的上下内边距。
    ///
    /// **底部要够**：iOS 26 的标签栏是**悬浮玻璃胶囊**，它压住的是一条视觉浮层、
    /// 不一定算进 `safeAreaInsets`——只留 56 时最后一整张卡会被压在胶囊底下
    /// （实测 iPhone 17 Pro：设置页「应用」段的卡片直接被 Tab 栏盖住）。
    /// 96 是「胶囊高 + 与内容之间一档呼吸位」的量。
    public static var pageTopInset: CGFloat { 16 }
    public static var pageBottomInset: CGFloat {
        #if os(macOS)
        56
        #else
        96
        #endif
    }

    /// 卡内行尾输入框的最大宽度：更宽的行里输入框不跟着无限拉长，
    /// 保住「标签在左、值在右」的阅读顺序。
    public static var cardTrailingFieldMaxWidth: CGFloat { 260 }

    /// 设置页内容列的最大宽度。
    ///
    /// 设置页是一列文字行，卡片横铺到 1300pt 会读不动；改造前 `Form` 的窄列
    /// （1440 窗口里卡宽约 700）正是这个原因。macOS 窗口更宽，给 780；
    /// iOS iPad 全屏也只到 760 就够（iPhone 上远达不到，等于 no-op）。
    public static var pageMaxContentWidth: CGFloat {
        #if os(macOS)
        780
        #else
        720
        #endif
    }
}

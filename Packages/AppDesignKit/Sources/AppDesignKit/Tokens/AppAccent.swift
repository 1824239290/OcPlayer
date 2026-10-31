import SwiftUI

/// App 的强调色语言：**中性**（不用色相表达「强调 / 选中」）。
///
/// 与 macOS 顶栏药丸、iOS 标签栏同一套口径：选中与强调只靠**前景色的亮暗差**
/// 表达（`.primary` vs `.secondary`），色相不参与。落地方式是根节点钉一次
/// `RootView` 的 `.tint(.primary)`——`Color.accentColor` 与 `.foregroundStyle(.tint)`
/// **都会跟着环境 tint 走**，所以全 App 吃强调色的元素自动变中性，不必逐个改。
///
/// 这里只放**系统不会自动处理**的那几支配方：tint 是 `.primary` 时，系统**不会**
/// 给实底按钮换反色字——`.buttonStyle(.borderedProminent)` 与自绘的
/// `.fill(Color.accentColor)` 会整颗糊成**白底白字**（模拟器实测：按钮变成一个
/// 看不出文字的白色胶囊）。凡是「实底强调」都要显式点名 `onSolid`。
///
/// ⚠️ 系统按钮（`borderedProminent`）**不吃 `onSolid`**：它的标签由系统着色，
/// `.foregroundStyle(onSolid)` 挂在 `buttonStyle` 之后在 macOS 26 上会被丢弃
/// （后果是浅色模式黑底黑字）。系统按钮要走 `.tint(solidTint)`，让系统自己算反色
/// ——细节与实测数据见 `neutralProminentButton()`。
public enum AppAccent {
    /// 实底强调（主行动按钮、选中态实底）的填充色。
    public static let solid = Color.primary

    /// 交给**系统按钮**（`.borderedProminent`）的实底 tint。
    ///
    /// 与 `solid` 视觉等价（浅色黑、深色白），但**语义不同**：`Color.primary` 是
    /// 「内容前景色」，系统拿它当 tint 时**算不出对比度**，于是填了实底却仍按
    /// 「标签保持默认前景」渲染——浅色下就是**黑底黑字**（见 `neutralProminentButton()`
    /// 的注释：`/preview` 上实测整颗胶囊看不见文字）。`.labelColor` / `.label` 是
    /// 系统自己的「标签反色」语义色，`borderedProminent` 会照它把标签换成反色。
    public static var solidTint: Color {
        #if canImport(UIKit)
        Color(uiColor: .label)
        #elseif canImport(AppKit)
        Color(nsColor: .labelColor)
        #else
        .primary
        #endif
    }

    /// 压在 `solid` 上的文字 / 图标色，即 `solid` 的反色：深色模式近黑、浅色模式近白。
    public static var onSolid: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color.black
        #endif
    }

    /// 开关（`Toggle`）的轨道色：`primary` 压到 30%。
    ///
    /// **不能直接吃根节点的 `.tint(.primary)`**：开关的圆点在深色模式下是白的，而
    /// `.primary` 会让**开态轨道也是白的**——实测开、关两态都渲染成一颗纯白胶囊，
    /// 圆点与状态一起消失（用户口径：「开的时候变成全白了」）。
    ///
    /// 0.30 是量出来的折中（模拟器逐行取样，圆点恒为白）：
    /// 深色下轨道 `rgb(140,140,142)`、与圆点差 115；浅色下轨道 `rgb(138,138,139)`、
    /// 与圆点差 117——两种外观都读得出「亮的是圆点、暗的是轨道」。0.45 在深色下只剩
    /// 差 91（圆点开始糊），0.60 只剩 66（基本看不见）。
    public static let switchTrack = Color.primary.opacity(0.30)
}

extension View {
    /// 中性强调色下的**实底主行动**按钮（替代裸的 `.buttonStyle(.borderedProminent)`）。
    ///
    /// ## 为什么是 `.tint(solidTint)` 而不是补反色字
    ///
    /// 早先这里写的是 `buttonStyle(.borderedProminent)` + `.foregroundStyle(onSolid)`，
    /// 理由是「填充吃 tint，系统不会换反色标签，所以自己补上」。**这个补法在
    /// macOS 26 上不生效**：`.foregroundStyle` 挂在 `buttonStyle` **之后**时，
    /// `borderedProminent` 不把它传给标签（`ImageRenderer` 实测，浅色下按钮是
    /// 黑底黑字 `rgb(8,8,8)` 底 + `rgb(0,0,0)` 字，整颗看不见；深色下碰巧正常，
    /// 因为浅底配默认黑字——这是它长期没被发现的原因）。
    ///
    /// 正确做法是让**系统自己去算**对比度：tint 换成 `solidTint`（`.labelColor` /
    /// `.label`，与 `.primary` 同值但语义是「标签色」），系统就会把标签渲染成反色。
    /// 实测深 / 浅两种外观、常态 / 禁用态四组合里文字与底的对比度都 ≥ 4.5:1，
    /// 且按压态、禁用态、圆角、内边距全部沿用系统实现。
    ///
    /// 回归用例见 `AppAccentTests.testNeutralProminentButtonIsReadable*`——那组用例
    /// **直接渲染本方法**（而不是复刻配方），正因为早先只有复刻品被量过，才让这个
    /// 真实路径的 bug 溜了过去。
    public func neutralProminentButton() -> some View {
        buttonStyle(.borderedProminent)
            .tint(AppAccent.solidTint)
    }

    /// 中性强调色下的开关（挂在 `Toggle` 上）。
    ///
    /// 与 `neutralProminentButton()` 同一类：系统控件吃根节点的 tint，而 `.primary`
    /// 对开关是**不可用**的值（深色下开关全白，开 / 关两态都读不出来）。凡是 `Toggle`
    /// 都要挂这一句——目前没有共用的行组件可挂，所以是逐个调用点；新增开关时别忘。
    ///
    /// **两个平台都挂**：本仓的 `Toggle` 全都落在 `NavigationStack + Form` 里
    /// （设置 10 个子页 + MoviePilot 订阅 sheet），macOS 在这个上下文下渲染的是
    /// **开关**而不是复选框（macOS 真实设置页实拍确认）；裸 `Form` 的探针会渲染成
    /// 复选框，那是探针上下文与 App 不同，不能照搬结论。
    public func neutralSwitch() -> some View {
        tint(AppAccent.switchTrack)
    }
}

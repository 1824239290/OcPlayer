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
public enum AppAccent {
    /// 实底强调（主行动按钮、选中态实底）的填充色。
    public static let solid = Color.primary

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
    /// 存在的唯一理由：`borderedProminent` 的填充吃 tint，tint 是 `.primary` 时填充变
    /// `.primary`，而系统**不会**把标签换成反色——直接裸用会得到一颗白底白字、看不见
    /// 文字的按钮（模拟器实测）。这里把反色字一并补上，调用点不必各自记得。
    public func neutralProminentButton() -> some View {
        buttonStyle(.borderedProminent)
            .foregroundStyle(AppAccent.onSolid)
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

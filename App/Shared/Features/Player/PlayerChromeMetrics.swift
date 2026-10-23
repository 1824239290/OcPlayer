import SwiftUI

/// 播放 HUD 的系统 chrome 让位预算（iOS 灵动岛 / 屏幕圆角 / 状态栏带）。
///
/// RootView 把整棵 PlayerScreen 用无参 `.ignoresSafeArea()` 包住（视频、黑底、
/// 弹幕都要全屏 bleed），子树内安全区随之归零、读不到系统禁区。外层读到的
/// 真实安全区经 `\.playerChromeInsets` 环境值「绕过」ignoresSafeArea 传进来，
/// HUD 各锚点用下面的公式做让位，其余各层照旧全屏。
///
/// - 横屏正常态（播放锁横屏后）顶部 inset 为 0、侧边 inset 即灵动岛/圆角禁区
///   （灵动岛机型约 59pt）：侧边锚点让出禁区，顶部维持原状。
/// - 竖屏（进播放锁横屏生效前的窗口期）：顶部药丸带约 59pt，顶部锚点让位。
/// - macOS 无系统 insets（环境值恒 .zero），公式全部退化到原有固定常量，
///   与窗口标题栏让位逻辑（PlayerHUDTopBar 的 56/58）互不相扰。
enum PlayerChromeMetrics {

    /// HUD 顶栏顶距：安全区之外保留原有呼吸间距（14/22）。
    static func topBarTopPadding(_ insets: EdgeInsets, isNarrow: Bool) -> CGFloat {
        insets.top + (isNarrow ? 14 : 22)
    }

    /// HUD 元素的水平边距：侧边安全区与原有呼吸间距（16/28）取大——
    /// 有禁区让禁区，没禁区维持现状。
    static func sidePadding(_ insets: EdgeInsets, isNarrow: Bool) -> CGFloat {
        max(insets.leading, insets.trailing, isNarrow ? 16 : 28)
    }

    /// 信息面板顶距：原 70/82 是「避开顶栏」的手算值，顶栏整体让位后
    /// 跟着平移同样的量。
    static func infoPanelTopPadding(_ insets: EdgeInsets, isNarrow: Bool) -> CGFloat {
        insets.top + (isNarrow ? 70 : 82)
    }

    /// 亮度 OSD 徽章顶距（顶部中央，竖屏窗口期正对灵动岛药丸）。
    static func osdTopPadding(_ insets: EdgeInsets) -> CGFloat {
        insets.top + 14
    }
}

private struct PlayerChromeInsetsKey: EnvironmentKey {
    static let defaultValue: EdgeInsets = EdgeInsets()
}

extension EnvironmentValues {
    /// 播放覆盖层的系统安全区：RootView 在 ignoresSafeArea 之外读到的真实值，
    /// 转屏时随布局更新；默认 .zero = 无系统禁区。
    var playerChromeInsets: EdgeInsets {
        get { self[PlayerChromeInsetsKey.self] }
        set { self[PlayerChromeInsetsKey.self] = newValue }
    }
}

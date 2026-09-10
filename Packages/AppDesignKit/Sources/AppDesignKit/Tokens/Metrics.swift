import SwiftUI

// MARK: - 尺寸 token（design/apple-native.html）

public enum Metrics {
    public static let posterWidth: CGFloat = 178      // 海报 2:3
    public static let stillWidth: CGFloat = 328       // 剧照 16:9
    /// 紧凑布局（iPhone 竖屏 / iPad 分屏窄窗）的卡片宽度。
    public static let compactPosterWidth: CGFloat = 120
    public static let compactStillWidth: CGFloat = 240
    public static let cardRadius: CGFloat = 10
    /// 选集卡圆角。比 `cardRadius` 略小，选集卡在详情页里尺寸更小、更密集，
    /// 和海报/剧照卡用同一个圆角会显得偏圆。`EpisodeSelectCard` 与 `SkeletonEpisodeStrip` 共用。
    public static let episodeCardRadius: CGFloat = 8
    public static let railSpacing: CGFloat = 22
    public static let contentInset: CGFloat = 52
    /// 紧凑宽度（iPhone、iPad 分屏窄窗）的横向留白。
    public static let compactContentInset: CGFloat = 22
    /// Rail 横向 ScrollView 上下为悬停放大预留的内边距（上下各一档）。
    public static let railHoverPadding: CGFloat = 28

    /// 详情页横幅高度与横幅内主操作行高。真实内容和骨架共用同一组常量，
    /// 免得改了一边忘了另一边、骨架撤掉时横幅高度跳一下。
    public static let bannerHeight: CGFloat = 320
    public static let bannerActionHeight: CGFloat = 40

    /// 详情页横向选集卡尺寸（`EpisodeSelectCard` 与它的骨架共用）。
    public static let episodeCardWidth: CGFloat = 200
    public static let episodeThumbHeight: CGFloat = 112

    /// 海报卡（图 2:3 + 标题行）在 Rail 里的可视高度，含 hover 留白。
    public static func posterRailHeight(compact: Bool = false) -> CGFloat {
        let w = compact ? compactPosterWidth : posterWidth
        return w * 1.5 + 9 + 22 + railHoverPadding * 2
    }

    /// 剧照卡（16:9 + 进度条 + 两行文案）在 Rail 里的可视高度，含 hover 留白。
    public static func stillRailHeight(compact: Bool = false) -> CGFloat {
        let w = compact ? compactStillWidth : stillWidth
        return w * 9 / 16 + 6 + 3 + 10 + 40 + railHoverPadding * 2
    }

    /// 加载占位的统一灰。骨架块和 `RemoteImage` 的图片占位都用它——
    /// 两边取值不同的话，骨架撤掉换成真实卡片、而图还在下载的那一瞬间，
    /// 整墙灰块会明显「变深一档」。
    public static let placeholderTint: Double = 0.08
    public static var placeholderFill: Color { Color.primary.opacity(placeholderTint) }
}

// MARK: - 横向留白（跟窗口宽度走，不跟设备型号走）

private struct ContentLeadingKey: EnvironmentKey {
    static let defaultValue: CGFloat = Metrics.contentInset
}

public extension EnvironmentValues {
    /// 页面横向留白，由 `AppShellView` 按 `horizontalSizeClass` 注入。
    ///
    /// **不能用 `UIDevice.current.userInterfaceIdiom` 判断**：那是设备属性而不是窗口属性。
    /// iPad 拖到 1/3 宽时 `horizontalSizeClass` 已经是 `.compact`，但 idiom 仍然是 `.pad`，
    /// 于是窄窗里左右各留 52pt——内容区只剩 216pt，一张 178pt 的海报都排不出第二列。
    var contentLeading: CGFloat {
        get { self[ContentLeadingKey.self] }
        set { self[ContentLeadingKey.self] = newValue }
    }
}

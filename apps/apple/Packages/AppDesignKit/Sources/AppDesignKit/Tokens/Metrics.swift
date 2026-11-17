import SwiftUI

// MARK: - 尺寸 token（design/apple-native.html）

public enum Metrics {
    public static let posterWidth: CGFloat = 178      // 海报 2:3
    public static let stillWidth: CGFloat = 328       // 剧照 16:9
    /// 紧凑布局（iPhone 竖屏 / iPad 分屏窄窗）的卡片宽度。
    public static let compactPosterWidth: CGFloat = 120
    public static let compactStillWidth: CGFloat = 240
    /// 首页「最近添加」的卡宽：**16:9 横版**，不是海报。
    ///
    /// 版式照 Rex 的首页「最近更新」定（2026-10-11 对照截图实测，430pt 宽的机器）：
    /// 那一栏的卡是 16:9 横版、宽 ≈ 屏宽的 41%（176pt），同屏「继续观看」的剧照卡
    /// 是 59%（251pt）——参考产品的口径就是「最近添加比剧照卡小一档」。本 App 原先
    /// 这一栏用的是 2:3 海报卡（紧凑 120 宽 / 180 高，面积是 Rex 那张的两倍多），
    /// 用户对照后给的口径是「他们的最近添加比例较小」。165 = 402pt × 41%。
    public static let compactLatestWidth: CGFloat = 165
    /// 常规宽度（macOS / iPad 全屏）的同款卡宽：`stillWidth` × 0.70，与紧凑端
    /// 165 / 240 ≈ 0.69 同一口径（同排比剧照卡小一档）。
    public static let latestWidth: CGFloat = 230
    public static let cardRadius: CGFloat = 10

    // MARK: - 液态玻璃圆角（2026-10-22 全站统一）

    /// **内容卡的统一圆角**：全站所有 `liquidGlassCard` 都用它，不再按页面各写 10/12/14/16/18。
    ///
    /// 取 16 是因为用户口径把「MoviePilot 下载队列的卡」定为基准（那边本来就是 16）；
    /// 统一之后切页时卡片圆角不会跳，视觉上才像同一套语言。
    public static let glassCardRadius: CGFloat = 16

    /// **嵌在玻璃卡里的次级小卡**（信息格 / 统计格 / 选集网格）的圆角。
    ///
    /// 取 8 而不是同样 16：外层卡 16 + 内边距 8 的同心圆角正好收敛到 8（Apple 的
    /// 同心圆角规则），内层再画 16 会显得「圆角套圆角、里外不平行」。
    /// 也用于纯色底的小格（如选集格），让它们与玻璃小卡的轮廓一致。
    public static let glassNestedRadius: CGFloat = 8
    /// 选集卡圆角。比 `cardRadius` 略小，选集卡在详情页里尺寸更小、更密集，
    /// 和海报/剧照卡用同一个圆角会显得偏圆。`EpisodeSelectCard` 在用。
    ///
    /// **2026-10-22 与 `glassNestedRadius` 对齐成同一个值**：选集格与玻璃卡里的
    /// 次级小卡在页面上是同一档「嵌套小卡」，两者圆角若不同，并排时轮廓会打架。
    /// 两个名字都留着（语义不同：一个是选集格，一个是嵌套小卡），值锁死在 8。
    public static let episodeCardRadius: CGFloat = 8
    public static let railSpacing: CGFloat = 22
    /// Rail 标题与内容行之间的间距。
    ///
    /// 与 `railHoverPadding` 相加才是「标题 → 封面」的可见留白（滚动内容自己还顶着
    /// 一段悬停内边距）。Rex 那档参考产品实测 ≈17pt（430pt 机器、像素实测：
    /// 「最近更新」标题 ink 底 435.0pt → 封面顶 450.7pt），我们 10 + 16 = 26pt、
    /// 连行盒下伸部在真机上是 28.5pt——刻意比它松一点，因为我们的卡在悬停时会
    /// 放大 1.055，完全贴到标题会打架。
    public static let railHeaderSpacing: CGFloat = 10
    /// 每个 Rail 自己的顶部内边距（上一栏内容底 → 本栏标题）。
    public static let railTopInset: CGFloat = 18
    public static let contentInset: CGFloat = 52
    /// 紧凑宽度（iPhone、iPad 分屏窄窗）的横向留白。
    public static let compactContentInset: CGFloat = 22
    /// 紧凑宽度海报墙的**最小列宽**。402pt 宽的手机（iPhone 16/17 Pro）扣掉左右
    /// 各 22pt 页面留白后是 358pt：按它排正好 **3 列 × 112.7pt**，与隔壁 Rex 的
    /// 媒体库版式同观感（截图像素实测 ≈118pt × 3 列）。取值判据见 `PosterGrid`。
    public static let compactGridPosterMinWidth: CGFloat = 100
    /// 拿不到图片真实比例时，海报卡**兜底**用的框比例（宽 ÷ 高）。
    ///
    /// 取 **0.70** 而不是教科书 2:3（0.667）：实测本机 Jellyfin 库 26 部剧集里
    /// **22 部是 0.7013**、2 部 0.75、3 部 0.6667——兜底取多数派，能把「比例还没到手」
    /// 那一小段的偏差从 11%（按 2:3 铺 0.70 的图）降到 4.5%。真正决定观感的是跟随
    /// 图片自己的比例（见 `MediaArtwork`），这里只影响加载中的那一拍。
    public static let posterFallbackRatio: CGFloat = 0.70
    /// 紧凑海报墙的列距（Rex 实测 ≈10pt；常规宽度网格走 `railSpacing`）。
    public static let compactGridColumnSpacing: CGFloat = 10
    /// 紧凑海报墙的行距（Rex 实测 ≈16pt）。
    public static let compactGridRowSpacing: CGFloat = 16
    /// Rail 横向 ScrollView 上下为悬停放大预留的内边距（上下各一档）。
    ///
    /// **28 → 16（2026-10-11）**。28 是「上一个栏位的内容底 → 下一栏标题」里最大的一块：
    /// 它加上 `railTopInset` 再叠上卡高与 Rail 固定框高之差，就是首页栏位之间那段
    /// 空白——真机截图上量到 66–73pt（用户口径「每个栏位之间间距没那么大」），
    /// 而 Rex 同位置只有 ≈42pt（对照截图像素实测：卡底 → 下一栏标题 ink 顶）。
    /// 16 与 `railTopInset` 18、`railHeaderSpacing` 10 一起把这段收到 **42.5pt**。
    ///
    /// **下限由悬停抬升定死**：`hoverLift` 放大 1.055，最大的卡是常规海报
    /// （178 宽 / 267 高），抬起来上下各多 7.4pt——低于 8pt 就会把抬起时的卡片顶端
    /// 压到上一栏的标题上。16 留了一倍余量（投影半径 14 也基本落在框内）。
    public static let railHoverPadding: CGFloat = 16

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

    /// 首页「最近添加」卡（16:9 横版 + 两行文案，**没有进度条那一条**）在 Rail 里的
    /// 可视高度，含 hover 留白。结构照 `StillCard` 去掉「6 + 3」的进度轨。
    public static func latestRailHeight(compact: Bool = false) -> CGFloat {
        let w = compact ? compactLatestWidth : latestWidth
        return w * 9 / 16 + 10 + 40 + railHoverPadding * 2
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

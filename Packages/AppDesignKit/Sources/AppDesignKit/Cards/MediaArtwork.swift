import SwiftUI

/// 比例闸门的**上界**（见 `MediaArtwork.clamped`）。只为挡脏数据（0 / NaN / 离谱值），
/// **不参与审美**——上一版写 1.6，把正常的 16:9（1.7778）也夹成 1.6，于是横版剧照上下
/// 各留一条灰边（用户报「横着的那些有问题」）。上界必须容得下 16:9 与更宽的 backdrop。
private let artworkMaximumRatio: CGFloat = 3.0

/// 卡片图区：**边框按图片自己的比例**（海报 ≈0.70 / 剧照 16:9）+ 占位 + 圆角裁剪 + 可选描边/投影。
///
/// 所有「海报/封面卡」的图区收敛到这里。调用方只给 URL + 宽度，
/// 不再各写一份 `RemoteImage(...).aspectRatio(...).frame(...).clipShape(...)`。
/// 需要在图区上叠内容（渐变压暗、角标按钮）时传 `overlay` 槽——叠层在裁剪**之前**
/// 应用，圆角外侧不会漏出叠层的方角。
///
/// ## 三条「别写死」的规矩（全是实测踩出来的）
///
/// 1. **边框贴图，不裁切也不留边**。服务端的海报**没有统一比例**——实测本机
///    Jellyfin 库 26 部剧集：22 部 0.7013、2 部 0.75、3 部 0.6667。任何写死的框
///    都两头不讨好：钉 2:3 会把 0.70/0.75 的左右各裁 2.5%–5.6%（用户的封面被切），
///    改 `.fit` 又会在上下留出灰边（用户的原话「上下空出一截」）。**所以框跟着图走**：
///    `aspectRatio`（服务端 `PrimaryImageAspectRatio`，宽 ÷ 高）给出后，框高＝宽 ÷ 比例，
///    图片正好铺满四条边。**参考产品也是这么做的边界**：隔壁 Rex 的网格是固定框 +
///    裁切（实测它的卡恒为 106×154＝0.688，把 `正相反的你与我` 那张 0.75 的海报左右
///    切掉了），我们取「不裁」这一侧，代价是同行的卡高会随各自比例略有不同。
/// 2. **比例的三级来源**：服务端字段 → 位图实测（`RemoteImage` 解码完回报真实尺寸，
///    服务端没给或不实时用它校正）→ 画幅兜底（`Shape.heightRatio`，此时用 `.fill`
///    保证**永远不留缝**）。前两级都能做到「四边贴死」。
/// 3. **解码预算跟盒子走，且与图片比例无关**：`maxPixelSize` 不给（nil）时按
///    `盒宽 × 画幅 × displayScale` 算长边。刻意用**画幅的名义比例**而不是图片的真实
///    比例——否则同一张图在比例校正前后会算出两个解码尺寸（＝两个缓存键），白白重下一遍。
///    写死 400 的后果是 3x 手机上 113pt 的卡要 508px 却只解 400px，白糊一档。
///    网格自适应宽（`width == nil`）要等 `onGeometryChange` 量到真实列宽，量到之前先铺
///    中性灰（与加载态同一块色，肉眼无差），这样解码只做一次。
public struct MediaArtwork<Overlay: View>: View {
    public enum Shape: Equatable {
        /// 海报（比例不统一，实测 0.667 / 0.70 / 0.75 混在同一个库里）。
        case poster
        /// 16:9 剧照。
        case still

        /// 解码预算锚定的**长边系数**（长边 = 宽 × 这个值）。
        ///
        /// 按该画幅「最高常见档」取，保证预算对任何常见比例都够用：海报锚 2:3
        /// （实测最窄的常见海报 0.6667 → 高＝宽×1.5），剧照锚 9/16（长边本来就是宽）。
        /// **注意它不再兼任框比例**——那是 `nominalRatio`，两者混用正是上一版把
        /// 16:9 挤变形的根因。
        public var budgetHeightRatio: CGFloat {
            switch self {
            case .poster: return 1.5
            case .still: return 9.0 / 16.0
            }
        }

        /// 拿不到图片真实比例时的**兜底框比例**（宽 ÷ 高）。
        public var nominalRatio: CGFloat {
            switch self {
            case .poster: return Metrics.posterFallbackRatio
            case .still: return 16.0 / 9.0
            }
        }

        /// 是否跟随图片自己的比例。
        ///
        /// - 海报**跟随**：实测同一个库里 0.667 / 0.70 / 0.75 三种混着，任何写死的框
        ///   都必然「裁」或「留边」。
        /// - 剧照**不跟随**，两个理由：①它的资产统一是 16:9（实测「继续观看」「接下来看」
        ///   「媒体库封面」全是 1.7778），而 rail 高度是常量——跟随只会让个别非 16:9 的
        ///   封面把卡片撑高、标题被裁；②剧照卡显示的是 Thumb/Backdrop，而服务端的
        ///   `PrimaryImageAspectRatio` 描述的是 **Primary 那张图**（实测「年会不能停！2」
        ///   primary = 0.667 而它的 thumb 是 16:9），拿它当剧照比例本身就是错的。
        public var followsImageRatio: Bool { self == .poster }

        /// 跟随比例时的**下限**（宽 ÷ 高）：比它更窄的图不再跟随，盒高封顶在 2:3。
        ///
        /// 依据是硬约束而不是审美：海报 rail 的高度是常量（`Metrics.posterRailHeight`
        /// ＝宽×1.5 ＋ 间距/文案/悬停留白），2:3 正是它恰好装得下的最窄画幅。更窄的图
        /// 若继续跟随，卡片会比 rail 高、**标题行被裁掉**——那比两侧留几 pt 更糟。
        public var minimumFollowedRatio: CGFloat {
            switch self {
            case .poster: return 2.0 / 3.0
            case .still: return 0
            }
        }
    }

    public let url: URL?
    public var authHeader: String?
    public var shape: Shape
    /// nil = 跟随可用宽度（网格自适应列，订阅卡那类）；给具体值 = 定宽（Rail/行内缩略图）。
    public var width: CGFloat?
    public var cornerRadius: CGFloat
    public var cornerStyle: RoundedCornerStyle
    /// 解码下采样上限（长边像素）；**nil = 按盒子实际显示尺寸算**（推荐，见类型注释）。
    public var maxPixelSize: Int?
    /// 无图 / 加载失败时的占位图标（透传给 `RemoteImage`）。默认通用「photo」。
    public var emptyIcon: String
    /// 细描边：白底图上让卡片边界可辨（Bangumi 日历卡 / 搜索结果行的习惯）。
    public var bordered: Bool
    /// 轻投影。
    public var shadowed: Bool
    /// 图片自己的宽高比（宽 ÷ 高），来自服务端 `PrimaryImageAspectRatio`。
    ///
    /// **给了它，边框就按它排**（图片四边贴死，不裁不留边）；nil 则先按 `shape` 的兜底
    /// 比例 + `.fill` 排（保证不留缝），等 `RemoteImage` 回报位图真实尺寸后再校正一次。
    public var aspectRatio: CGFloat?
    /// 覆盖画幅的**兜底比例**（宽 ÷ 高）；nil ＝用 `Shape.nominalRatio`。
    ///
    /// 只影响「比例还没到手」的那一拍（有真实比例就跟随真实比例）。给那些**来源本身
    /// 有固定惯例**的调用点用：TMDb / Bangumi 的海报都是 2:3，传 `2.0/3.0` 就能让
    /// 加载前那一帧也严丝合缝；不传则按通用兜底比例排，那一帧会有一点点裁。
    public var nominalRatio: CGFloat?
    /// 位图铺法。默认 `nil` ＝**按比例来源自动决定**：有真实比例（服务端或位图实测）
    /// 时 `.fit`（贴死且不裁），只有兜底比例时 `.fill`（宁可裁一点也绝不留缝）。
    /// 显式给值则覆盖自动判断（库卡拼图那类「必须铺满」的场景传 `.fill`）。
    public var scaling: ArtworkScaling?
    /// 显式指定图片管道；nil = 取环境的 `imagePipeline`（默认 `.shared`）。
    ///
    /// 与 `RemoteImage` 同名参数同一理由，但多一条**实打实的差别**：显式传入时
    /// `RemoteImage` 才能在 `init` 里同步命中内存缓存（首帧即出图）；只走环境注入
    /// 时首帧拿不到（环境值在 `init` 期不可读，见 `RemoteImage.init` 的注释）。
    /// 单测要「渲染一帧就断言像素」必须有这条同步路径。
    public var pipeline: ImagePipeline?
    @ViewBuilder public var overlay: Overlay

    public init(
        url: URL?,
        authHeader: String? = nil,
        shape: Shape,
        width: CGFloat? = nil,
        cornerRadius: CGFloat = Metrics.cardRadius,
        cornerStyle: RoundedCornerStyle = .circular,
        maxPixelSize: Int? = nil,
        emptyIcon: String = "photo",
        bordered: Bool = false,
        shadowed: Bool = false,
        aspectRatio: CGFloat? = nil,
        nominalRatio: CGFloat? = nil,
        scaling: ArtworkScaling? = nil,
        pipeline: ImagePipeline? = nil,
        @ViewBuilder overlay: () -> Overlay
    ) {
        self.url = url
        self.authHeader = authHeader
        self.shape = shape
        self.width = width
        self.cornerRadius = cornerRadius
        self.cornerStyle = cornerStyle
        self.maxPixelSize = maxPixelSize
        self.emptyIcon = emptyIcon
        self.bordered = bordered
        self.shadowed = shadowed
        self.aspectRatio = aspectRatio
        self.nominalRatio = nominalRatio
        self.scaling = scaling
        self.pipeline = pipeline
        self.overlay = overlay()
    }

    @Environment(\.displayScale) private var displayScale
    /// 自适应盒子的**实测**宽度：`width == nil`（网格列）时唯一能知道「要显示多大」的
    /// 来源，解码预算靠它算准。
    @State private var measuredWidth: CGFloat = 0
    /// 位图实测比例（`RemoteImage` 回报）。服务端比例可信时用不到它；服务端没给
    /// （或给的与位图不符）时，靠它把框校正到「四边贴死」。
    @State private var measuredRatio: CGFloat?

    public var body: some View {
        Group {
            if let width {
                artwork(boxWidth: width)
                    .frame(width: width, height: width / boxRatio)
            } else {
                // 自适应宽（网格列宽）：透明底按**盒子比例**撑出盒子。
                Color.clear
                    .aspectRatio(boxRatio, contentMode: .fit)
                    .overlay { measuredArtwork }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle))
        .overlay {
            if bordered {
                RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
        .shadow(
            color: .black.opacity(shadowed ? 0.08 : 0),
            radius: shadowed ? 3 : 0,
            y: shadowed ? 1 : 0
        )
    }

    /// 自适应盒子：量到列宽之前先铺一块和「加载中」同一色的中性灰，量到再起图。
    /// 这样解码预算第一次就是对的（见类型注释第 2 条），也不会闪。
    @ViewBuilder
    private var measuredArtwork: some View {
        if measuredWidth > 0 {
            artwork(boxWidth: measuredWidth)
        } else {
            Rectangle().fill(Metrics.placeholderFill)
        }
    }

    /// 盒子的宽高比（宽 ÷ 高）：服务端字段 → 位图实测（仅海报）→ 画幅兜底。
    private var boxRatio: CGFloat {
        if let ratio = clamped(aspectRatio) { return ratio }
        if shape.followsImageRatio, let ratio = clamped(measuredRatio) { return ratio }
        // 调用点能覆盖兜底比例（TMDb / Bangumi 的海报惯例是 2:3，见 `nominalRatio`）。
        return clamped(nominalRatio) ?? shape.nominalRatio
    }

    /// 合法性闸门：非有限 / 非正一律当作「没有」（退回兜底），再夹进
    /// `[shape.minimumFollowedRatio, maximumRatio]`。
    private func clamped(_ ratio: CGFloat?) -> CGFloat? {
        guard let ratio, ratio.isFinite, ratio > 0 else { return nil }
        return min(max(ratio, shape.minimumFollowedRatio), artworkMaximumRatio)
    }

    /// 是否用上了图片的**真实**比例（服务端字段或位图实测）。
    private var usesRealRatio: Bool {
        clamped(aspectRatio) != nil || (shape.followsImageRatio && clamped(measuredRatio) != nil)
    }

    /// 铺法：显式给了就用给的；否则有真实比例 → `.fit`（贴死且不裁），
    /// 只有兜底比例 → `.fill`（宁可裁一点，也绝不留缝）。
    private var effectiveScaling: ArtworkScaling {
        scaling ?? (usesRealRatio ? .fit : .fill)
    }

    private func artwork(boxWidth: CGFloat) -> some View {
        ZStack {
            RemoteImage(
                url: url,
                authHeader: authHeader,
                maxPixelSize: pixelBudget(boxWidth: boxWidth),
                emptyIcon: emptyIcon,
                scaling: effectiveScaling,
                // 只有「跟随图片比例」的画幅才需要实测（见 `Shape.followsImageRatio`）。
                // 剧照的框是固定 16:9，记录实测比例没有消费者，白写一次状态。
                onImageSizeChange: shape.followsImageRatio ? { size in
                    guard size.width > 0, size.height > 0 else { return }
                    let ratio = size.width / size.height
                    if abs(ratio - (measuredRatio ?? 0)) > 0.001 {
                        measuredRatio = ratio
                    }
                } : nil,
                pipeline: pipeline
            )
            overlay
        }
    }

    /// 盒子里真正要画多少像素。给了 `maxPixelSize` 就按给的（调用方明确知道自己要什么
    /// 时），否则按盒子算（见 `ArtworkMetrics.pixelBudget`）。
    private func pixelBudget(boxWidth: CGFloat) -> Int? {
        guard maxPixelSize == nil else { return maxPixelSize }
        return ArtworkMetrics.pixelBudget(
            boxWidth: boxWidth,
            heightRatio: shape.budgetHeightRatio,
            scale: displayScale
        )
    }
}

public extension MediaArtwork where Overlay == EmptyView {
    init(
        url: URL?,
        authHeader: String? = nil,
        shape: Shape,
        width: CGFloat? = nil,
        cornerRadius: CGFloat = Metrics.cardRadius,
        cornerStyle: RoundedCornerStyle = .circular,
        maxPixelSize: Int? = nil,
        emptyIcon: String = "photo",
        bordered: Bool = false,
        shadowed: Bool = false,
        aspectRatio: CGFloat? = nil,
        nominalRatio: CGFloat? = nil,
        scaling: ArtworkScaling? = nil,
        pipeline: ImagePipeline? = nil
    ) {
        self.init(
            url: url,
            authHeader: authHeader,
            shape: shape,
            width: width,
            cornerRadius: cornerRadius,
            cornerStyle: cornerStyle,
            maxPixelSize: maxPixelSize,
            emptyIcon: emptyIcon,
            bordered: bordered,
            shadowed: shadowed,
            aspectRatio: aspectRatio,
            nominalRatio: nominalRatio,
            scaling: scaling,
            pipeline: pipeline,
            overlay: { EmptyView() }
        )
    }
}

/// 卡片进度细轨：紧贴图区底部、与卡同宽的一条 3pt 胶囊。
/// `StillCard`（继续观看）与 `MoviePilotSubscribeCard`（追更进度）原来是两份实现。
public struct CardProgressTrack: View {
    /// 0...1；超界自动夹紧。
    public let fraction: Double
    /// nil = 跟随可用宽度（网格自适应列）；定宽 Rail 卡给定宽，布局少一次协商。
    public var width: CGFloat?
    /// 填充色。默认中性灰（融入卡片不抢海报调子）；追更进度等强调场景传 `.accentColor`。
    public var tint: Color

    public init(fraction: Double, width: CGFloat? = nil, tint: Color = Color.primary.opacity(0.6)) {
        self.fraction = fraction
        self.width = width
        self.tint = tint
    }

    private var clamped: Double { min(max(fraction, 0), 1) }

    public var body: some View {
        // 不用 containerRelativeFrame 量宽：它量的是最近容器（ScrollView/窗口），
        // 嵌在卡片行内会量出整窗宽。定宽走常量乘，自适应走一个 3pt 高的
        // GeometryReader 探针（高度写死，布局代价恒定且极小）。
        Group {
            if let width {
                track
                    .frame(width: width * clamped, alignment: .leading)
                    .frame(width: width, alignment: .leading)
            } else {
                GeometryReader { proxy in
                    track
                        .frame(width: proxy.size.width * clamped, alignment: .leading)
                }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }

    private var track: some View {
        Capsule()
            .fill(tint)
            .background(Capsule().fill(Color.primary.opacity(0.12)))
    }
}

// MARK: - 图区尺寸策略（可单测的纯函数）

/// 卡片图区的尺寸策略。抽成不依赖视图的纯函数，是为了让「按显示尺寸算解码预算」
/// 这条规矩能被用例直接钉住——它出错的症状（图片被放大后发糊）肉眼很难归因。
public enum ArtworkMetrics {
    /// 盒子里真正要画多少像素（解码下采样的长边上限）：**宽 × 画幅 × 屏幕缩放**。
    ///
    /// 海报的长边是高（`heightRatio` 1.5）、剧照的长边是宽（0.5625），所以取两者的大者。
    /// 写死数字的代价是实测过的：3x 手机上 113pt 的海报卡要 508px，而原来写死 400，
    /// 每张都被放大 27%，白白糊一档。
    public static func pixelBudget(boxWidth: CGFloat, heightRatio: CGFloat, scale: CGFloat) -> Int {
        let longEdge = max(boxWidth, boxWidth * heightRatio) * scale
        return Int(longEdge.rounded(.up))
    }
}

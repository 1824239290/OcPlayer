import SwiftUI

/// 卡片图区：固定画幅（2:3 海报 / 16:9 剧照）+ 占位 + 圆角裁剪 + 可选描边/投影。
///
/// 所有「海报/封面卡」的图区收敛到这里。调用方只给 URL + 宽度，
/// 不再各写一份 `RemoteImage(...).aspectRatio(...).frame(...).clipShape(...)`。
/// 需要在图区上叠内容（渐变压暗、角标按钮）时传 `overlay` 槽——叠层在裁剪**之前**
/// 应用，圆角外侧不会漏出叠层的方角。
public struct MediaArtwork<Overlay: View>: View {
    public enum Shape {
        /// 2:3 海报。
        case poster
        /// 16:9 剧照。
        case still

        /// 高 = 宽 × heightRatio。
        public var heightRatio: CGFloat {
            switch self {
            case .poster: return 1.5
            case .still: return 9.0 / 16.0
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
    /// 解码下采样上限（长边像素）；定宽时默认按展示宽度 ×3 给。
    public var maxPixelSize: Int
    /// 细描边：白底图上让卡片边界可辨（Bangumi 日历卡 / 搜索结果行的习惯）。
    public var bordered: Bool
    /// 轻投影。
    public var shadowed: Bool
    @ViewBuilder public var overlay: Overlay

    public init(
        url: URL?,
        authHeader: String? = nil,
        shape: Shape,
        width: CGFloat? = nil,
        cornerRadius: CGFloat = Metrics.cardRadius,
        cornerStyle: RoundedCornerStyle = .circular,
        maxPixelSize: Int? = nil,
        bordered: Bool = false,
        shadowed: Bool = false,
        @ViewBuilder overlay: () -> Overlay
    ) {
        self.url = url
        self.authHeader = authHeader
        self.shape = shape
        self.width = width
        self.cornerRadius = cornerRadius
        self.cornerStyle = cornerStyle
        self.maxPixelSize = maxPixelSize ?? Int((width ?? 200) * 3)
        self.bordered = bordered
        self.shadowed = shadowed
        self.overlay = overlay()
    }

    public var body: some View {
        Group {
            if let width {
                RemoteImage(url: url, authHeader: authHeader, maxPixelSize: maxPixelSize)
                    .aspectRatio(1 / shape.heightRatio, contentMode: .fill)
                    .frame(width: width, height: width * shape.heightRatio)
                    .overlay { overlay }
            } else {
                // 自适应宽（网格列宽）：透明底定画幅比例，图填满后随容器裁圆角。
                Color.clear
                    .aspectRatio(1 / shape.heightRatio, contentMode: .fit)
                    .overlay {
                        ZStack {
                            RemoteImage(url: url, authHeader: authHeader, maxPixelSize: maxPixelSize)
                                .scaledToFill()
                            overlay
                        }
                    }
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
        bordered: Bool = false,
        shadowed: Bool = false
    ) {
        self.init(
            url: url,
            authHeader: authHeader,
            shape: shape,
            width: width,
            cornerRadius: cornerRadius,
            cornerStyle: cornerStyle,
            maxPixelSize: maxPixelSize,
            bordered: bordered,
            shadowed: shadowed,
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

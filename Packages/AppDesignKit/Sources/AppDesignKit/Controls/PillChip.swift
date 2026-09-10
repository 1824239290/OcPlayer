import SwiftUI

/// 胶囊/小徽章标签的统一外观。
///
/// 收编全站手写的 `Text(...).padding(...).background(…, in: Capsule())`：
/// 同一个「标签」之前有六种配方（primary 0.04/0.06、tint 0.18、yellow 0.12、
/// fill.quaternary…），颜色各拍各的脑袋。现在只留三档角色 + 两种轮廓。
public struct PillChip: View {
    /// 语义色。`custom` 仅留给域状态色（如 Bangumi 收藏状态色）这类调色板
    /// 已由域定义好的场景；新代码优先用 neutral/accent。
    public enum Role {
        case neutral
        case accent
        case custom(Color)
    }

    public enum Outline {
        /// 胶囊（信息标签默认）。
        case capsule
        /// 小圆角矩形（排行榜 #、类型徽章这类「印章」观感）。
        case stamp(cornerRadius: CGFloat)
    }

    public let title: String
    public var systemImage: String?
    public var role: Role
    public var outline: Outline
    public var font: Font
    /// 同色细描边（「玻璃徽章」观感：种子卡的站点/标签徽章）。
    public var bordered: Bool

    public init(
        _ title: String,
        systemImage: String? = nil,
        role: Role = .neutral,
        outline: Outline = .capsule,
        font: Font = .caption2.weight(.medium),
        bordered: Bool = false
    ) {
        self.title = title
        self.systemImage = systemImage
        self.role = role
        self.outline = outline
        self.font = font
        self.bordered = bordered
    }

    private var tint: Color {
        switch role {
        case .neutral: return .primary
        case .accent: return .accentColor
        case .custom(let color): return color
        }
    }

    private var fillOpacity: Double {
        switch role {
        case .neutral: return 0.06
        case .accent, .custom: return 0.15
        }
    }

    public var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
        }
        .font(font)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .foregroundStyle(foregroundColor)
        .background(backgroundShape.fill(tint.opacity(fillOpacity)))
        .overlay {
            if bordered {
                // AnyShape 不保证是 InsettableShape，用 stroke（描边压边沿）不用 strokeBorder。
                backgroundShape.stroke(tint.opacity(0.25), lineWidth: 0.5)
            }
        }
    }

    private var foregroundColor: Color {
        switch role {
        case .neutral: return .secondary
        case .accent, .custom: return tint
        }
    }

    private var backgroundShape: AnyShape {
        switch outline {
        case .capsule: return AnyShape(Capsule())
        case .stamp(let radius): return AnyShape(RoundedRectangle(cornerRadius: radius))
        }
    }
}

/// 评分徽章：星 + 分数（+可选排名）。全站统一橙色（对齐 Bangumi 官方评分色；
/// MoviePilot 原来的黄色评分徽章收敛到这里）。
public struct RatingPill: View {
    public enum Style {
        /// 星+分纯文本，排名带印章底（Bangumi 搜索结果行的习惯）。
        case plain
        /// 星+分也带胶囊底（MoviePilot 搜索卡的习惯）。
        case capsule
    }

    public let score: Double
    public var rank: Int?
    /// 评分色；默认与 `BangumiStatusColor.rating` 同为橙。
    public var tint: Color
    public var style: Style

    public init(score: Double, rank: Int? = nil, tint: Color = .orange, style: Style = .plain) {
        self.score = score
        self.rank = rank
        self.tint = tint
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 4) {
            switch style {
            case .plain:
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                    Text(String(format: "%.1f", score))
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                .foregroundStyle(tint)
            case .capsule:
                PillChip(
                    String(format: "%.1f", score),
                    systemImage: "star.fill",
                    role: .custom(tint)
                )
            }
            if let rank, rank > 0 {
                PillChip(
                    "#\(rank)",
                    role: .custom(tint),
                    outline: .stamp(cornerRadius: 3),
                    font: .system(size: 10).weight(.semibold).monospacedDigit()
                )
            }
        }
        .accessibilityElement(children: .combine)
    }
}

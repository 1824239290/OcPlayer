import AppDesignKit
import MoviePilotKit
import SwiftUI

// MARK: - 媒体搜索结果液态玻璃卡片

/// 搜索结果卡（液态玻璃，2:3 海报 + 元信息 + 订阅 / 查资源动作）。
///
/// ## 为什么紧凑档是「上下两段」，而不是「左图右文 + 右侧按钮」
///
/// 旧版把动作区（两枚液态玻璃胶囊）和海报、文字列、`Spacer` 塞进**同一个**
/// `HStack`。iPhone 竖屏的卡内宽只有 330pt（402 − 页面留白 22×2 − 卡内边距 14×2），
/// 账面刚好被
/// `76(海报) + 16(间距) + 124(文字列) + 8(Spacer) + 49 + 8 + 49(胶囊)` 填满 ——
/// **不溢出，所以 SwiftUI 不报错，只会静默压缩最先让位的 `Text`**：
///
/// - 4 枚 `PillChip` 被压到 16 / 51 / 16 / 16pt，中文没有空格可断 → 逐字竖排，
///   在真机上就是三根 156pt 高的「纺锤形竖条」；
/// - 胶囊里的 `Text` 被压到 0 宽 → 只剩 `+` 和放大镜；标题截成「药屋少女的…」。
///
/// 现在紧凑档把动作区**移出那一行**（`compactActionRow`），独占卡片底部整宽，
/// 文字列因此拿到 238pt（海报 76 + 间距 16 之外的全部）；常规档
/// （iPad / macOS，最小窗宽 960pt）依旧横排，只补上「胶囊文案不许被压」的兜底。
/// 卡高 ≈262 → ≈186pt（= 28 padding + 114 海报 + 12 spacing + 32 胶囊）。
///
/// - Note: 紧凑 / 常规判据与 `MoviePilotHomeView.isCompact` 同源
///   （`horizontalSizeClass == .compact`），跟随窗口宽度而不是设备型号。
///
/// - Note: 刻意**不是** `private` —— `AppTests/MoviePilotMediaCardLayoutTests` 用
///   `ImageRenderer` 渲染它做几何钉子（紧凑档卡高 ≈186、常规档 ≈142、AX 档只增不缩），
///   这正是「文字被压成竖条」那类回归最直接的判据。改回 `private` 会让那条测试失效。
struct MoviePilotMediaGlassCard: View {
    let media: MPMediaInfo
    let isSubscribed: Bool
    let isAdding: Bool
    let onQuickSubscribe: () -> Void
    let onConfigureSubscribe: () -> Void
    var onOpenResource: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isCompact: Bool { horizontalSizeClass == .compact }

    /// 标题行数上限：常规档 1 行（宽屏本来放得下）；紧凑档 2 行；无障碍字号 3 行。
    ///
    /// 无障碍字号下这是必须的：AX5 时一行只放得下 3–4 个字，2 行照样会截成
    /// 「药屋少女的…」（真机截图 `preview/07-implemented-ax3.png` 实证）。
    private var titleLineLimit: Int {
        guard isCompact else { return 1 }
        return dynamicTypeSize.isAccessibilitySize ? 3 : 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ① 海报 + 信息列。**动作区不在这行里** —— 这正是旧版出问题的原因：
            //    定宽海报 + 可压缩文字 + Spacer + 胶囊挤在同一行，负空间只能从文字上扣。
            HStack(alignment: .top, spacing: 16) {
                poster

                infoColumn

                // ② 常规档（iPad / macOS）：宽屏装得下，动作留在信息行右侧。
                if !isCompact {
                    Spacer(minLength: 8)
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            subscribeAction(expand: false)
                            resourceAction(expand: false)
                        }
                    }
                }
            }

            // ③ 紧凑档：动作条独占卡片底部整宽。
            if isCompact {
                compactActionRow
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassCard()
        .accessibilityElement(children: .contain)
    }

    // MARK: - 信息区

    /// 2:3 标准胶片海报。
    private var poster: some View {
        MediaArtwork(
            url: media.posterURL,
            shape: .poster,
            width: 76,
            cornerRadius: 12,
            cornerStyle: .continuous,
            // TMDB 的海报惯例就是 2:3：给它兜底比例，加载前那一帧也严丝合缝。
            nominalRatio: 2.0 / 3.0
        )
        // 封面投影比通用原语默认为重，保留原观感。
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        // 装饰图：片名在信息列里会被朗读，不必再报一遍「图片」。
        .accessibilityHidden(true)
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(media.title ?? "未知条目")
                .font(.headline.weight(.bold))
                .foregroundStyle(.primary)
                // 紧凑档 2 行：「药屋少女的呢喃 第二季」这类长标题 1 行必截；
                // 无障碍字号再放一档到 3 行，见 `titleLineLimit`。
                .lineLimit(titleLineLimit)

            chips

            overview
        }
        // 文字列整体作为一段朗读，避免 VoiceOver 把标题 / 标签 / 简介拆成三段。
        .accessibilityElement(children: .combine)
    }

    /// 标签行（类型 / 年份 / 评分 / 源）。
    ///
    /// 用 `FlowLayout` 自动换行、每枚 chip `.fixedSize()` 钉住本征宽：
    /// 旧版是一条裸 `HStack`，宽度不够时 chip 会被压到 1 个字宽（中文逐字竖排）。
    private var chips: some View {
        FlowLayout(spacing: 6) {
            if let type = media.type, !type.isEmpty {
                PillChip(type, font: .caption2.weight(.medium))
                    .fixedSize()
            }

            if let year = media.titleYear ?? media.year, !year.isEmpty {
                PillChip(year, font: .caption2.monospacedDigit())
                    .fixedSize()
            }

            if let rating = media.voteAverage, rating > 0 {
                RatingPill(score: rating, style: .capsule)
                    .fixedSize()
            }

            if let source = media.mediaSource, !source.isEmpty {
                PillChip(
                    source.uppercased(),
                    role: .custom(.secondary),
                    font: .system(size: 9, weight: .bold)
                )
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var overview: some View {
        if let overview = media.overview, !overview.isEmpty {
            Text(overview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .lineSpacing(2)
        } else if !media.subtitle.isEmpty {
            Text(media.subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    // MARK: - 动作区

    /// 紧凑档动作条：整卡宽度 + 三档降级（与 `BangumiSubjectDetailView.compactActionArea` 同构）。
    ///
    /// ① 一行两枚等宽胶囊（默认）→ ② 各占一行（超大字号）→ ③ 各占一行且放行压缩。
    /// 第 ③ 档是必须的：`.fixedSize` 在「连换行都放不下」时的失败模式是**画出玻璃卡
    /// 边界**，比出省略号更糟（`BangumiSubjectDetailView` 里的同一判例）。
    ///
    /// `ViewThatFits` 刻意放在 `GlassEffectContainer` **外面**：容器内的提案行为不稳
    /// （`PlayerHUDActions` 记录过这一坑，那边改用隐藏镜像驱动分支），所以容器只包胶囊本身。
    /// - Note: **不是 `private`** —— `AppTests/MoviePilotMediaCardLayoutTests` 直接量它的高度
    ///   来验证 `ViewThatFits` 的降级档真的生效（「AX3 下动作条高度 ≈ 2×」比「整卡变高」
    ///   严格得多：后者在文字变大时也成立，抓不住降级被删）。
    var compactActionRow: some View {
        ViewThatFits(in: .horizontal) {
            capsulePair(stacked: false)
            capsulePair(stacked: true)
            capsulePair(stacked: true, compressible: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func capsulePair(stacked: Bool, compressible: Bool = false) -> some View {
        GlassEffectContainer(spacing: 8) {
            Group {
                if stacked {
                    VStack(spacing: 8) {
                        subscribeAction(expand: true, compressible: compressible)
                        resourceAction(expand: true, compressible: compressible)
                    }
                } else {
                    HStack(spacing: 8) {
                        subscribeAction(expand: true, compressible: compressible)
                        resourceAction(expand: true, compressible: compressible)
                    }
                }
            }
        }
    }

    /// 订阅菜单胶囊。
    ///
    /// - Parameters:
    ///   - expand: 紧凑档动作条里两枚胶囊等分整宽（拇指落点更大）；常规档留在信息行
    ///     右侧，用本征宽度。
    ///   - compressible: 只给 `ViewThatFits` 的最终兜底档用，见 `compactActionRow`。
    private func subscribeAction(expand: Bool, compressible: Bool = false) -> some View {
        Menu {
            Button {
                onQuickSubscribe()
            } label: {
                Label("快捷加入订阅", systemImage: "plus.circle")
            }
            .disabled(isSubscribed || isAdding)

            Button {
                onConfigureSubscribe()
            } label: {
                Label("配置规则并订阅…", systemImage: "slider.horizontal.3")
            }
        } label: {
            HStack(spacing: 5) {
                if isAdding {
                    ProgressView().controlSize(.small)
                } else if isSubscribed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("已订阅")
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "plus")
                    Text("订阅")
                }
            }
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
            // 钉住本征宽度：HStack 宽度不够时默认压缩顺序会先把文案截成 0
            // （字号不变、只剩图标）。只有最终兜底档例外 —— 见 `compactActionRow`。
            .fixedSize(horizontal: !compressible, vertical: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: expand ? .infinity : nil)
        }
        .buttonStyle(.plain)
        .liquidGlassCapsule(
            tint: isSubscribed ? Color.green.opacity(0.15) : nil,
            isInteractive: !isSubscribed && !isAdding
        )
        .disabled(isSubscribed || isAdding)
        .accessibilityLabel(isAdding ? "正在添加订阅" : (isSubscribed ? "已订阅" : "订阅"))
        .accessibilityHint("打开订阅菜单：快捷加入或配置规则")
    }

    /// 查资源入口胶囊（参数语义见 `subscribeAction`）。
    private func resourceAction(expand: Bool, compressible: Bool = false) -> some View {
        Button {
            onOpenResource()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                Text("查资源")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .fixedSize(horizontal: !compressible, vertical: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: expand ? .infinity : nil)
        }
        .buttonStyle(.plain)
        .liquidGlassCapsule(
            tint: Color.accentColor.opacity(0.22),
            isInteractive: true
        )
        .accessibilityLabel("查资源")
        .accessibilityHint("在各站点搜索该条目的下载资源")
    }
}

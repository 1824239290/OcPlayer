import BangumiKit
import SwiftUI

/// 对一集的操作。
enum BangumiEpisodeAction: Equatable {
    /// 直接置为某个状态。
    case set(BangumiEpisodeCollectionType)
    /// 「看到此集」：连带把之前的本篇都标成看过。
    case markUpTo
}

/// 章节网格里的一格：集号 + 状态。
///
/// 进度页和详情页共用这一个，两边观感与交互一致：
/// - 单击 = 主操作（未看 → 看过，看过 → 撤销），跟详情页「已看过」钮的 toggle 语义一样
/// - 右键 / 长按 = 其余状态 + 「看到此集」
/// - 未开播禁用
///
/// 配色沿用 App 既有的两色体系（中性 primary + accent 表示"已生效"），
/// 不引入新色相：已看是 accent 淡填充，未看是发丝边框。
struct BangumiEpisodeCell: View {
    let episode: BangumiEpisodeDTO
    /// 该格正在提交（请求在途）。
    var isBusy = false
    var onAction: (BangumiEpisodeAction) async -> Void

    private var status: BangumiEpisodeCollectionType { episode.collectionTypeEnum }
    private var isEnabled: Bool { episode.aired && !isBusy }

    var body: some View {
        Button {
            Task { await onAction(.set(status == .collect ? .none : .collect)) }
        } label: {
            VStack(spacing: 2) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(height: 14)
                } else {
                    Text(episode.sortDisplay)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(numberStyle)
                        .frame(height: 14)
                }
                Text(statusLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(fill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(border, lineWidth: 1))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .contextMenu {
            if episode.aired {
                ForEach(status.otherTypes()) { type in
                    Button {
                        Task { await onAction(.set(type)) }
                    } label: {
                        Label(type.action, systemImage: type.icon)
                    }
                }
                if episode.type == .main {
                    Divider()
                    Button {
                        Task { await onAction(.markUpTo) }
                    } label: {
                        Label("看到此集", systemImage: "text.insert")
                    }
                }
            }
        }
        #if os(iOS)
        .sensoryFeedback(.impact, trigger: status)
        #endif
        .help(helpText)
        .accessibilityLabel("\(episode.type.description) \(episode.sortDisplay)")
        .accessibilityValue(statusLabel)
    }

    private var statusLabel: String {
        guard episode.aired else { return "未播" }
        return status == .none ? "未看" : status.description
    }

    private var numberStyle: HierarchicalShapeStyle {
        guard episode.aired else { return .tertiary }
        return status == .dropped ? .secondary : .primary
    }

    private var fill: AnyShapeStyle {
        guard episode.aired else { return AnyShapeStyle(Color.primary.opacity(0.04)) }
        switch status {
        case .collect: return AnyShapeStyle(.tint.opacity(0.18))
        case .dropped: return AnyShapeStyle(Color.primary.opacity(0.06))
        case .wish, .none: return AnyShapeStyle(.clear)
        }
    }

    private var border: AnyShapeStyle {
        guard episode.aired else { return AnyShapeStyle(Color.primary.opacity(0.06)) }
        switch status {
        case .collect: return AnyShapeStyle(.tint.opacity(0.35))
        case .wish: return AnyShapeStyle(.tint.opacity(0.45))
        case .dropped: return AnyShapeStyle(Color.primary.opacity(0.08))
        case .none: return AnyShapeStyle(Color.primary.opacity(0.12))
        }
    }

    private var helpText: String {
        let name = episode.nameCN.isEmpty ? episode.name : episode.nameCN
        let title = "\(episode.type.name.uppercased()).\(episode.sortDisplay)"
        guard episode.aired else { return "\(title) 未开播" }
        return name.isEmpty ? "\(title)（\(statusLabel)）" : "\(title) \(name)（\(statusLabel)）"
    }
}

extension BangumiEpisodeCell {
    /// 章节网格的列定义（两页共用，格子宽度一致）。
    static let columns: [GridItem] = [GridItem(.adaptive(minimum: 46), spacing: 6)]
}

/// 内联提示条：和详情页 `loadErrorNotice` 同一套观感（secondary 色 + 三角图标）。
/// Bangumi 的写操作以前失败是全静默的，这条用来把话说出来。
struct BangumiNotice: View {
    let message: String
    var systemImage = "exclamationmark.triangle"
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
            Text(message).font(.callout)
            Spacer(minLength: 0)
            if let onRetry {
                Button("重试", action: onRetry)
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
        .foregroundStyle(.secondary)
    }
}

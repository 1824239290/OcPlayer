import SwiftUI

// MARK: - 同行等高网格

/// 按最小列宽自适应列数的网格布局，**同一行的子视图等高**（取该行最高者）。
///
/// 与 `LazyVGrid` 的区别：`LazyVGrid` 的 `.flexible()` 列在行内各算各的高度，
/// 同行的卡片高矮不齐；这个布局先量一遍每行最大高度，再按行高统一下发提案，
/// 卡片底边因此对齐（Bangumi 作品信息、详情页媒体信息这类 label/value 表用）。
public struct EqualRowHeightGrid: Layout {
    public var minColumnWidth: CGFloat
    public var horizontalSpacing: CGFloat
    public var verticalSpacing: CGFloat

    public init(
        minColumnWidth: CGFloat = 260,
        horizontalSpacing: CGFloat = 8,
        verticalSpacing: CGFloat = 8
    ) {
        self.minColumnWidth = minColumnWidth
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? 800
        let columns = max(1, Int((width + horizontalSpacing) / (minColumnWidth + horizontalSpacing)))
        let colWidth = max(0, (width - CGFloat(columns - 1) * horizontalSpacing) / CGFloat(columns))

        var totalHeight: CGFloat = 0
        var rowMaxHeight: CGFloat = 0
        var currentCol = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: colWidth, height: nil))
            rowMaxHeight = max(rowMaxHeight, size.height)
            currentCol += 1
            if currentCol >= columns {
                totalHeight += rowMaxHeight + verticalSpacing
                rowMaxHeight = 0
                currentCol = 0
            }
        }
        if currentCol > 0 {
            totalHeight += rowMaxHeight
        } else if totalHeight > 0 {
            totalHeight -= verticalSpacing
        }

        return CGSize(width: width, height: totalHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let width = bounds.width
        let columns = max(1, Int((width + horizontalSpacing) / (minColumnWidth + horizontalSpacing)))
        let colWidth = max(0, (width - CGFloat(columns - 1) * horizontalSpacing) / CGFloat(columns))

        // 1. 计算每行的最大高度
        var rowHeights: [CGFloat] = []
        var rowMaxHeight: CGFloat = 0
        var currentCol = 0

        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: colWidth, height: nil))
            rowMaxHeight = max(rowMaxHeight, size.height)
            currentCol += 1
            if currentCol >= columns {
                rowHeights.append(rowMaxHeight)
                rowMaxHeight = 0
                currentCol = 0
            }
        }
        if currentCol > 0 {
            rowHeights.append(rowMaxHeight)
        }

        // 2. 按行对齐摆放子视图，让同行所有卡片高度统一为该行最大高度
        var y = bounds.minY
        var rowIdx = 0
        currentCol = 0

        for subview in subviews {
            let rowH = rowIdx < rowHeights.count ? rowHeights[rowIdx] : 36
            let x = bounds.minX + CGFloat(currentCol) * (colWidth + horizontalSpacing)
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: colWidth, height: rowH)
            )
            currentCol += 1
            if currentCol >= columns {
                y += rowH + verticalSpacing
                rowIdx += 1
                currentCol = 0
            }
        }
    }
}

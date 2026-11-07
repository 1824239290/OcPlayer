import AppDesignKit
import SwiftUI

struct MyViewingCollectionTile: Identifiable {
    var id: String
    var title: String
    var count: Int?
    var covers: [URL] = []
    var action: () -> Void
}

struct MyViewingCollectionTiles: View {
    let tiles: [MyViewingCollectionTile]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 16)) : AnyLayout(HStackLayout(spacing: 16))
        layout {
            ForEach(tiles) { tile in
                Button(action: tile.action) { MyViewingCollectionCard(tile: tile) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(tile.title)，\(tile.count.map { "\($0) 部" } ?? "尚未同步")，Bangumi")
            }
        }
    }
}

private struct MyViewingCollectionCard: View {
    let tile: MyViewingCollectionTile
    @ScaledMetric private var valueSize: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top) {
                Text(tile.count.map(String.init) ?? "—")
                    .font(.system(size: valueSize, weight: .semibold, design: .rounded)).monospacedDigit()
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).padding(.top, 8)
            }
            Text(tile.title).font(.subheadline.weight(.medium))
            Text("Bangumi").font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            if !tile.covers.isEmpty {
                GeometryReader { proxy in
                    let posterWidth = min(56, proxy.size.width * 0.25)
                    ZStack {
                        ForEach(Array(tile.covers.prefix(3).enumerated()), id: \.element) { index, url in
                            MediaArtwork(url: url, shape: .poster, width: posterWidth, cornerRadius: 6, nominalRatio: 2.0 / 3.0)
                                .rotationEffect(.degrees([-13.0, 4.0, 14.0][index]))
                                .offset(x: CGFloat(index - 1) * posterWidth * 0.41)
                                .shadow(color: .black.opacity(0.12), radius: 5, y: 3)
                        }
                    }
                    .frame(width: min(120, proxy.size.width * 0.5), height: posterWidth * 1.72)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                .accessibilityHidden(true).allowsHitTesting(false)
            }
        }
        .liquidGlassCard(isInteractive: true)
    }
}

enum MyViewingCardRole: Int, CaseIterable, Sendable {
    case collections, month, genres, trends
}

private struct MyViewingCardRoleKey: LayoutValueKey {
    static let defaultValue = MyViewingCardRole.month
}

extension View {
    func viewingCardRole(_ role: MyViewingCardRole) -> some View {
        layoutValue(key: MyViewingCardRoleKey.self, value: role)
    }
}

/// Keeps the same view instances while reflowing. The month panel spans the count and genre rows.
struct MyViewingSummaryLayout: Layout {
    var prefersSingleColumn = false
    var spacing: CGFloat = 16

    static func frames(width: CGFloat, sizes: [MyViewingCardRole: CGSize],
                       singleColumn: Bool, spacing: CGFloat = 16) -> [MyViewingCardRole: CGRect] {
        var frames: [MyViewingCardRole: CGRect] = [:]
        if singleColumn || width < 700 || sizes.keys.allSatisfy({ $0 == .month }) {
            var y: CGFloat = 0
            for role in MyViewingCardRole.allCases {
                guard let size = sizes[role] else { continue }
                frames[role] = CGRect(x: 0, y: y, width: width, height: size.height)
                y += size.height + spacing
            }
            return frames
        }
        let columnWidth = (width - spacing) / 2
        var leftBottom: CGFloat = 0
        if let size = sizes[.collections] {
            frames[.collections] = CGRect(x: 0, y: 0, width: columnWidth, height: size.height)
            leftBottom = size.height + spacing
        }
        if let size = sizes[.genres] {
            frames[.genres] = CGRect(x: 0, y: leftBottom, width: columnWidth, height: size.height)
            leftBottom += size.height
        } else if leftBottom > 0 { leftBottom -= spacing }
        if let size = sizes[.month] {
            let height = max(size.height, leftBottom)
            frames[.month] = CGRect(x: columnWidth + spacing, y: 0, width: columnWidth, height: height)
            if let genre = frames[.genres] {
                frames[.genres] = CGRect(x: genre.minX, y: genre.minY, width: genre.width, height: height - genre.minY)
            }
            leftBottom = height
        }
        if let size = sizes[.trends] {
            frames[.trends] = CGRect(x: 0, y: leftBottom > 0 ? leftBottom + spacing : 0,
                                   width: columnWidth, height: size.height)
        }
        return frames
    }

    private func frames(proposal: ProposedViewSize, subviews: Subviews) -> [MyViewingCardRole: CGRect] {
        let width = max(0, proposal.width ?? 700)
        let single = prefersSingleColumn || width < 700 || subviews.allSatisfy { $0[MyViewingCardRoleKey.self] == .month }
        let columnWidth = single ? width : (width - spacing) / 2
        let sizes = Dictionary(subviews.map {
            ($0[MyViewingCardRoleKey.self], $0.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)))
        }, uniquingKeysWith: { first, _ in first })
        return Self.frames(width: width, sizes: sizes, singleColumn: single, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let positions = frames(proposal: proposal, subviews: subviews)
        return CGSize(width: max(0, proposal.width ?? 700), height: positions.values.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let positions = frames(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for view in subviews {
            guard let frame = positions[view[MyViewingCardRoleKey.self]] else { continue }
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }
}

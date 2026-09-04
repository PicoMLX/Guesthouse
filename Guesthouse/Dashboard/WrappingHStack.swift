import SwiftUI

/// How a run of controls is broken into lines that fit a given width.
///
/// Separated from the layout so the packing can be checked directly: `Layout.Subviews` cannot
/// be constructed outside SwiftUI, and this is the part that decides whether a card's buttons
/// stay inside it.
/// `Layout` is measured off the main actor, so this carries no isolation of its own.
nonisolated enum WrappingRows {
    /// Groups indices into rows, each no wider than `width`. An item wider than the row on its
    /// own still gets a row of its own, so nothing is dropped or overlapped.
    static func rows(of widths: [CGFloat], spacing: CGFloat, in width: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, itemWidth) in widths.enumerated() {
            let advance = current.isEmpty ? itemWidth : itemWidth + spacing
            if !current.isEmpty, used + advance > width {
                rows.append(current)
                current = [index]
                used = itemWidth
            } else {
                current.append(index)
                used += advance
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}

/// A row of controls that wraps onto further lines when the width runs out.
///
/// `ViewThatFits` chooses between alternatives written in advance, which is not enough here:
/// the recovery panel's buttons are as many and as long as the error makes them, and the
/// dashboard's adaptive grid can be as narrow as one card's minimum width.
struct WrappingHStack: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let available = proposal.width ?? sizes.reduce(0) { $0 + $1.width + spacing }
        let rows = WrappingRows.rows(of: sizes.map(\.width), spacing: spacing, in: available)
        let width = rows.map { row in row.reduce(0) { $0 + sizes[$1].width } + spacing * CGFloat(row.count - 1) }.max() ?? 0
        let heights = rows.map { row in row.map { sizes[$0].height }.max() ?? 0 }
        let height = heights.reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: min(width, available), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = WrappingRows.rows(of: sizes.map(\.width), spacing: spacing, in: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let height = row.map { sizes[$0].height }.max() ?? 0
            for index in row {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (height - sizes[index].height) / 2),
                    proposal: ProposedViewSize(sizes[index])
                )
                x += sizes[index].width + spacing
            }
            y += height + lineSpacing
        }
    }
}

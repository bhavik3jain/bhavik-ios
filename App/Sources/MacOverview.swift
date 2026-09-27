#if os(macOS)
import Core
import SwiftUI

/// The Mac's landing page: one live card per visible tracker, in the
/// sidebar's order, three to a row. Trips takes two columns — it has a day's
/// plan and the ideas around it to show, where every other card has a number.
///
/// The cards themselves come from the modules (`overviewCard(…)`), fed by
/// `HomeView`'s queries; this only lays them out.
struct MacOverview<Card: View>: View {
    let modules: [SelectedModule]
    @ViewBuilder let card: (SelectedModule) -> Card

    private static var columns: Int { 3 }
    private static var spacing: CGFloat { 14 }
    private static var padding: CGFloat { 24 }

    /// Rows of (module, columns it spans), filled left to right. A wide card
    /// that doesn't fit what's left of a row starts the next one rather than
    /// being squeezed to one column.
    private var rows: [[(module: SelectedModule, span: Int)]] {
        var rows: [[(module: SelectedModule, span: Int)]] = []
        var row: [(module: SelectedModule, span: Int)] = []
        var used = 0
        for module in modules {
            let span = module == .trips ? 2 : 1
            if used + span > Self.columns {
                rows.append(row)
                row = []
                used = 0
            }
            row.append((module, span))
            used += span
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    var body: some View {
        GeometryReader { proxy in
            let column = max(
                200,
                (proxy.size.width - Self.padding * 2 - Self.spacing * CGFloat(Self.columns - 1)) / CGFloat(Self.columns)
            )
            ScrollView {
                VStack(alignment: .leading, spacing: Self.spacing) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        // Taller where Trips is: its plan needs four lines
                        // and a caption, the others a headline and a detail.
                        let height: CGFloat = row.contains { $0.span > 1 } ? 250 : 190
                        HStack(alignment: .top, spacing: Self.spacing) {
                            ForEach(row, id: \.module) { cell in
                                card(cell.module)
                                    .frame(
                                        width: column * CGFloat(cell.span) + Self.spacing * CGFloat(cell.span - 1),
                                        height: height
                                    )
                            }
                        }
                    }
                }
                .padding(Self.padding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Overview")
        .navigationSubtitle(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
    }
}
#endif

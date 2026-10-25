import Core
import SwiftUI

/// The trackers' Overview cards in rows, sized and placed where Core's
/// `OverviewGrid` says: three to a row where they fit, two where they don't,
/// Trips two columns wide. The Mac's Overview and the open iPhone Duo's hub
/// (`HubDashboard`) both draw through this, each with its own scroll view and
/// chrome around it, so the two grids can't drift apart.
struct OverviewCardRows<Card: View>: View {
    /// The width to lay out in, padding included — the scroll view's.
    let width: CGFloat
    let modules: [SelectedModule]
    let now: Date
    /// Whether a module's card needs the taller row as of the given moment —
    /// Trips while one is under way. Every other row is one height.
    let isTall: (SelectedModule, Date) -> Bool
    /// A module's card as of the given moment.
    @ViewBuilder let card: (SelectedModule, Date) -> Card

    private typealias Grid = OverviewGrid<SelectedModule>

    var body: some View {
        let grid = Grid(
            width: width,
            ids: modules,
            span: { $0 == .trips ? 2 : 1 },
            isTall: { isTall($0, now) }
        )
        VStack(alignment: .leading, spacing: Grid.spacing) {
            ForEach(Array(grid.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: Grid.spacing) {
                    ForEach(row.cells, id: \.id) { cell in
                        card(cell.id, now)
                            .frame(width: max(0, cell.width), height: row.height)
                    }
                }
            }
        }
        .padding(Grid.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#if os(macOS)
import Core
import SwiftUI

/// The Mac's landing page: one live card per visible tracker, in the
/// sidebar's order, three to a row (two in a narrow window). Trips takes two columns — it has a day's
/// plan and the ideas around it to show, where every other card has a number.
///
/// The cards themselves come from the modules (`overviewCard(…)`), fed by
/// `HomeView`'s queries; this only lays them out, where Core's `OverviewGrid`
/// says — the arithmetic lives there so it can be tested.
struct MacOverview<Card: View>: View {
    let modules: [SelectedModule]
    let syncMonitor: CloudSyncMonitor?
    let open: (SelectedModule) -> Void
    /// Whether a module's card needs the taller row as of the given moment —
    /// Trips while one is under way. Every other row is one height.
    let isTall: (SelectedModule, Date) -> Bool
    /// A module's card as of the given moment — see the TimelineView below.
    @ViewBuilder let card: (SelectedModule, Date) -> Card

    private typealias Grid = OverviewGrid<SelectedModule>

    var body: some View {
        // Re-read once a minute. The cards read `.now` only when HomeView
        // re-rendered, which only a data change did — left open overnight,
        // "Up next", "Day 3 of 9" and the date above all still said
        // yesterday's.
        TimelineView(.everyMinute) { context in
            GeometryReader { proxy in
                let grid = Grid(
                    width: proxy.size.width,
                    ids: modules,
                    span: { $0 == .trips ? 2 : 1 },
                    isTall: { isTall($0, context.date) }
                )
                ScrollView {
                    VStack(alignment: .leading, spacing: Grid.spacing) {
                        ForEach(Array(grid.rows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: Grid.spacing) {
                                ForEach(row.cells, id: \.id) { cell in
                                    card(cell.id, context.date)
                                        .frame(width: max(0, cell.width), height: row.height)
                                }
                            }
                        }
                    }
                    .padding(Grid.padding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationSubtitle(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let syncMonitor {
                    Button {
                        Task { await syncMonitor.refresh() }
                    } label: {
                        Label("Refresh from iCloud", systemImage: "arrow.clockwise")
                    }
                    .disabled(syncMonitor.isRefreshing)
                    .help("Refresh from iCloud (⌘R)")
                }
                // Each tracker adds from its own page — a trip's editor, a
                // fill-up sheet — so New opens the one picked.
                Menu {
                    ForEach(modules) { module in
                        Button(module.accent.name) { open(module) }
                    }
                } label: {
                    Label("New", systemImage: "plus")
                }
                .help("Open a tracker to add to it")
            }
        }
    }
}
#endif

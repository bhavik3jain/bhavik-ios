#if os(macOS)
import Core
import SwiftUI

/// The Mac's landing page: one live card per visible tracker, in the
/// sidebar's order, three to a row (two in a narrow window). Trips takes two columns — it has a day's
/// plan and the ideas around it to show, where every other card has a number.
///
/// The cards themselves come from the modules (`overviewCard(…)`), fed by
/// `HomeView`'s queries; this only lays them out.
struct MacOverview<Card: View>: View {
    let modules: [SelectedModule]
    let syncMonitor: CloudSyncMonitor?
    let open: (SelectedModule) -> Void
    /// A module's card as of the given moment — see the TimelineView below.
    @ViewBuilder let card: (SelectedModule, Date) -> Card

    private static var spacing: CGFloat { 14 }
    private static var padding: CGFloat { 24 }
    /// The narrowest a card can be and still hold its headline and detail.
    private static var minimumColumn: CGFloat { 200 }

    /// Three columns where they fit, two where they don't. A fixed three with
    /// a 200pt floor under each overflowed the pane by 16pt at the window's
    /// minimum width and clipped the third card.
    private static func columns(for width: CGFloat) -> Int {
        let three = (width - padding * 2 - spacing * 2) / 3
        return three >= minimumColumn ? 3 : 2
    }

    /// Rows of (module, columns it spans), filled left to right. A wide card
    /// that doesn't fit what's left of a row starts the next one rather than
    /// being squeezed to one column.
    private func rows(columns: Int) -> [[(module: SelectedModule, span: Int)]] {
        var rows: [[(module: SelectedModule, span: Int)]] = []
        var row: [(module: SelectedModule, span: Int)] = []
        var used = 0
        for module in modules {
            let span = module == .trips ? 2 : 1
            if used + span > columns {
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
        // Re-read once a minute. The cards read `.now` only when HomeView
        // re-rendered, which only a data change did — left open overnight,
        // "Up next", "Day 3 of 9" and the date above all still said
        // yesterday's.
        TimelineView(.everyMinute) { context in
            GeometryReader { proxy in
                let columns = Self.columns(for: proxy.size.width)
                let column = (proxy.size.width - Self.padding * 2 - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns)
                ScrollView {
                    VStack(alignment: .leading, spacing: Self.spacing) {
                        ForEach(Array(rows(columns: columns).enumerated()), id: \.offset) { _, row in
                            // Taller where Trips is: its plan needs four lines
                            // and a caption, the others a headline and a detail.
                            let height: CGFloat = row.contains { $0.span > 1 } ? 250 : 190
                            HStack(alignment: .top, spacing: Self.spacing) {
                                ForEach(row, id: \.module) { cell in
                                    card(cell.module, context.date)
                                        .frame(
                                            width: max(0, column * CGFloat(cell.span) + Self.spacing * CGFloat(cell.span - 1)),
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

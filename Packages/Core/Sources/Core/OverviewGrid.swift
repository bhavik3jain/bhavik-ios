import CoreGraphics

/// Where the Mac Overview's cards go: how many columns fit, which cards share
/// a row, and how big each one is. Pure arithmetic, so it can be tested; the
/// view (`MacOverview`, in the app) only draws what this works out.
public struct OverviewGrid<ID: Hashable>: Equatable {
    public struct Cell: Equatable {
        public let id: ID
        /// Columns it spans — 2 for Trips, 1 for everything else.
        public let span: Int
        public let width: CGFloat
    }

    public struct Row: Equatable {
        public let cells: [Cell]
        public let height: CGFloat
    }

    public static var spacing: CGFloat { 14 }
    public static var padding: CGFloat { 24 }
    /// The narrowest a card can be and still hold its headline and detail.
    public static var minimumColumn: CGFloat { 200 }
    /// Every row's height unless it holds a tall card. One height for all of
    /// them: the first row used to be 250pt because Trips was in it, so the
    /// card beside Trips — Finance, whose content is three lines — stood
    /// half empty and taller than every other single card.
    public static var rowHeight: CGFloat { 206 }
    /// A row holding a tall card: Trips while one is under way, whose plan
    /// needs four lines, a caption and "Up next".
    public static var tallRowHeight: CGFloat { 250 }

    public let columns: Int
    public let rows: [Row]

    /// - Parameters:
    ///   - width: the pane's width, padding included.
    ///   - ids: the cards in the sidebar's order.
    ///   - span: how many columns a card takes (clamped to the columns there are).
    ///   - isTall: whether a card needs the taller row.
    public init(width: CGFloat, ids: [ID], span: (ID) -> Int, isTall: (ID) -> Bool = { _ in false }) {
        columns = Self.columns(for: width)
        let column = max(0, (width - Self.padding * 2 - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns))

        var rows: [Row] = []
        var cells: [Cell] = []
        var used = 0
        var tall = false
        func finishRow() {
            guard !cells.isEmpty else { return }
            rows.append(Row(cells: cells, height: tall ? Self.tallRowHeight : Self.rowHeight))
            cells = []
            used = 0
            tall = false
        }
        for id in ids {
            let span = min(max(span(id), 1), columns)
            // A wide card that doesn't fit what's left of a row starts the
            // next one rather than being squeezed to one column.
            if used + span > columns { finishRow() }
            cells.append(Cell(id: id, span: span, width: column * CGFloat(span) + Self.spacing * CGFloat(span - 1)))
            used += span
            tall = tall || isTall(id)
        }
        finishRow()
        self.rows = rows
    }

    /// Three columns where they fit, two where they don't. A fixed three with
    /// a 200pt floor under each overflowed the pane by 16pt at the window's
    /// minimum width and clipped the third card.
    public static func columns(for width: CGFloat) -> Int {
        let three = (width - padding * 2 - spacing * 2) / 3
        return three >= minimumColumn ? 3 : 2
    }
}

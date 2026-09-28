import CoreGraphics
import Testing
@testable import Core

private typealias Grid = OverviewGrid<String>

@Test func threeColumnsWhereTheyFitTwoWhereTheyDont() {
    // 3 × 200 + 2 × 14 + 2 × 24 = 676: the narrowest pane that holds three.
    #expect(Grid.columns(for: 676) == 3)
    #expect(Grid.columns(for: 675) == 2)
    #expect(Grid.columns(for: 1_040) == 3)
}

@Test func aWideCardThatDoesntFitStartsTheNextRow() {
    let grid = Grid(width: 1_040, ids: ["finance", "trips", "explore", "fuel", "points"], span: { $0 == "trips" ? 2 : 1 })
    #expect(grid.rows.map { $0.cells.map(\.id) } == [["finance", "trips"], ["explore", "fuel", "points"]])

    let late = Grid(width: 1_040, ids: ["finance", "explore", "trips", "fuel"], span: { $0 == "trips" ? 2 : 1 })
    #expect(late.rows.map { $0.cells.map(\.id) } == [["finance", "explore"], ["trips", "fuel"]],
            "Trips isn't squeezed into the one column left beside two cards")
}

@Test func cardsFillThePaneExactly() {
    let width: CGFloat = 1_040
    let grid = Grid(width: width, ids: ["a", "trips", "b", "c", "d"], span: { $0 == "trips" ? 2 : 1 })
    for row in grid.rows where row.cells.reduce(0, { $0 + $1.span }) == grid.columns {
        let used = row.cells.reduce(0) { $0 + $1.width } + Grid.spacing * CGFloat(row.cells.count - 1)
        #expect(abs(used - (width - Grid.padding * 2)) < 0.001)
    }
}

@Test func everyRowIsTheSameHeightUnlessItHoldsATallCard() {
    let ids = ["finance", "trips", "explore", "fuel", "points", "gym"]
    let calm = Grid(width: 1_040, ids: ids, span: { $0 == "trips" ? 2 : 1 })
    #expect(Set(calm.rows.map(\.height)) == [Grid.rowHeight], "Trips being wide doesn't make its row taller")

    let underWay = Grid(width: 1_040, ids: ids, span: { $0 == "trips" ? 2 : 1 }, isTall: { $0 == "trips" })
    #expect(underWay.rows.map(\.height) == [Grid.tallRowHeight, Grid.rowHeight, Grid.rowHeight])
}

@Test func aSpanWiderThanThePaneIsClamped() {
    let grid = Grid(width: 500, ids: ["trips"], span: { _ in 3 })
    #expect(grid.columns == 2)
    #expect(grid.rows.first?.cells.first?.span == 2)
}

@Test func noCardsNoRows() {
    #expect(Grid(width: 1_040, ids: [], span: { _ in 1 }).rows.isEmpty)
}

import Core
import CoreData
import Foundation
import Testing
@testable import TripTracker

extension TextMeasure {
    /// Every character half an em wide, so a test knows exactly how many
    /// lines a string takes without depending on the fonts installed.
    static let fixed = TextMeasure(
        lines: { text, type, width in
            guard !text.isEmpty else { return 0 }
            return max(1, Int((Double(text.count) * type.size * 0.5 / width).rounded(.up)))
        },
        width: { text, type in Double(text.count) * type.size * 0.5 }
    )
}

private typealias M = ItineraryMetrics
private typealias Block = ItineraryLayout.FlowBlock

private let bodyHeight = M.bodyHeight - M.pageHeaderHeight

private extension ItineraryLayout {
    var daysPages: [DaysPage] {
        pages.compactMap { if case .days(let page) = $0 { page } else { nil } }
    }

    var codePages: [ConfirmationsPage] {
        pages.compactMap { if case .confirmations(let page) = $0 { page } else { nil } }
    }

    var cover: CoverPage? {
        if case .cover(let cover) = pages.first { cover } else { nil }
    }
}

private func line(_ title: String, detail: String = "", time: String? = "09:00") -> ItineraryDocument.Line {
    ItineraryDocument.Line(time: time, duration: "", title: title, detail: detail, symbolName: "building.columns", isFlight: false)
}

private func sampleDay(_ number: Int, lines: [ItineraryDocument.Line], weather: ItineraryDocument.Weather? = nil) -> ItineraryDocument.Day {
    ItineraryDocument.Day(
        dayNumber: number, weekday: "Sat", dayOfMonth: "\(number)", month: "Jun",
        heading: "Saturday \(number) June", shortDate: "Sat \(number) Jun", weather: weather, lines: lines
    )
}

private func document(days: [ItineraryDocument.Day], codes: [ItineraryDocument.Confirmation] = [], weatherAsOf: String? = nil) -> ItineraryDocument {
    ItineraryDocument(
        title: "Rome & Amalfi",
        dateRange: "6–14 Jun 2026",
        cover: ItineraryDocument.Cover(title: "Rome & Amalfi", destination: "Rome, Italy", dateRange: "Saturday 6 – Sunday 14 June 2026", facts: []),
        days: days,
        confirmations: codes,
        weatherAsOf: weatherAsOf
    )
}

private func code(_ section: String, _ code: String, isFlight: Bool = false) -> ItineraryDocument.Confirmation {
    ItineraryDocument.Confirmation(
        section: section, symbolName: "bed.double", title: "Hotel", detail: "Booking.com · in Sat 6 · out Wed 10",
        contact: "", date: "", code: code, isFlight: isFlight
    )
}

// MARK: - Flow

@Test func blocksThatFitShareAPage() {
    let pages = ItineraryLayout.flow(
        [Block(header: 20, rows: [30, 30]), Block(header: 20, rows: [30], gapBefore: 10)],
        pageHeight: 200, keepWithHeader: 2
    )
    #expect(pages.count == 1)
    #expect(pages[0].map(\.rows) == [0..<2, 0..<1])
    #expect(pages[0].allSatisfy { !$0.isContinuation && !$0.continues })
}

@Test func aBlockThatWouldFitAloneIsNeverSplitJustForStartingLow() {
    let pages = ItineraryLayout.flow(
        [Block(header: 20, rows: [100]), Block(header: 20, rows: [40, 40], gapBefore: 10)],
        pageHeight: 150, keepWithHeader: 2
    )
    #expect(pages.map { $0.map(\.block) } == [[0], [1]], "The second day moves to the next page whole")
    #expect(pages[1][0].rows == 0..<2)
}

@Test func aBlockTallerThanAPageContinues() {
    let pages = ItineraryLayout.flow(
        [Block(header: 20, rows: Array(repeating: 30, count: 10))],
        pageHeight: 150, keepWithHeader: 2
    )
    #expect(pages.map { $0[0].rows } == [0..<4, 4..<8, 8..<10], "Header + four rows is 140 of 150")
    #expect(pages.map { $0[0].isContinuation } == [false, true, true])
    #expect(pages.map { $0[0].continues } == [true, true, false])
}

@Test func aHeaderIsNeverLeftAtTheFootOfAPage() {
    // 110 used; a long day's header and one row would fit in the 40 left, but
    // not the two rows `keepWithHeader` asks for, so the day starts over.
    let pages = ItineraryLayout.flow(
        [Block(header: 20, rows: [90]), Block(header: 10, rows: Array(repeating: 25, count: 8), gapBefore: 0)],
        pageHeight: 150, keepWithHeader: 2
    )
    #expect(pages.map { $0.map(\.block) } == [[0], [1], [1]])
    #expect(pages[1][0].rows == 0..<5)
}

@Test func aRowTallerThanAPageStillGetsOneAndTheFlowEnds() {
    let pages = ItineraryLayout.flow([Block(header: 20, rows: [30, 400, 30])], pageHeight: 150, keepWithHeader: 1)
    #expect(pages.flatMap { $0.map(\.rows) } == [0..<1, 1..<2, 2..<3])
}

@Test func aDayIsAtLeastAsTallAsItsBadge() {
    let block = Block(header: 22, rows: [15], minHeight: M.badgeHeight)
    #expect(block.height(0..<1) == M.badgeHeight)
}

// MARK: - Pages

@Test func theCoverThenTheCodesThenTheDays() throws {
    let days = (1...9).map { sampleDay($0, lines: [line("Colosseum"), line("Pantheon")]) }
    let layout = ItineraryLayout(document: document(days: days, codes: [code("Lodging", "RM-88412")]), measure: .fixed)

    guard case .cover = layout.pages.first else {
        Issue.record("The first page is the cover")
        return
    }
    guard case .confirmations = layout.pages[1] else {
        Issue.record("The codes come straight after the cover, where they're found at a desk")
        return
    }
    #expect(layout.codePages.count == 1)
    #expect(layout.daysPages.flatMap(\.slices).map(\.day.dayNumber) == Array(1...9))
    #expect(layout.pages.count < 1 + 1 + 9, "Short days share pages instead of one each")
}

@Test func theContentsListNamesTheRightPages() throws {
    let days = (1...9).map { sampleDay($0, lines: Array(repeating: line("Stop", detail: "Somewhere to be, with a note"), count: 8)) }
    let layout = ItineraryLayout(document: document(days: days, codes: [code("Lodging", "RM-88412")]), measure: .fixed)
    let cover = try #require(layout.cover)

    #expect(cover.contents.map(\.title) == ["Flights & bookings", "Day by day"])
    #expect(cover.contents[0].pages == "Page 2")
    #expect(cover.contents[1].pages == "Pages 3–\(layout.pages.count)")
}

@Test func noCodesMeansNoCodesPage() throws {
    let layout = ItineraryLayout(document: document(days: [sampleDay(1, lines: [line("Colosseum")])]), measure: .fixed)
    #expect(layout.codePages.isEmpty)
    #expect(try #require(layout.cover).contents.map(\.pages) == ["Page 2"])
}

@Test func nothingOnAPageRunsIntoTheFooter() {
    // Days of every length, notes long enough to wrap, and a day far longer
    // than a page.
    let days = (1...12).map { number in
        sampleDay(number, lines: (0..<(number == 5 ? 40 : number % 4 + 1)).map { index in
            line("Stop \(index)", detail: String(repeating: "A long note about the place. ", count: index % 5))
        })
    }
    let layout = ItineraryLayout(document: document(days: days), measure: .fixed)

    for page in layout.daysPages {
        let used = page.slices.map(ItineraryLayout.sliceHeight).reduce(0, +) + Double(page.slices.count - 1) * M.dayGap
        #expect(used <= bodyHeight, "\(page.label) is \(used)pt of \(bodyHeight)")
    }
    let dayFive = layout.daysPages.flatMap(\.slices).filter { $0.day.dayNumber == 5 }
    #expect(dayFive.count > 1)
    #expect(dayFive.flatMap(\.rows).map(\.line.title) == (0..<40).map { "Stop \($0)" }, "Continuations keep the day's order")
    #expect(layout.daysPages.contains { $0.label == "Day 5, continued" })
}

@Test func anEmptyDayStillTakesARow() {
    let layout = ItineraryLayout(document: document(days: [sampleDay(1, lines: [])]), measure: .fixed)
    let slice = layout.daysPages[0].slices[0]
    #expect(slice.rows.isEmpty)
    #expect(ItineraryLayout.sliceHeight(slice) == max(M.badgeHeight, M.dayHeaderHeight + M.emptyDayRowHeight))
}

@Test func longTextIsMeasuredIntoMoreLinesUpToALimit() {
    let short = ItineraryLayout.row(for: line("Pantheon"), measure: .fixed)
    let long = ItineraryLayout.row(for: line("Pantheon", detail: String(repeating: "word ", count: 20)), measure: .fixed)
    let huge = ItineraryLayout.row(for: line("Pantheon", detail: String(repeating: "word ", count: 600)), measure: .fixed)
    #expect(short.detailLines == 0)
    #expect(long.detailLines == 2)
    #expect(huge.detailLines == M.maxDetailLines, "A novel of a note is cut, not given the page")
    #expect(short.height < long.height)
}

@Test func codeBoxesAreWideEnoughForTheirCode() {
    let short = ItineraryLayout.card(for: code("Lodging", "AB12"), measure: .fixed)
    let long = ItineraryLayout.card(for: code("Tickets", "VAT-230611-88-EXTRA-LONG"), measure: .fixed)
    #expect(short.codeWidth == M.minCodeWidth)
    #expect(long.codeWidth > short.codeWidth)
    #expect(long.codeWidth <= M.maxCodeWidth)
    let drawn = TextMeasure.fixed.width("VAT-230611-88-EXTRA-LONG", .code) + 24 * M.codeKerning + 2 * M.codePadding
    #expect(long.codeWidth >= drawn, "The tracking the code is drawn with is part of its width")
}

@Test func codesGroupBySectionAndSplitAcrossPages() {
    let codes = (0..<30).map { code($0 < 20 ? "Lodging" : "Tickets", "CODE\($0)") }
    let layout = ItineraryLayout(document: document(days: [], codes: codes), measure: .fixed)

    #expect(layout.codePages.count > 1)
    #expect(layout.codePages.map(\.isContinuation) == [false] + Array(repeating: true, count: layout.codePages.count - 1))
    #expect(layout.codePages.flatMap(\.groups).flatMap(\.cards).map(\.confirmation.code) == (0..<30).map { "CODE\($0)" })
    #expect(Set(layout.codePages.flatMap(\.groups).map(\.section)) == ["Lodging", "Tickets"])
}

// MARK: - Cover

@Test func theCoverListsEveryDayWhenTheyFit() throws {
    let days = (1...9).map { sampleDay($0, lines: [line("Colosseum"), line("Forum"), line("Palatine"), line("Monti"), line("Trastevere")]) }
    let cover = try #require(ItineraryLayout(document: document(days: days), measure: .fixed).cover)
    #expect(cover.glance.count == 9)
    #expect(cover.moreDays == nil)
    #expect(cover.glance[0].highlights == "Colosseum · Forum · Palatine")
    #expect(cover.glance[0].more == 2)
}

@Test func aLongTripsCoverSaysHowManyDaysItLeftOff() throws {
    let days = (1...30).map { sampleDay($0, lines: [line("Beach")]) }
    let layout = ItineraryLayout(document: document(days: days), measure: .fixed)
    let cover = try #require(layout.cover)
    let firstDays = 2 + layout.codePages.count
    #expect(cover.glance.count < 30)
    #expect(cover.moreDays == "+ \(30 - cover.glance.count) more days, from page \(firstDays)")
}

@Test func aFreeDayReadsAsNothingPlannedOnTheCover() throws {
    let cover = try #require(ItineraryLayout(document: document(days: [sampleDay(1, lines: [])]), measure: .fixed).cover)
    #expect(cover.glance[0].highlights == ItineraryLayout.nothingPlanned)
    #expect(cover.glance[0].more == 0)
}

// MARK: - Footer

@Test func onlyPagesShowingWeatherCarryTheCredit() {
    let sunny = ItineraryDocument.Weather(symbolName: "sun.max", summary: "Sunny", temperatures: "28° / 19°")
    let days = [sampleDay(1, lines: [line("Colosseum")], weather: sunny)]
    let doc = document(days: days, codes: [code("Lodging", "RM-88412")], weatherAsOf: "1 Jun 2026")
    let layout = ItineraryLayout(document: doc, measure: .fixed)
    let footers = layout.pages.enumerated().map { index, page in
        ItineraryLayout.Footer(document: doc, page: page, number: index + 1, count: layout.pages.count)
    }

    #expect(footers.map(\.pageNumber) == ["Page 1 of 3", "Page 2 of 3", "Page 3 of 3"])
    #expect(footers.allSatisfy { $0.trip == "Rome & Amalfi · 6–14 Jun 2026" })
    #expect(footers[0].weatherCredit?.contains("Apple Weather") == true, "The cover's list shows the weather")
    #expect(footers[0].weatherCredit?.contains("1 Jun 2026") == true, "A printed forecast says when it was fetched")
    #expect(footers[1].weatherCredit == nil, "The codes page has no weather")
    #expect(footers[2].weatherCredit != nil)
}

@Test func theWeatherCreditIsALinkOverItsOwnLine() {
    let rect = M.weatherCreditRect
    let url = ItineraryLayout.Footer.legalAttributionURL
    #expect(url.absoluteString == "https://weatherkit.apple.com/legal-attribution.html")
    // PDF space starts at the bottom left: the footer's second line sits on
    // the bottom margin, under the page and clear of its body.
    // Compared as a point: `rect.minY == M.bottomMargin` inside `#expect`
    // mixes CGFloat and Double, and failed printing 40.0 on both sides.
    #expect(rect.origin == CGPoint(x: M.sideMargin, y: M.bottomMargin))
    #expect(rect.maxY <= M.bottomMargin + M.footerHeight)
    #expect(rect.maxX < M.pageSize.width - M.sideMargin, "Stops short of \"Made in Multitrack\"")

    let sunny = ItineraryDocument.Weather(symbolName: "sun.max", summary: "Sunny", temperatures: "28° / 19°")
    let doc = document(days: [sampleDay(1, lines: [line("Colosseum")], weather: sunny)], weatherAsOf: "1 Jun 2026")
    let layout = ItineraryLayout(document: doc, measure: .fixed)
    let footer = ItineraryLayout.Footer(document: doc, page: layout.pages[1], number: 2, count: 2)
    #expect(footer.weatherCredit?.contains("weatherkit.apple.com/legal-attribution.html") == true, "The printed link is the linked one")
}

@Test func pageLabelsNameTheirDays() {
    let first = ItineraryLayout.DaySlice(day: sampleDay(1, lines: []), rows: [], isContinuation: false, continues: false)
    let third = ItineraryLayout.DaySlice(day: sampleDay(3, lines: []), rows: [], isContinuation: false, continues: false)
    let more = ItineraryLayout.DaySlice(day: sampleDay(4, lines: []), rows: [], isContinuation: true, continues: false)
    #expect(ItineraryLayout.label(for: [first, third]) == "Days 1–3")
    #expect(ItineraryLayout.label(for: [third]) == "Day 3")
    #expect(ItineraryLayout.label(for: [more]) == "Day 4, continued")
    #expect(ItineraryLayout.pageSpan(3, count: 1) == "Page 3")
    #expect(ItineraryLayout.pageSpan(3, count: 3) == "Pages 3–5")
}

@Test func thePageFitsLetterAndA4() {
    // A4 is 595pt wide; the text block has to fit it with no scaling.
    #expect(M.bodyWidth + 2 * 36 <= 595)
    #expect(M.pageSize == CGSize(width: 612, height: 792))
}

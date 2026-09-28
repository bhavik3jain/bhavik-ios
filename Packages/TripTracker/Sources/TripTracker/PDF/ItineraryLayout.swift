import Core
import CoreGraphics
import CoreText
import Foundation

/// Where everything in an `ItineraryDocument` falls on paper: which page, and
/// how tall each row is drawn.
///
/// Heights are measured, not guessed from a count. The first version broke
/// pages every twelve entries and gave every day a page of its own, so a
/// nine-day trip with three things a day printed eleven pages, most of them
/// blank below the fourth line — and a day of long notes could still run off
/// the bottom. Here each row's text is measured with Core Text, the days flow
/// on from one another, and the page views draw every row at exactly the
/// height worked out for it (`.frame(height:)`, with the measured line count as
/// its `lineLimit`), so a measurement that is slightly off truncates a line
/// rather than pushing the footer off the page.
struct ItineraryLayout: Equatable {
    enum Page: Equatable {
        case cover(CoverPage)
        case confirmations(ConfirmationsPage)
        case days(DaysPage)

        /// Whether the page prints weather, and so needs Apple's credit.
        var showsWeather: Bool {
            switch self {
            case .cover(let page): page.glance.contains { $0.weather != nil }
            case .confirmations: false
            case .days(let page): page.slices.contains { $0.day.weather != nil }
            }
        }
    }

    struct CoverPage: Equatable {
        let cover: ItineraryDocument.Cover
        let titleLines: Int
        let glance: [GlanceRow]
        /// "+ 6 more days, from page 3" when the trip has more days than fit.
        let moreDays: String?
        let contents: [ContentsEntry]
    }

    struct GlanceRow: Equatable {
        let dayNumber: Int
        let date: String
        /// The day's first few titles, "Colosseum & Forum · Lunch in Monti · Palatine Hill".
        let highlights: String
        /// How many more entries the day has than `highlights` names.
        let more: Int
        let weather: ItineraryDocument.Weather?
    }

    struct ContentsEntry: Equatable {
        let title: String
        /// "Page 2", "Pages 3–5".
        let pages: String
    }

    struct ConfirmationsPage: Equatable {
        let groups: [ConfirmationGroup]
        let isContinuation: Bool
    }

    struct ConfirmationGroup: Equatable {
        let section: String
        let symbolName: String
        let cards: [Card]
    }

    struct Card: Equatable {
        let confirmation: ItineraryDocument.Confirmation
        let detailLines: Int
        /// Wide enough for the code on one line, so it never wraps mid-code.
        let codeWidth: Double
        let height: Double
    }

    struct DaysPage: Equatable {
        let slices: [DaySlice]
        /// "Days 1–3", "Day 4, continued".
        let label: String
    }

    /// All of a day, or the part of a long day that fits on this page.
    struct DaySlice: Equatable {
        let day: ItineraryDocument.Day
        let rows: [Row]
        let isContinuation: Bool
        let continues: Bool
    }

    struct Row: Equatable {
        let line: ItineraryDocument.Line
        let titleLines: Int
        let detailLines: Int
        let height: Double
    }

    let pages: [Page]

    init(document: ItineraryDocument, measure: TextMeasure = .coreText) {
        typealias M = ItineraryMetrics

        // Codes, straight after the cover: the pages opened at a check-in desk.
        let cards = document.confirmations.map { Self.card(for: $0, measure: measure) }
        let sections = Self.sections(cards)
        let confirmationPages = Self.flow(
            sections.map { FlowBlock(header: M.groupHeaderHeight, rows: $0.cards.map(\.height), gapBefore: M.groupGap) },
            pageHeight: M.bodyHeight - M.pageHeaderHeight,
            keepWithHeader: 1
        ).enumerated().map { index, pieces in
            ConfirmationsPage(
                groups: pieces.map { piece in
                    let section = sections[piece.block]
                    return ConfirmationGroup(section: section.section, symbolName: section.symbolName, cards: Array(section.cards[piece.rows]))
                },
                isContinuation: index > 0
            )
        }

        // Then the days, run on from one another.
        let dayRows = document.days.map { day in day.lines.map { Self.row(for: $0, measure: measure) } }
        let dayPages = Self.flow(
            dayRows.map { rows in
                FlowBlock(
                    header: M.dayHeaderHeight,
                    // A free day still takes a row, for its "Nothing planned".
                    rows: rows.isEmpty ? [M.emptyDayRowHeight] : rows.map(\.height),
                    gapBefore: M.dayGap,
                    minHeight: M.badgeHeight
                )
            },
            pageHeight: M.bodyHeight - M.pageHeaderHeight,
            keepWithHeader: 2
        ).map { pieces in
            let slices = pieces.map { piece in
                let rows = dayRows[piece.block]
                return DaySlice(
                    day: document.days[piece.block],
                    rows: rows.isEmpty ? [] : Array(rows[piece.rows]),
                    isContinuation: piece.isContinuation,
                    continues: piece.continues
                )
            }
            return DaysPage(slices: slices, label: Self.label(for: slices))
        }

        // The cover last: its contents list needs the page numbers.
        let firstCodes = 2
        let firstDays = firstCodes + confirmationPages.count
        var contents: [ContentsEntry] = []
        if !confirmationPages.isEmpty {
            contents.append(ContentsEntry(title: "Flights & bookings", pages: Self.pageSpan(firstCodes, count: confirmationPages.count)))
        }
        if !dayPages.isEmpty {
            contents.append(ContentsEntry(title: "Day by day", pages: Self.pageSpan(firstDays, count: dayPages.count)))
        }
        let titleLines = min(2, measure.lines(document.cover.title, .coverTitle, M.bodyWidth))
        let capacity = M.glanceCapacity(titleLines: titleLines, contentsCount: contents.count)
        let glance = Self.glance(document.days, capacity: capacity, measure: measure)
        let hidden = document.days.count - glance.count
        let cover = CoverPage(
            cover: document.cover,
            titleLines: titleLines,
            glance: glance,
            moreDays: hidden > 0 ? "+ \(counted(hidden, "more day")), from page \(firstDays)" : nil,
            contents: contents
        )

        pages = [.cover(cover)] + confirmationPages.map(Page.confirmations) + dayPages.map(Page.days)
    }

    // MARK: - Flow

    /// A header and the rows under it, as heights: a day, or a kind of booking.
    struct FlowBlock: Equatable {
        let header: Double
        let rows: [Double]
        /// Space above the block when something is already on the page.
        var gapBefore: Double = 0
        /// The block is never drawn shorter than this — a day is at least as
        /// tall as its date badge.
        var minHeight: Double = 0

        func height(_ rows: Range<Int>) -> Double {
            max(minHeight, header + self.rows[rows].reduce(0, +))
        }
    }

    /// Where one block, or part of one, goes.
    struct FlowPiece: Equatable {
        let block: Int
        let rows: Range<Int>
        let isContinuation: Bool
        let continues: Bool
    }

    /// Packs blocks onto pages of `pageHeight`, in order.
    ///
    /// A block that fits in the space left goes there. One that doesn't, but
    /// would fit on a page of its own, starts the next page — a day is never
    /// split just because it happened to start low. Only a block taller than a
    /// whole page is split, and then its header never sits at the foot of a
    /// page with fewer than `keepWithHeader` of its rows under it. A row taller
    /// than a page still gets one, alone, rather than looping forever.
    static func flow(_ blocks: [FlowBlock], pageHeight: Double, keepWithHeader: Int) -> [[FlowPiece]] {
        var pages: [[FlowPiece]] = []
        var page: [FlowPiece] = []
        var used = 0.0

        func newPage() {
            if !page.isEmpty { pages.append(page) }
            page = []
            used = 0
        }

        for (index, block) in blocks.enumerated() {
            let whole = 0..<block.rows.count
            let gap = page.isEmpty ? 0 : block.gapBefore
            if used + gap + block.height(whole) <= pageHeight {
                page.append(FlowPiece(block: index, rows: whole, isContinuation: false, continues: false))
                used += gap + block.height(whole)
                continue
            }
            if block.height(whole) <= pageHeight {
                newPage()
                page.append(FlowPiece(block: index, rows: whole, isContinuation: false, continues: false))
                used = block.height(whole)
                continue
            }

            // Taller than a page: as many rows as fit, then onward.
            var start = 0
            var isContinuation = false
            while start < block.rows.count {
                let gap = page.isEmpty ? 0 : block.gapBefore
                var end = start
                while end < block.rows.count, used + gap + block.height(start..<(end + 1)) <= pageHeight {
                    end += 1
                }
                let wanted = min(keepWithHeader, block.rows.count - start)
                if end - start < max(1, wanted), !page.isEmpty {
                    newPage()
                    continue
                }
                end = max(end, start + 1)
                page.append(FlowPiece(block: index, rows: start..<end, isContinuation: isContinuation, continues: end < block.rows.count))
                used += gap + block.height(start..<end)
                start = end
                if start < block.rows.count {
                    newPage()
                    isContinuation = true
                }
            }
        }
        newPage()
        return pages
    }

    // MARK: - Pieces

    static func row(for line: ItineraryDocument.Line, measure: TextMeasure) -> Row {
        typealias M = ItineraryMetrics
        // The duration shares the title's line, so it is measured with it.
        let title = line.duration.isEmpty ? line.title : "\(line.title) · \(line.duration)"
        let titleLines = min(M.maxTitleLines, measure.lines(title, .rowTitle, M.rowTextWidth))
        let detailLines = line.detail.isEmpty ? 0 : min(M.maxDetailLines, measure.lines(line.detail, .rowDetail, M.rowTextWidth))
        return Row(line: line, titleLines: titleLines, detailLines: detailLines, height: M.rowHeight(titleLines: titleLines, detailLines: detailLines))
    }

    static func card(for confirmation: ItineraryDocument.Confirmation, measure: TextMeasure) -> Card {
        typealias M = ItineraryMetrics
        let code = confirmation.code.isEmpty ? "—" : confirmation.code
        // The code is drawn with tracking, so that goes into its width too.
        // Measured without it, a 13-character code came out 6pt short, and
        // `minimumScaleFactor` quietly shrank the one thing on the page meant
        // to be read from arm's length.
        let codeText = measure.width(code, .code) + Double(code.count) * M.codeKerning
        let codeWidth = min(M.maxCodeWidth, max(M.minCodeWidth, codeText + 2 * M.codePadding))
        let textWidth = M.bodyWidth - 2 * M.cardPadding - M.cardSpacing - codeWidth
        let detailLines = confirmation.detail.isEmpty ? 0 : min(2, measure.lines(confirmation.detail, .cardDetail, textWidth))
        return Card(
            confirmation: confirmation,
            detailLines: detailLines,
            codeWidth: codeWidth,
            height: M.cardHeight(isFlight: confirmation.isFlight, detailLines: detailLines, hasContact: !confirmation.contact.isEmpty)
        )
    }

    struct Section {
        let section: String
        let symbolName: String
        let cards: [Card]
    }

    /// Consecutive cards of one section, in order.
    static func sections(_ cards: [Card]) -> [Section] {
        var sections: [Section] = []
        for card in cards {
            if let last = sections.last, last.section == card.confirmation.section {
                sections[sections.count - 1] = Section(section: last.section, symbolName: last.symbolName, cards: last.cards + [card])
            } else {
                sections.append(Section(section: card.confirmation.section, symbolName: card.confirmation.symbolName, cards: [card]))
            }
        }
        return sections
    }

    /// The cover's day-by-day summary: every day when they fit, otherwise the
    /// first ones and a line saying how many more there are.
    static func glance(_ days: [ItineraryDocument.Day], capacity: Int, measure: TextMeasure) -> [GlanceRow] {
        let shown = days.count <= capacity ? days : Array(days.prefix(max(0, capacity - 1)))
        return shown.map { day in
            // As many titles as fit on the one line, never fewer than one: an
            // ellipsis mid-name reads worse than "+4".
            let titles = day.lines.map(\.title)
            var count = min(titles.count, 3)
            while count > 1, measure.width(titles.prefix(count).joined(separator: " · "), .glance) > ItineraryMetrics.glanceHighlightsWidth - 24 {
                count -= 1
            }
            return GlanceRow(
                dayNumber: day.dayNumber,
                date: day.shortDate,
                highlights: titles.isEmpty ? nothingPlanned : titles.prefix(count).joined(separator: " · "),
                more: titles.count - count,
                weather: day.weather
            )
        }
    }

    /// What an empty day says, in the cover's list and on its own row.
    static let nothingPlanned = "Nothing planned"

    /// How tall a day, or a piece of one, is drawn — the same sum `flow`
    /// packed it with.
    static func sliceHeight(_ slice: DaySlice) -> Double {
        let rows = slice.rows.isEmpty ? ItineraryMetrics.emptyDayRowHeight : slice.rows.map(\.height).reduce(0, +)
        return max(ItineraryMetrics.badgeHeight, ItineraryMetrics.dayHeaderHeight + rows)
    }

    /// The two lines at the foot of every page.
    struct Footer: Equatable {
        /// "Rome & Amalfi · 6–14 Jun 2026".
        let trip: String
        /// "Page 2 of 5".
        let pageNumber: String
        /// Apple's credit and when the forecast was fetched, on a page that
        /// shows weather — WeatherKit's terms want the credit and the legal
        /// link wherever its data appears, and a PDF can't load the live
        /// `WeatherAttributionView`, so the link is printed as text. Nil on a
        /// page without weather.
        let weatherCredit: String?

        /// The legal page `WeatherAttributionView` links to. Printed as text,
        /// and made a real link over `ItineraryMetrics.weatherCreditRect` for
        /// whoever reads the PDF on a screen — text alone was only a link in
        /// the viewers that happen to guess at URLs.
        static let legalAttributionURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

        init(document: ItineraryDocument, page: Page, number: Int, count: Int) {
            trip = document.dateRange.isEmpty ? document.title : "\(document.title) · \(document.dateRange)"
            pageNumber = "Page \(number) of \(count)"
            if page.showsWeather, let asOf = document.weatherAsOf {
                let link = "\(Self.legalAttributionURL.host() ?? "")\(Self.legalAttributionURL.path())"
                weatherCredit = "Apple Weather · Other data sources: \(link) · forecast as of \(asOf)"
            } else {
                weatherCredit = nil
            }
        }
    }

    /// "Days 1–3", "Day 4", "Day 4, continued".
    static func label(for slices: [DaySlice]) -> String {
        guard let first = slices.first, let last = slices.last else { return "" }
        if first.day.dayNumber == last.day.dayNumber {
            return first.isContinuation ? "Day \(first.day.dayNumber), continued" : "Day \(first.day.dayNumber)"
        }
        return "Days \(first.day.dayNumber)–\(last.day.dayNumber)"
    }

    /// "Page 2", "Pages 3–5".
    static func pageSpan(_ first: Int, count: Int) -> String {
        count <= 1 ? "Page \(first)" : "Pages \(first)–\(first + count - 1)"
    }
}

// MARK: - Metrics

/// Every size on the page, in points, read by both the layout and the views
/// that draw it, so the two can't disagree about how tall anything is.
///
/// The page is US Letter, but everything sits inside an A4 page's width too:
/// 54pt side margins leave 504pt of text, and A4 is only 17pt narrower than
/// Letter. Printing either way needs no scaling.
enum ItineraryMetrics {
    static let pageSize = CGSize(width: 612, height: 792)
    static let sideMargin = 54.0
    static let topMargin = 46.0
    static let bottomMargin = 40.0
    static let bodyWidth = pageSize.width - 2 * sideMargin
    /// Two lines of footer, and the rule and space above them.
    static let footerHeight = 34.0
    static let bodyHeight = pageSize.height - topMargin - bottomMargin - footerHeight - 12
    /// The footer's second line, where the weather credit sits, in the PDF's
    /// own coordinates — origin bottom left, which is what a link annotation
    /// is placed in. It stops short of "Made in Multitrack" on the right.
    static let weatherCreditRect = CGRect(x: sideMargin, y: bottomMargin, width: bodyWidth - 80, height: 10)

    /// "Day by day" or "Flights & bookings", its rule and the space under it.
    static let pageHeaderHeight = 48.0

    // Days
    static let badgeWidth = 46.0
    static let badgeSpacing = 12.0
    static let badgeHeight = 52.0
    static let dayHeaderHeight = 22.0
    static let dayGap = 25.0
    static let timeWidth = 50.0
    static let iconWidth = 14.0
    static let rowSpacing = 6.0
    static let rowPadding = 4.5
    static let flightInset = 6.0
    static let maxTitleLines = 2
    static let maxDetailLines = 3
    static var rowTextWidth: Double {
        bodyWidth - badgeWidth - badgeSpacing - timeWidth - iconWidth - 2 * rowSpacing - 2 * flightInset
    }
    static let emptyDayRowHeight = 24.0

    static func rowHeight(titleLines: Int, detailLines: Int) -> Double {
        let detail = detailLines == 0 ? 0 : 1 + Double(detailLines) * ItineraryType.rowDetail.lineHeight
        return (2 * rowPadding + Double(titleLines) * ItineraryType.rowTitle.lineHeight + detail).rounded(.up)
    }

    // Confirmations
    static let groupHeaderHeight = 20.0
    static let groupGap = 6.0
    static let cardPadding = 12.0
    static let cardSpacing = 12.0
    static let cardGap = 7.0
    static let codePadding = 10.0
    /// The tracking between a code's characters, drawn and measured.
    static let codeKerning = 0.5
    static let minCodeWidth = 118.0
    static let maxCodeWidth = 230.0

    static func cardHeight(isFlight: Bool, detailLines: Int, hasContact: Bool) -> Double {
        let detail = Double(detailLines) * ItineraryType.cardDetail.lineHeight
        let text = isFlight
            ? ItineraryType.cardLabel.lineHeight + ItineraryType.route.lineHeight + 2 + detail
            : ItineraryType.cardTitle.lineHeight + 2 + detail + (hasContact ? 2 + ItineraryType.cardDetail.lineHeight : 0)
        let codeBox = 2 * 6 + ItineraryType.cardLabel.lineHeight + ItineraryType.code.lineHeight
        return (max(text, codeBox) + 2 * 10 + cardGap).rounded(.up)
    }

    // Cover
    static let glanceRowHeight = 22.0
    static let glanceDayWidth = 40.0
    static let glanceDateWidth = 70.0
    static let glanceWeatherWidth = 74.0
    static var glanceHighlightsWidth: Double {
        bodyWidth - glanceDayWidth - glanceDateWidth - glanceWeatherWidth - 3 * 10
    }
    static let contentsRowHeight = 17.0
    /// Everything on the cover but the title and the rows: the label, place,
    /// dates, stat tiles and two section headers. Summed from typed parts: as
    /// one literal expression it timed out the type checker.
    static let coverFixedHeight: Double = {
        let label: Double = 20, destination: Double = 22, dates: Double = 20, stats: Double = 78
        let sectionHeaders: Double = 2 * 44, underContents: Double = 8
        return label + destination + dates + stats + sectionHeaders + underContents
    }()

    /// How many at-a-glance rows fit under a title of `titleLines`.
    static func glanceCapacity(titleLines: Int, contentsCount: Int) -> Int {
        let title = Double(titleLines) * ItineraryType.coverTitle.lineHeight
        let free = bodyHeight - coverFixedHeight - title - Double(contentsCount) * contentsRowHeight
        return max(1, Int(free / glanceRowHeight))
    }
}

/// The type styles on the page. The views draw with `font`, and the layout
/// measures with the same size and weight.
enum ItineraryType: Sendable {
    case coverTitle, rowTitle, rowDetail, cardTitle, cardDetail, cardLabel, route, code, glance

    var size: Double {
        switch self {
        case .coverTitle: 38
        case .rowTitle: 11.5
        case .rowDetail, .cardDetail: 9.5
        case .cardTitle: 13
        case .cardLabel: 7.5
        case .route: 21
        case .code: 15
        case .glance: 10
        }
    }

    var isBold: Bool {
        switch self {
        case .coverTitle, .rowTitle, .cardTitle, .cardLabel, .route, .code: true
        case .rowDetail, .cardDetail, .glance: false
        }
    }

    var isMonospaced: Bool { self == .code }

    /// San Francisco's own line height is about 1.19 times its size; a little
    /// over that, so a measured row never comes out short.
    var lineHeight: Double { (size * 1.22).rounded(.up) }
}

/// How the layout measures text: lines at a width, and the width of one line.
/// Core Text in the app; tests pass their own, so pagination is testable
/// without depending on the fonts installed.
struct TextMeasure: Sendable {
    let lines: @Sendable (String, ItineraryType, Double) -> Int
    let width: @Sendable (String, ItineraryType) -> Double

    /// Core Text's San Francisco, the same face SwiftUI's `.system` draws
    /// with. Bold stands in for semibold: slightly wider, so it errs toward
    /// one line too many — a shorter page — never a line too few.
    static let coreText = TextMeasure(
        lines: { text, type, width in
            guard !text.isEmpty else { return 0 }
            let framesetter = CTFramesetterCreateWithAttributedString(attributed(text, type))
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: width * 0.97, height: 10_000), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            return max(1, CFArrayGetCount(CTFrameGetLines(frame)))
        },
        width: { text, type in
            // SF Mono's advance is 0.6em for every character, bold or not.
            if type.isMonospaced { return Double(text.count) * type.size * 0.6 }
            let line = CTLineCreateWithAttributedString(attributed(text, type))
            return CTLineGetTypographicBounds(line, nil, nil, nil)
        }
    )

    private static func attributed(_ text: String, _ type: ItineraryType) -> NSAttributedString {
        let font = CTFontCreateUIFontForLanguage(type.isBold ? .emphasizedSystem : .system, type.size, nil)
        return NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font as Any])
    }
}

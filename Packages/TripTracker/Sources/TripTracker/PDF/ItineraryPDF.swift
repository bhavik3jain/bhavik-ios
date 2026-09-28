import CoreGraphics
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Writes an `ItineraryDocument` to a PDF file.
///
/// `ImageRenderer` drawing SwiftUI views into a CoreGraphics PDF context — not
/// `UIGraphicsPDFRenderer`, which is UIKit-only and would need a Mac shim. The
/// pages use flat fills and system fonts only: any material, blur or shadow
/// makes the renderer rasterise the whole page, and the text stops being
/// selectable or searchable in the reader's PDF viewer.
enum ItineraryPDF {
    /// US Letter, in points.
    static let pageSize = ItineraryMetrics.pageSize

    @MainActor
    static func write(_ document: ItineraryDocument, to url: URL) throws {
        // Laid out here, when a file is actually wanted, and not in the
        // document: that is built on every redraw of the trip screen.
        let layout = ItineraryLayout(document: document)
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, [
                  kCGPDFContextTitle as String: document.title,
                  kCGPDFContextCreator as String: "Multitrack",
              ] as CFDictionary)
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        for (index, page) in layout.pages.enumerated() {
            let footer = ItineraryLayout.Footer(document: document, page: page, number: index + 1, count: layout.pages.count)
            let renderer = ImageRenderer(content:
                ItineraryPageView(page: page, footer: footer)
                    .frame(width: pageSize.width, height: pageSize.height)
                    // Paper is white whatever the phone is set to.
                    .environment(\.colorScheme, .light)
            )
            renderer.proposedSize = ProposedViewSize(pageSize)
            context.beginPDFPage(nil)
            renderer.render { _, draw in
                draw(context)
            }
            context.endPDFPage()
        }
        context.closePDF()
    }
}

/// What the Share button hands to `ShareLink`: the itinerary as a PDF file,
/// rendered only when a destination is actually chosen rather than every time
/// the trip screen redraws.
struct ItineraryFile: Transferable, Sendable {
    let document: ItineraryDocument

    var filename: String {
        let cleaned = document.title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\(cleaned.isEmpty ? "Trip" : cleaned) itinerary.pdf"
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { file in
            // A fresh folder per export, so sharing twice never collides with a
            // file the share sheet still holds open.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(file.filename)
            try await MainActor.run { try ItineraryPDF.write(file.document, to: url) }
            return SentTransferredFile(url)
        }
    }
}

// MARK: - Pages

/// The colours on paper. Everything that carries meaning also has a shape —
/// a rule, a box, an icon — so the page still reads from a black-and-white
/// laser printer, where the accent comes out as a mid grey.
private enum Ink {
    static let accent = TripTrackerModule.accent.color
    static let accentTint = TripTrackerModule.accent.color.opacity(0.08)
    static let text = Color(white: 0.1)
    static let muted = Color(white: 0.42)
    static let faint = Color(white: 0.6)
    static let rule = Color(white: 0.89)
    static let ruleStrong = Color(white: 0.8)
    static let fill = Color(white: 0.95)
}

/// One Letter page. Drawn only for the PDF, so it hard-codes its colours and
/// sizes instead of following the device's appearance and Dynamic Type — and
/// every size comes from `ItineraryMetrics`, which the layout measured with,
/// so a row is drawn at exactly the height its page was packed with.
struct ItineraryPageView: View {
    let page: ItineraryLayout.Page
    let footer: ItineraryLayout.Footer

    private typealias M = ItineraryMetrics

    var body: some View {
        ZStack(alignment: .top) {
            Color.white
            if case .cover = page {
                Ink.accent.frame(height: 10)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
                    .frame(width: M.bodyWidth, height: M.bodyHeight, alignment: .topLeading)
                Spacer(minLength: 0)
                footerView
                    .frame(width: M.bodyWidth, height: M.footerHeight, alignment: .bottom)
            }
            .padding(.top, M.topMargin)
            .padding(.bottom, M.bottomMargin)
            .padding(.horizontal, M.sideMargin)
        }
        .frame(width: M.pageSize.width, height: M.pageSize.height)
        .foregroundStyle(Ink.text)
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .cover(let cover): CoverPageView(page: cover)
        case .confirmations(let codes): ConfirmationsPageView(page: codes)
        case .days(let days): DaysPageView(page: days)
        }
    }

    private var footerView: some View {
        VStack(alignment: .leading, spacing: 3) {
            Ink.rule.frame(height: 0.75)
                .padding(.bottom, 4)
            HStack {
                Text(footer.trip)
                Spacer()
                Text(footer.pageNumber).monospacedDigit()
            }
            .font(.system(size: 8.5))
            .foregroundStyle(Ink.muted)
            .frame(height: 11)
            HStack {
                Text(footer.weatherCredit ?? "")
                Spacer()
                Text("Made in Multitrack")
            }
            .font(.system(size: 7.5))
            // Fixed, so a page without the weather credit puts its footer at
            // the same height as one with it.
            .frame(height: 10)
            .foregroundStyle(Ink.faint)
        }
        .lineLimit(1)
    }
}

/// "TRIP ITINERARY", "AT A GLANCE": small bold capitals with a little air.
private func caps(_ text: String, size: Double) -> Text {
    Text(text.uppercased())
        .font(.system(size: size, weight: .bold))
        .kerning(size * 0.06)
}

/// A page's title with its accent rule, 48pt tall with the space under it.
private struct PageHeader: View {
    let title: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .kerning(-0.2)
                Spacer()
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(Ink.muted)
            }
            .padding(.bottom, 6)
            .frame(height: ItineraryMetrics.pageHeaderHeight - 14 - 1.5, alignment: .bottom)
            Ink.accent.frame(height: 1.5)
            Spacer(minLength: 0)
        }
        .frame(height: ItineraryMetrics.pageHeaderHeight)
    }
}

// MARK: Cover

private struct CoverPageView: View {
    let page: ItineraryLayout.CoverPage

    private typealias M = ItineraryMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            caps("Trip itinerary", size: 9.5)
                .foregroundStyle(Ink.accent)
                .frame(height: 12, alignment: .bottomLeading)
                .padding(.top, 8)
            Text(page.cover.title)
                .font(.system(size: ItineraryType.coverTitle.size, weight: .bold))
                .kerning(-0.5)
                .lineLimit(page.titleLines)
                .minimumScaleFactor(0.75)
                .frame(height: Double(page.titleLines) * ItineraryType.coverTitle.lineHeight, alignment: .leading)
            Text(page.cover.destination)
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .lineLimit(1)
                .frame(height: 22, alignment: .bottomLeading)
            Text(page.cover.dateRange)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 20, alignment: .bottomLeading)

            stats
                .padding(.top, 22)

            sectionHeader("At a glance", note: page.glance.contains { $0.weather != nil } ? "Weather: high / low" : nil)
            ForEach(Array(page.glance.enumerated()), id: \.offset) { _, row in
                glanceRow(row)
            }
            if let more = page.moreDays {
                Text(more)
                    .font(.system(size: 10))
                    .foregroundStyle(Ink.muted)
                    .frame(height: M.glanceRowHeight, alignment: .leading)
            }

            if !page.contents.isEmpty {
                sectionHeader("In this itinerary", note: nil)
                    .padding(.bottom, 8)
                ForEach(Array(page.contents.enumerated()), id: \.offset) { _, entry in
                    HStack {
                        Text(entry.title)
                        Spacer()
                        Text(entry.pages)
                            .foregroundStyle(Ink.muted)
                            .monospacedDigit()
                    }
                    .font(.system(size: 10.5))
                    .frame(height: M.contentsRowHeight)
                }
            }
        }
    }

    /// Days, places, flights, bookings, between two rules.
    private var stats: some View {
        HStack(spacing: 0) {
            ForEach(Array(page.cover.facts.enumerated()), id: \.offset) { index, fact in
                HStack(spacing: 0) {
                    if index > 0 {
                        Ink.rule.frame(width: 0.75)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(fact.value)
                            .font(.system(size: 24, weight: .bold))
                            .monospacedDigit()
                        caps(fact.label, size: 8.5)
                            .foregroundStyle(Ink.muted)
                    }
                    .padding(.leading, index > 0 ? 12 : 0)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 56)
        .overlay(alignment: .top) { Ink.ruleStrong.frame(height: 0.75) }
        .overlay(alignment: .bottom) { Ink.ruleStrong.frame(height: 0.75) }
    }

    /// 44pt: the space above, the label, and the accent rule under it.
    private func sectionHeader(_ title: String, note: String?) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                caps(title, size: 9.5)
                    .foregroundStyle(Ink.accent)
                Spacer()
                if let note {
                    Text(note)
                        .font(.system(size: 8.5))
                        .foregroundStyle(Ink.muted)
                }
            }
            .padding(.bottom, 4)
            Ink.accent.frame(height: 1.5)
        }
        .frame(height: 44, alignment: .bottom)
    }

    private func glanceRow(_ row: ItineraryLayout.GlanceRow) -> some View {
        HStack(spacing: 10) {
            caps("Day \(row.dayNumber)", size: 8.5)
                .foregroundStyle(Ink.accent)
                .frame(width: M.glanceDayWidth, alignment: .leading)
            Text(row.date)
                .font(.system(size: 10))
                .frame(width: M.glanceDateWidth, alignment: .leading)
            Group {
                if row.more > 0 {
                    Text("\(Text(row.highlights)) \(Text("+\(row.more)").foregroundStyle(Ink.faint))")
                } else {
                    Text(row.highlights)
                        .foregroundStyle(row.highlights == ItineraryLayout.nothingPlanned ? Ink.muted : Ink.text)
                }
            }
            .font(.system(size: 10))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                if let weather = row.weather {
                    Image(systemName: weather.symbolName)
                        .symbolRenderingMode(.monochrome)
                    Text(weather.temperatures)
                }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(Ink.muted)
            .frame(width: M.glanceWeatherWidth, alignment: .trailing)
        }
        .lineLimit(1)
        .frame(height: M.glanceRowHeight)
        .overlay(alignment: .bottom) { Ink.rule.frame(height: 0.5) }
    }
}

// MARK: Flights & bookings

private struct ConfirmationsPageView: View {
    let page: ItineraryLayout.ConfirmationsPage

    private typealias M = ItineraryMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Flights & bookings", label: page.isContinuation ? "Continued" : "Codes to show at the desk")
            ForEach(Array(page.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Spacer().frame(height: M.groupGap)
                }
                HStack(spacing: 5) {
                    Image(systemName: group.symbolName)
                        .font(.system(size: 8.5))
                    caps(group.section, size: 8.5)
                }
                .foregroundStyle(Ink.muted)
                .frame(height: M.groupHeaderHeight, alignment: .leading)
                ForEach(Array(group.cards.enumerated()), id: \.offset) { _, card in
                    CardView(card: card)
                        .frame(height: card.height - M.cardGap)
                        .padding(.bottom, M.cardGap)
                }
            }
        }
    }
}

private struct CardView: View {
    let card: ItineraryLayout.Card

    private typealias M = ItineraryMetrics
    private var confirmation: ItineraryDocument.Confirmation { card.confirmation }

    var body: some View {
        HStack(spacing: M.cardSpacing) {
            VStack(alignment: .leading, spacing: 0) {
                if confirmation.isFlight {
                    caps(confirmation.date, size: ItineraryType.cardLabel.size)
                        .foregroundStyle(Ink.muted)
                    Text(confirmation.title)
                        .font(.system(size: ItineraryType.route.size, weight: .bold))
                        .kerning(0.2)
                        .minimumScaleFactor(0.6)
                } else {
                    Text(confirmation.title)
                        .font(.system(size: ItineraryType.cardTitle.size, weight: .bold))
                }
                if card.detailLines > 0 {
                    Text(confirmation.detail)
                        .font(.system(size: ItineraryType.cardDetail.size))
                        .foregroundStyle(Ink.muted)
                        .lineLimit(card.detailLines)
                        .padding(.top, 2)
                }
                if !confirmation.contact.isEmpty {
                    Text(confirmation.contact)
                        .font(.system(size: ItineraryType.cardDetail.size))
                        .foregroundStyle(Ink.muted)
                        .padding(.top, 2)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 0) {
                caps("Confirmation", size: 7)
                    .foregroundStyle(Ink.muted)
                Text(confirmation.code.isEmpty ? "—" : confirmation.code)
                    .font(.system(size: ItineraryType.code.size, weight: .bold, design: .monospaced))
                    .kerning(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, M.codePadding)
            .frame(width: card.codeWidth, alignment: .trailing)
            .background(Ink.fill, in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.horizontal, M.cardPadding)
        .padding(.vertical, 10)
        .frame(maxHeight: .infinity)
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Ink.ruleStrong, lineWidth: 0.75)
        }
    }
}

// MARK: Day by day

private struct DaysPageView: View {
    let page: ItineraryLayout.DaysPage

    private typealias M = ItineraryMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Day by day", label: page.label)
            ForEach(Array(page.slices.enumerated()), id: \.offset) { index, slice in
                if index > 0 {
                    // The gap between days, with a hairline across its middle.
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Ink.rule.frame(height: 0.75)
                        Spacer(minLength: 0)
                    }
                    .frame(height: M.dayGap)
                }
                DaySliceView(slice: slice)
            }
        }
    }
}

private struct DaySliceView: View {
    let slice: ItineraryLayout.DaySlice

    private typealias M = ItineraryMetrics
    private var day: ItineraryDocument.Day { slice.day }

    var body: some View {
        HStack(alignment: .top, spacing: M.badgeSpacing) {
            badge
            VStack(alignment: .leading, spacing: 0) {
                header
                if slice.rows.isEmpty {
                    Text("Nothing planned")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Ink.muted)
                        .padding(.leading, M.flightInset)
                        .frame(height: M.emptyDayRowHeight, alignment: .leading)
                }
                ForEach(Array(slice.rows.enumerated()), id: \.offset) { index, row in
                    RowView(row: row)
                        .overlay(alignment: .top) {
                            // A hairline between rows, but not against a
                            // flight's tint, which is its own edge.
                            if index > 0, !row.line.isFlight, !slice.rows[index - 1].line.isFlight {
                                Ink.rule.frame(height: 0.5)
                            }
                        }
                }
            }
        }
        .frame(height: ItineraryLayout.sliceHeight(slice), alignment: .top)
    }

    private var badge: some View {
        VStack(spacing: 0) {
            caps(day.weekday, size: 7.5)
                .foregroundStyle(Ink.muted)
            Text(day.dayOfMonth)
                .font(.system(size: 22, weight: .bold))
                .monospacedDigit()
            caps(day.month, size: 7.5)
                .foregroundStyle(Ink.muted)
        }
        .lineLimit(1)
        .frame(width: M.badgeWidth, height: M.badgeHeight)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Ink.ruleStrong, lineWidth: 0.75)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(Text("Day \(day.dayNumber)").foregroundStyle(Ink.accent)) · \(day.heading)")
                .font(.system(size: 13.5, weight: .bold))
            if slice.isContinuation {
                Text("continued")
                    .font(.system(size: 8.5))
                    .foregroundStyle(Ink.muted)
            }
            Spacer(minLength: 8)
            if let weather = day.weather {
                HStack(spacing: 4) {
                    Image(systemName: weather.symbolName)
                        .symbolRenderingMode(.monochrome)
                    Text("\(weather.summary) · \(weather.temperatures)")
                }
                .font(.system(size: 9.5))
                .foregroundStyle(Ink.muted)
            }
        }
        .lineLimit(1)
        .frame(height: M.dayHeaderHeight, alignment: .top)
    }
}

private struct RowView: View {
    let row: ItineraryLayout.Row

    private typealias M = ItineraryMetrics
    private var line: ItineraryDocument.Line { row.line }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: M.rowSpacing) {
            Group {
                if let time = line.time {
                    Text(time)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                } else {
                    caps("Anytime", size: 6.5)
                        .foregroundStyle(Ink.muted)
                }
            }
            .lineLimit(1)
            .frame(width: M.timeWidth, alignment: .trailing)

            Image(systemName: line.symbolName)
                .font(.system(size: 9))
                .foregroundStyle(Ink.accent)
                .frame(width: M.iconWidth)

            VStack(alignment: .leading, spacing: 1) {
                title
                    .font(.system(size: ItineraryType.rowTitle.size, weight: .semibold))
                    .lineLimit(row.titleLines)
                if row.detailLines > 0 {
                    Text(line.detail)
                        .font(.system(size: ItineraryType.rowDetail.size))
                        .foregroundStyle(Ink.muted)
                        .lineLimit(row.detailLines)
                }
            }
            .frame(width: M.rowTextWidth, alignment: .leading)
        }
        // No Spacer to push the row out: in an HStack it takes a spacing of
        // its own too, which ran every row 6pt past the page's right margin.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, M.rowPadding)
        .padding(.horizontal, M.flightInset)
        .frame(height: row.height, alignment: .top)
        .background {
            if line.isFlight {
                // Tinted, and a solid rule down the left edge: the rule is
                // what still marks a flight once the tint prints as nothing.
                ZStack(alignment: .leading) {
                    Ink.accentTint
                    Ink.accent.frame(width: 2.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3))
            }
        }
    }

    /// The title, and its duration after it in lighter type.
    private var title: Text {
        if line.duration.isEmpty { return Text(line.title) }
        let duration = Text("· \(line.duration)")
            .font(.system(size: ItineraryType.rowDetail.size))
            .foregroundStyle(Ink.muted)
        return Text("\(Text(line.title)) \(duration)")
    }
}

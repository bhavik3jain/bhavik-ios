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
    static let pageSize = CGSize(width: 612, height: 792)

    @MainActor
    static func write(_ document: ItineraryDocument, to url: URL) throws {
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, [
                  kCGPDFContextTitle as String: document.title,
                  kCGPDFContextCreator as String: "Multitrack",
              ] as CFDictionary)
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        for (index, page) in document.pages.enumerated() {
            let renderer = ImageRenderer(content:
                ItineraryPageView(page: page, pageNumber: index + 1, pageCount: document.pages.count)
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

/// One Letter page. Drawn only for the PDF, so it hard-codes its colours and
/// sizes instead of following the device's appearance and Dynamic Type.
struct ItineraryPageView: View {
    let page: ItineraryDocument.Page
    let pageNumber: Int
    let pageCount: Int

    private let accent = TripTrackerModule.accent.color
    private let ink = Color.black
    private let muted = Color(white: 0.43)
    private let rule = Color(white: 0.9)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch page {
            case .cover(let cover):
                coverBody(cover)
            case .day(let day):
                dayBody(day)
            case .confirmations(let lines, let part, let partCount):
                confirmationsBody(lines, part: part, partCount: partCount)
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(.horizontal, 54)
        .padding(.vertical, 50)
        .frame(width: ItineraryPDF.pageSize.width, height: ItineraryPDF.pageSize.height, alignment: .topLeading)
        .background(Color.white)
    }

    private var footer: some View {
        HStack {
            Text("Made in Multitrack")
            Spacer()
            Text("\(pageNumber) / \(pageCount)")
                .monospacedDigit()
        }
        .font(.system(size: 9))
        .foregroundStyle(muted)
    }

    private func coverBody(_ cover: ItineraryDocument.Cover) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(accent)
                .frame(width: 48, height: 6)
                .padding(.top, 120)
            Text(cover.title)
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(ink)
            if !cover.destination.isEmpty {
                Text(cover.destination)
                    .font(.system(size: 18))
                    .foregroundStyle(muted)
            }
            Text(cover.dateRange)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(ink)
                .padding(.top, 12)
            Text(cover.facts)
                .font(.system(size: 13))
                .foregroundStyle(muted)
        }
    }

    private func dayBody(_ day: ItineraryDocument.DayPage) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(day.heading.uppercased())
                    .font(.system(size: 13, weight: .bold))
                    .kerning(0.4)
                    .foregroundStyle(accent)
                if day.partCount > 1 {
                    Text(day.part == 1 ? "continues" : "continued, \(day.part) of \(day.partCount)")
                        .font(.system(size: 10))
                        .foregroundStyle(muted)
                }
            }
            .padding(.bottom, 14)

            if day.lines.isEmpty {
                Text("Nothing planned.")
                    .font(.system(size: 13))
                    .foregroundStyle(muted)
            }

            ForEach(Array(day.lines.enumerated()), id: \.offset) { index, line in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(line.time)
                            .font(.system(size: 12))
                            .monospacedDigit()
                        if !line.duration.isEmpty {
                            Text(line.duration)
                                .font(.system(size: 9))
                        }
                    }
                    .foregroundStyle(muted)
                    .frame(width: 52, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: line.symbolName)
                                .font(.system(size: 10))
                                .foregroundStyle(accent)
                            Text(line.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(ink)
                        }
                        if !line.detail.isEmpty {
                            Text(line.detail)
                                .font(.system(size: 11))
                                .foregroundStyle(muted)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 9)
                .overlay(alignment: .top) {
                    if index > 0 {
                        Rectangle().fill(rule).frame(height: 0.5)
                    }
                }
            }
        }
    }

    private func confirmationsBody(_ lines: [ItineraryDocument.Confirmation], part: Int, partCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(partCount > 1 && part > 1 ? "CONFIRMATIONS, CONTINUED" : "CONFIRMATIONS")
                .font(.system(size: 13, weight: .bold))
                .kerning(0.4)
                .foregroundStyle(accent)
                .padding(.bottom, 8)

            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                if index == 0 || lines[index - 1].section != line.section {
                    Text(line.section.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .kerning(0.3)
                        .foregroundStyle(muted)
                        .padding(.top, 12)
                        .padding(.bottom, 4)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ink)
                        if !line.detail.isEmpty {
                            Text(line.detail)
                                .font(.system(size: 10))
                                .foregroundStyle(muted)
                        }
                    }
                    Spacer()
                    Text(line.code.isEmpty ? "—" : line.code)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ink)
                }
                .padding(.vertical, 6)
            }
        }
    }
}

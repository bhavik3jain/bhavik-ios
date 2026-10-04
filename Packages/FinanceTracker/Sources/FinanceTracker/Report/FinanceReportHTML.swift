import Core
import Foundation

/// The Finance report as one self-contained web page: a pure function of a
/// `FinanceReportData` (every figure already added up and worded) and, when
/// there is one, the month's review.
///
/// The same page is shown in the phone's report sheet and the Mac report
/// window (Core's `HTMLDocumentView`), saved as a PDF, printed, and shared as
/// an `.html` file, so it is written to stand alone: inline CSS and SVG, no
/// script, no font or image from anywhere, and a Content-Security-Policy
/// that refuses every load in case anything ever slipped in. Light and dark
/// follow `prefers-color-scheme`; exports always render light.
///
/// Every string that came from the household — account, owner, category,
/// merchant and item names, and the review's wording — goes through
/// `escape(_:)`. A merchant typed as `<script>` must arrive as text.
///
/// Section ids are `FinanceReportData.sections`' ids (`brief`, `networth`,
/// `figures`, `mix`, `moved`, `trend`, `accounts`, `metals`, `spending`,
/// `cards`, `fixing`), so the viewer's "Jump to Section" and the Mac contents
/// sidebar can scroll to them. Use `sections(for:review:options:)` for that
/// list: it leaves out the brief when the page has none.
public enum FinanceReportHTML {
    public struct Options: Sendable, Equatable {
        /// A "Table view" `<details>` under each chart, with the same figures as rows.
        public var includeTables: Bool
        /// Whether a given review is shown at all ("Include Review" in the viewer's menu).
        public var includeReview: Bool

        public init(includeTables: Bool = true, includeReview: Bool = true) {
            self.includeTables = includeTables
            self.includeReview = includeReview
        }
    }

    /// The review as the page shows it: "The month in brief". Built from the
    /// review (model-written or Swift's own plain wording) by whoever renders
    /// the page; the page itself never decides what the review says.
    public struct ReviewBlock: Sendable, Equatable {
        public var headline: String
        public var wentWell: [String]
        public var watch: [String]
        public var tryNext: [String]
        /// Apple Intelligence wrote some of it: the brief gets the sparkle,
        /// the purple border and a footnote saying so. Otherwise it is the
        /// app's own checks, worded by Swift.
        public var isModelWritten: Bool
        /// "Try in October"; nil works it out from the report's scope.
        public var tryNextTitle: String?

        public init(
            headline: String,
            wentWell: [String],
            watch: [String],
            tryNext: [String],
            isModelWritten: Bool,
            tryNextTitle: String? = nil
        ) {
            self.headline = headline
            self.wentWell = wentWell
            self.watch = watch
            self.tryNext = tryNext
            self.isModelWritten = isModelWritten
            self.tryNextTitle = tryNextTitle
        }

        public var isEmpty: Bool {
            headline.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && wentWell.isEmpty && watch.isEmpty && tryNext.isEmpty
        }
    }

    /// The page's sections in order, as the viewer's "Jump to Section" and
    /// the Mac sidebar should list them: `data.sections`, less the brief when
    /// this page doesn't show one.
    public static func sections(
        for data: FinanceReportData,
        brief: ReviewBlock?,
        options: Options = Options()
    ) -> [FinanceReportData.ReportSection] {
        let showsBrief = options.includeReview && brief.map { !$0.isEmpty } == true
        return data.sections.filter { showsBrief || $0.id != "brief" }
    }

    /// The whole page.
    public static func render(_ data: FinanceReportData, brief: ReviewBlock?, options: Options = Options()) -> String {
        let shownReview = options.includeReview ? brief.flatMap { $0.isEmpty ? nil : $0 } : nil
        let page = Page(data: data, review: shownReview, options: options)
        return page.html
    }

    // MARK: - Escaping and numbers

    /// Text for HTML content and attribute values alike.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    /// A CSS percentage from a 0…1 fraction, clamped, always with a "."
    /// decimal point: `String(format:)` without a locale is POSIX, so a
    /// comma-decimal region can't write "12,5%" and break the style.
    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "0%" }
        return String(format: "%.2f%%", min(max(fraction, 0), 1) * 100)
    }

    /// An SVG coordinate.
    static func coordinate(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.1f", value)
    }

    /// "good", "bad" or "flat" for a signed change, after rounding to the dollar.
    static func toneClass(_ change: Double?) -> String {
        guard let change else { return "flat" }
        let rounded = change.rounded()
        return rounded > 0 ? "good" : (rounded < 0 ? "bad" : "flat")
    }

    /// `style` for a bar in an owner's colour, light and dark (`.oc`).
    static func ownerStyle(_ owner: FinanceReportData.OwnerChip?) -> (className: String, style: String) {
        guard let owner else { return ("", "background:var(--muted)") }
        return ("oc", "--ocl:\(escape(owner.colorHex));--ocd:\(escape(owner.colorHexDark))")
    }

    /// The sparkle Apple Intelligence's brief is marked with.
    static let sparkle = """
    <svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round" aria-hidden="true">\
    <path d="M11 3c.6 4.6 2.4 6.4 7 7-4.6.6-6.4 2.4-7 7-.6-4.6-2.4-6.4-7-7 4.6-.6 6.4-2.4 7-7z"/>\
    <path d="M18.5 14.5c.2 1.6.9 2.3 2.5 2.5-1.6.2-2.3.9-2.5 2.5-.2-1.6-.9-2.3-2.5-2.5 1.6-.2 2.3-.9 2.5-2.5z"/></svg>
    """
}

// MARK: - Page

extension FinanceReportHTML {
    /// One render: the data, what's shown, and the sections built in page order.
    struct Page {
        let data: FinanceReportData
        let review: ReviewBlock?
        let options: Options

        var isYear: Bool { data.scope.isYear }

        /// `FinanceReportHTML.escape`, reachable unqualified from the section extensions.
        func escape(_ text: String) -> String { FinanceReportHTML.escape(text) }

        var html: String {
            var body = header
            body += hero
            if let review { body += brief(review) }
            body += figures
            body += mix
            body += moved
            body += trend
            body += accounts
            body += metals
            body += spending
            body += cards
            body += fixing
            body += footer
            return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="light dark">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
            <title>\(escape(data.header.title)) report</title>
            <style>
            \(FinanceReportHTML.stylesheet)
            </style>
            </head>
            <body>
            <main class="wrap">
            \(body)
            </main>
            </body>
            </html>
            """
        }

        /// The title the data gives a section, so the page's headings and the
        /// Jump to Section menu always agree.
        func title(of id: String, otherwise fallback: String) -> String {
            data.sections.first { $0.id == id }?.title ?? fallback
        }

        /// A "Table view" disclosure, when tables are on.
        func tableView(_ table: String, summary: String = "Table view") -> String {
            guard options.includeTables, !table.isEmpty else { return "" }
            return "<details><summary>\(escape(summary))</summary><div class=\"tbl\">\(table)</div></details>"
        }

        /// A table from a header row and rows of already-escaped cells; a
        /// header starting with ">" is right-aligned (and so is its column).
        func makeTable(_ headers: [String], _ rows: [[String]]) -> String {
            guard !rows.isEmpty else { return "" }
            let aligned = headers.map { $0.hasPrefix(">") }
            let head = headers.enumerated().map { index, title in
                aligned[index] ? "<th class=\"ar\">\(escape(String(title.dropFirst())))</th>" : "<th>\(escape(title))</th>"
            }.joined()
            let body = rows.map { row in
                "<tr>" + row.enumerated().map { index, cell in
                    index < aligned.count && aligned[index] ? "<td class=\"ar\">\(cell)</td>" : "<td>\(cell)</td>"
                }.joined() + "</tr>"
            }.joined()
            return "<table><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table>"
        }

        // MARK: Header and hero

        var header: String {
            let header = data.header
            let note = [header.builtNote, header.coverageNote]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            var flags: [String] = []
            if header.isPartial { flags.append("<span class=\"pill warn\">Not finished · figures are partial</span>") }
            if header.pricesAreLive { flags.append("<span class=\"pill flat\">Gold and silver at live prices</span>") }
            let flagRow = flags.isEmpty ? "" : "<div class=\"chips\">\(flags.joined())</div>"
            return """
            <header class="top"><div class="lbl">\(escape(header.kicker))</div>\
            <h1>\(escape(header.title))</h1><p>\(escape(note))</p>\(flagRow)</header>
            """
        }

        var hero: String {
            let hero = data.hero
            return """
            <section class="card hero" id="networth"><div class="main">\
            <div class="lbl">\(isYear ? "Net worth at the year’s end" : "Total net worth")</div>\
            <div class="big">\(escape(hero.netWorthText))</div>\
            <div class="sub"><span class="pill \(toneClass(hero.delta))">\(escape(hero.deltaLine))</span>\
            <span>\(escape(hero.assetsText)) assets</span><span><span class="flat">−&nbsp;</span>\(escape(hero.owedText)) owed</span></div>\
            </div>\(sparkline)</section>
            """
        }

        /// The hero's small net-worth line, first month to last.
        var sparkline: String {
            let points = data.trend.points
            guard points.count >= 2, let first = points.first, let last = points.last else { return "" }
            let values = points.map(\.value)
            let low = values.min() ?? 0
            let high = values.max() ?? 0
            let span = high - low
            let step = 288.0 / Double(points.count - 1)
            let xy: [(Double, Double)] = values.enumerated().map { index, value in
                let y = span == 0 ? 47 : 80 - (value - low) / span * 66
                return (6 + Double(index) * step, y)
            }
            let polyline = xy.map { "\(coordinate($0.0)),\(coordinate($0.1))" }.joined(separator: " ")
            let firstLabel = first.period.year == last.period.year
                ? first.label
                : "\(first.label) ’\(String(format: "%02d", first.period.year % 100))"
            let what = isYear ? "Net worth through \(data.scope.year)" : "Net worth over the last \(points.count) months"
            let end = xy[xy.count - 1]
            return """
            <svg viewBox="0 0 300 110" width="300" height="110" role="img" \
            aria-label="\(escape("\(what), from \(first.valueText) to \(last.valueText)"))">\
            <line x1="0" y1="96" x2="300" y2="96" stroke="var(--grid)"/>\
            <polyline points="\(polyline)" fill="none" stroke="var(--s1)" stroke-width="2.4" stroke-linejoin="round" stroke-linecap="round"/>\
            <circle cx="\(coordinate(end.0))" cy="\(coordinate(end.1))" r="4.5" fill="var(--s1)" stroke="var(--surface)" stroke-width="2"/>\
            <text x="6" y="92" font-size="10.5" fill="var(--muted)">\(escape(firstLabel))</text>\
            <text x="294" y="92" font-size="10.5" fill="var(--muted)" text-anchor="end">\(escape(last.label))</text></svg>
            """
        }

        // MARK: Brief

        func brief(_ review: ReviewBlock) -> String {
            let label = isYear ? "The year in brief" : "The month in brief"
            let tryTitle = review.tryNextTitle ?? (isYear ? "Try in \(data.scope.year + 1)" : "Try in \(data.period.next.monthName)")
            func column(_ title: String, _ className: String, _ items: [String]) -> String {
                let items = items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                guard !items.isEmpty else { return "" }
                return "<div class=\"bc\"><div class=\"lbl \(className)\">\(escape(title))</div><ul>"
                    + items.map { "<li>\(escape($0))</li>" }.joined() + "</ul></div>"
            }
            let columns = column("Went well", "ww", review.wentWell)
                + column("To watch", "tw", review.watch)
                + column(tryTitle, "tt", review.tryNext)
            let headline = review.headline.trimmingCharacters(in: .whitespacesAndNewlines)
            let footnote = review.isModelWritten
                ? "Written on this device by Apple Intelligence from the figures in this report, and checked against them. It doesn’t give investment advice."
                : "Worked out on this device by the app’s own checks, from the figures in this report. It doesn’t give investment advice."
            return """
            <section class="card brief\(review.isModelWritten ? "" : " plain")" id="brief">\
            <div class="kick">\(review.isModelWritten ? FinanceReportHTML.sparkle : "")<span class="lbl">\(label)</span></div>\
            \(headline.isEmpty ? "" : "<p class=\"head\">\(escape(headline))</p>")\
            \(columns.isEmpty ? "" : "<div class=\"cols\">\(columns)</div>")\
            <div class="foot">\(footnote)</div></section>
            """
        }

        // MARK: Key figures

        var figures: String {
            guard !data.kpis.isEmpty else { return "<div id=\"figures\"></div>" }
            let tiles = data.kpis.map { kpi in
                "<div class=\"kpi\"><div class=\"l\">\(escape(kpi.label))</div><div class=\"v\">\(escape(kpi.valueText))</div>"
                    + "<div class=\"s\">\(escape(kpi.detail))</div></div>"
            }.joined()
            return "<div class=\"grid kpis\" id=\"figures\" role=\"group\" aria-label=\"Key figures\">\(tiles)</div>"
        }

        // MARK: Footer

        var footer: String {
            let device = data.header.deviceName.trimmingCharacters(in: .whitespaces)
            let checked = review?.isModelWritten == true ? " Figures in the brief were checked against the tables above." : ""
            return """
            <footer>Built by Multitrack on \(escape(device.isEmpty ? "this device" : device)) from the household’s own figures. \
            No data left it to make this page, and the page makes no network requests.<br>\
            Charts are inline SVG and CSS.\(checked)</footer>
            """
        }
    }
}

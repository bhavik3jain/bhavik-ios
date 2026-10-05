import Core
import CoreData
import Observation
import SwiftUI
import UniformTypeIdentifiers

// What the report viewer, the Mac report window and the finish screen share:
// which scope and whose figures a report can step to, the page itself with
// its review, the files it's shared and saved as, and how a report is put on
// screen on each layout. The rules live in value types and in
// `ReportSession`, so the views stay declarative (views are untested by
// policy).

// MARK: - Stepping between reports

/// Which reports the ‹ › stepper and the Month / Year switch can reach, from
/// the months the household has.
struct ReportScopeNavigator: Equatable {
    /// One per period, oldest first.
    let periods: [YearMonth]
    /// Where a report opens with nothing else asked:
    /// `FinanceHome.reportedMonth` of the latest month.
    let defaultMonth: YearMonth?

    init(periods: [YearMonth], defaultMonth: YearMonth?) {
        self.periods = periods.sorted()
        self.defaultMonth = defaultMonth
    }

    @MainActor
    init(snapshot: FinanceSnapshot) {
        self.init(periods: snapshot.months.compactMap(\.period), defaultMonth: snapshot.reportedMonth?.period)
    }

    /// Every year with a month in it, oldest first.
    var years: [Int] { Array(Set(periods.map(\.year))).sorted() }

    var defaultScope: ReportScope? { (defaultMonth ?? periods.last).map(ReportScope.month) }

    func has(_ scope: ReportScope) -> Bool {
        switch scope {
        case .month(let period): periods.contains(period)
        case .year(let year): periods.contains { $0.year == year }
        }
    }

    /// What to show when `requested` is asked for: itself when there's a
    /// report for it, otherwise the default — a month deleted while its
    /// report was open, or a window restored after its month went.
    func resolved(_ requested: ReportScope?) -> ReportScope? {
        if let requested, has(requested) { return requested }
        return defaultScope
    }

    /// The nearest earlier report of the same kind; nil at the first. A gap
    /// in the months is stepped over rather than landing on nothing.
    func previous(of scope: ReportScope) -> ReportScope? {
        switch scope {
        case .month(let period): periods.last { $0 < period }.map(ReportScope.month)
        case .year(let year): years.last { $0 < year }.map(ReportScope.year)
        }
    }

    /// The nearest later report of the same kind; nil at the last.
    func next(of scope: ReportScope) -> ReportScope? {
        switch scope {
        case .month(let period): periods.first { $0 > period }.map(ReportScope.month)
        case .year(let year): years.first { $0 > year }.map(ReportScope.year)
        }
    }

    /// The Month / Year switch: a month's year in review, or a year's month —
    /// the default month when it's in that year, else the year's last month.
    func switching(_ scope: ReportScope, toYear: Bool) -> ReportScope {
        switch (scope, toYear) {
        case (.month(let period), true):
            return .year(period.year)
        case (.year(let year), false):
            if let defaultMonth, defaultMonth.year == year { return .month(defaultMonth) }
            return periods.last { $0.year == year }.map(ReportScope.month) ?? scope
        default:
            return scope
        }
    }
}

// MARK: - Whose figures

/// Whose figures a report shows, as picked in the viewer's "Whose" menu.
enum ReportOwnerChoice: Hashable, Sendable {
    /// Settings' "Whose by default" (`FinanceReportPreferences.defaultOwnerName`).
    case preferred
    case everyone
    case named(String)

    init(_ filter: OwnerFilter?) {
        switch filter {
        case nil: self = .preferred
        case .all?: self = .everyone
        case .owner(let owner)?: self = .named(owner.name)
        }
    }

    init(ownerName: String?) {
        self = ownerName.map(ReportOwnerChoice.named) ?? .everyone
    }

    /// The owner's name to filter by, nil for Everyone. A name no owner has
    /// (renamed, removed, or a preference from before) reads as Everyone
    /// rather than an empty report.
    func ownerName(preferred: String?, available: [String]) -> String? {
        let name: String? = switch self {
        case .preferred: preferred
        case .everyone: nil
        case .named(let name): name
        }
        guard let name, available.contains(name) else { return nil }
        return name
    }

    /// The filter for `ownerName(preferred:available:)` among `owners`.
    @MainActor
    func filter(preferred: String?, owners: [SharedFinanceOwner]) -> OwnerFilter {
        let name = ownerName(preferred: preferred, available: owners.map(\.name))
        return name.flatMap { name in owners.first { $0.name == name } }.map(OwnerFilter.owner) ?? .all
    }
}

// MARK: - Names

enum ReportNaming {
    /// "September 2026 Report", "2026 Year in Review", with "(Saloni)" when
    /// it's one person's figures — the file a share or PDF is saved as, and
    /// the print job.
    static func documentName(for scope: ReportScope, ownerName: String?) -> String {
        let base = switch scope {
        case .month(let period): "\(period.title) Report"
        case .year(let year): "\(year) Year in Review"
        }
        guard let ownerName, !ownerName.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        return "\(base) (\(ownerName))"
    }

    /// "this iPhone" / "this Mac" for the page's "Built on …" line. Finance
    /// asks how it's shown rather than where it runs (no `#if os` in a
    /// feature package), and the device's own name needs an entitlement on
    /// iOS that the app doesn't have.
    static func deviceName(for layout: ModuleLayout) -> String {
        layout == .sidebar ? "this Mac" : "this iPhone"
    }

    /// "September report" — the finish screen's card.
    static func shortTitle(for scope: ReportScope) -> String {
        switch scope {
        case .month(let period): "\(period.monthName) report"
        case .year(let year): "\(year) in review"
        }
    }
}

// MARK: - The page

/// What a report is built from, all but the gold and silver prices — so the
/// same report can be built again at the prices an earlier review of it was
/// written at, which is how a price tick is told from new figures
/// (`ReportReviewRenewal`).
@MainActor
struct ReportRecipe {
    let scope: ReportScope
    let household: SharedFinanceHousehold
    let filter: OwnerFilter
    let deviceName: String
    /// Fixed by a screen for as long as it's open: a report "built" anew at
    /// every redraw would never compare equal to the last one.
    let builtAt: Date

    func build(live: MetalPrices?) -> FinanceReportData? {
        FinanceReportData.build(scope: scope, household: household, filter: filter, live: live, deviceName: deviceName, asOf: builtAt)
    }

    /// What the model would be shown of this report with its open month
    /// valued at `prices` — nil: at its own saved ones.
    func brief(at prices: MetalPrices?) -> ReportBrief? {
        build(live: prices).map { ReportBrief(data: $0) }
    }

    /// For `ReportReviewModel.update(_:repricing:)`.
    var repricing: ReportReviewModel.Repricing {
        { prices in brief(at: prices) }
    }
}

/// One report on screen: its figures, its review, and the page built from
/// both. Views hand it a freshly built `FinanceReportData` whenever the store
/// changes (`show(_:recipe:)`), start the review from a `.task`, and read `html`.
///
/// Observable per property, so the view that builds the figures doesn't read
/// the review: each streamed word re-renders only the page, never rebuilds
/// the report from the store.
@MainActor
@Observable
final class ReportSession {
    private(set) var data: FinanceReportData?
    private(set) var model: ReportReviewModel?
    /// Set to a section id to scroll the page to it (`HTMLDocumentView`).
    var scrollTarget: String?
    /// The page as an `.html` file, for `ShareLink`; nil until written.
    private(set) var shareFile: URL?

    @ObservationIgnored private var rendered: (key: PageKey, html: String)?
    @ObservationIgnored private var writtenFileKey: Int?

    private struct PageKey: Equatable {
        let data: FinanceReportData
        let review: ReportReview?
        let options: FinanceReportHTML.Options
    }

    init() {}

    /// The report to show, or nil when there's none; `recipe` is what it was
    /// built from.
    ///
    /// The review model is kept when the new figures tell it the same facts
    /// (`ReportBrief.fingerprint`): a partner's synced edit to an unrelated
    /// account rebuilt the report, and with it a model that started writing
    /// the whole review again. It's kept through a gold or silver price tick
    /// too, and given the new report either way — see `ReportReviewRenewal`.
    /// A new one comes from `ReportReviewModel.shared(for:)`, so a review the
    /// Summary is already writing is the one the page waits for.
    func show(_ data: FinanceReportData?, recipe: ReportRecipe? = nil) {
        guard data != self.data else { return }
        self.data = data
        guard let data else {
            model = nil
            return
        }
        let renewal = ReportReviewRenewal.decide(
            current: model?.basis,
            next: ReportReviewBasis(data: data, brief: ReportBrief(data: data)),
            fingerprintAtPrices: { prices in recipe?.brief(at: prices)?.fingerprint }
        )
        if renewal != .replace, let model {
            model.update(data, repricing: recipe?.repricing)
        } else {
            let shared = ReportReviewModel.shared(for: data)
            shared.update(data, repricing: recipe?.repricing)
            model = shared
        }
    }

    /// Starts (or picks up from the cache) the review. Call from a `.task`
    /// whose id includes `modelID`, so a new report's model starts and the
    /// old one's stream is cancelled with the task.
    func startReview(advisor: any FinanceAdvising, enabled: Bool) async {
        await model?.start(advisor: advisor, enabled: enabled)
    }

    /// Changes whenever there's a new review model to start.
    var modelID: ObjectIdentifier? { model.map(ObjectIdentifier.init) }

    /// The review the page carries: the model's once it's finished and
    /// checked, the check's own plain wording until then. The page is never
    /// held back for the model, and isn't reloaded for every streamed word —
    /// only once, when the finished review arrives.
    func pageReview(includeReview: Bool) -> ReportReview? {
        guard includeReview, let model else { return nil }
        switch model.state {
        case .ready(let review), .plain(let review): return review
        case .idle, .writing: return model.plainReview
        }
    }

    /// The page, rendered once per change of figures, review or options.
    func html(options: FinanceReportHTML.Options) -> String? {
        guard let data else { return nil }
        let key = PageKey(data: data, review: pageReview(includeReview: options.includeReview), options: options)
        if let rendered, rendered.key == key { return rendered.html }
        let html = FinanceReportHTML.render(data, review: key.review, options: options)
        rendered = (key, html)
        return html
    }

    /// The page's sections for "Jump to Section" and the Mac's contents.
    func sections(options: FinanceReportHTML.Options) -> [FinanceReportData.ReportSection] {
        guard let data else { return [] }
        return FinanceReportHTML.sections(for: data, review: pageReview(includeReview: options.includeReview), options: options)
    }

    /// Writes `html` as "<name>.html" for the Share button. Call from a
    /// `.task(id: html)`; a page already written isn't written again.
    func prepareShareFile(html: String, name: String) {
        var hasher = Hasher()
        hasher.combine(html)
        hasher.combine(name)
        let key = hasher.finalize()
        guard key != writtenFileKey else { return }
        writtenFileKey = key
        shareFile = try? HTMLDocumentExport.writeTemporaryFile(named: name + ".html", contents: html)
    }
}

// MARK: - Saving a PDF

/// The PDF "Save as PDF" hands to `fileExporter` — the Files picker on the
/// phone, a save panel on the Mac.
struct ReportPDFDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Save as PDF and Print, with the state their buttons and alert need.
@MainActor
@Observable
final class ReportExporter {
    private(set) var isWorking = false
    var pdf: ReportPDFDocument?
    var isSavingPDF = false
    var failure: String?

    init() {}

    /// Makes the PDF, then shows the save panel.
    func savePDF(html: String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            pdf = ReportPDFDocument(data: try await HTMLDocumentExport.pdf(html: html))
            isSavingPDF = true
        } catch {
            failure = "The PDF couldn't be made. Try again in a moment."
        }
    }

    func print(html: String, jobName: String) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await HTMLDocumentExport.print(html: html, jobName: jobName)
        } catch {
            failure = "The report couldn't be printed. Try again in a moment."
        }
    }
}

extension View {
    /// The save panel and the failure alert for `exporter`.
    func reportExports(_ exporter: ReportExporter, fileName: String) -> some View {
        modifier(ReportExportsModifier(exporter: exporter, fileName: fileName))
    }
}

private struct ReportExportsModifier: ViewModifier {
    @Bindable var exporter: ReportExporter
    let fileName: String

    func body(content: Content) -> some View {
        content
            .fileExporter(
                isPresented: $exporter.isSavingPDF,
                document: exporter.pdf,
                contentType: .pdf,
                defaultFilename: fileName
            ) { _ in
                exporter.pdf = nil
            }
            .alert(
                "Something Went Wrong",
                isPresented: Binding(get: { exporter.failure != nil }, set: { if !$0 { exporter.failure = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exporter.failure ?? "")
            }
    }
}

// MARK: - Putting a report on screen

extension View {
    /// Shows `request`'s report the way this layout wants it: the report
    /// viewer over everything on the phone, its own window on the Mac (opened
    /// with the request as the window's value, so asking for a report that's
    /// already open brings its window forward). Clears `request` once shown.
    ///
    /// For the Months tab, the finish screen and anywhere else a "View Report"
    /// lives: callers set `FinanceReportWindowValue(scope:ownerName:)` with
    /// the owner from `\.financeReportPreferences.defaultOwnerName`.
    func presentsReport(_ request: Binding<FinanceReportWindowValue?>) -> some View {
        modifier(ReportPresentation(request: request))
    }
}

private struct ReportPresentation: ViewModifier {
    @Binding var request: FinanceReportWindowValue?
    @Environment(\.moduleLayout) private var layout
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, value in
                guard layout == .sidebar, let value else { return }
                openWindow(id: FinanceTrackerModule.reportWindowID, value: value)
                request = nil
            }
            // A cover, like the module itself: the viewer brings its own Done.
            // (On the Mac, MacCompat makes this a sheet, but the Mac never
            // gets here — it opens a window above.)
            .fullScreenCover(item: layout == .sidebar ? .constant(nil) : $request) { value in
                ReportViewerView(scope: value.scope, ownerName: value.ownerName)
            }
    }
}

// MARK: - Glass

extension View {
    /// Liquid Glass behind a floating control where the system has it, a
    /// material capsule before iOS 26 / macOS 26.
    @ViewBuilder
    func reportGlassCapsule() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .capsule)
        } else {
            background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.10), radius: 11, y: 6)
        }
    }
}

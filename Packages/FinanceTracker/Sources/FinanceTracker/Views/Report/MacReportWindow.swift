import Core // Only reached on macOS, from FinanceTrackerModule.reportWindow — keep for the Mac build.
import CoreData
import SwiftUI

/// The Mac's report window (Report, ⇧⌘R — ⌘R is already View ▸ Refresh from
/// iCloud, and the menu command takes the key first): a contents sidebar that
/// scrolls the page to a section, the web report, and an inspector with the
/// review and "Ask about <month>". The toolbar steps months, picks whose
/// figures, shows or hides the review, shares and prints; its More menu
/// saves a PDF and writes the review again.
///
/// A scene of its own, opened with `openWindow(id:value:)`. The window's
/// `FinanceReportWindowValue` is updated as it steps, so it stays on the
/// report it was stepped to while it's open; window restoration is disabled
/// on the scene (see BhavikApp), so a nil value only comes from File ▸ New
/// Report Window, and opens the month the Summary headlines.
struct MacReportWindow: View {
    @Binding var value: FinanceReportWindowValue?

    @Environment(\.financeAdvisor) private var advisor
    @Environment(\.financeAdvisorEnabled) private var advisorEnabled
    @Environment(\.financeReportPreferences) private var preferences
    var data = FinanceFetches()

    @State private var session = ReportSession()
    @State private var builtAt = Date.now
    @State private var showsReview = true
    @State private var includeReview = true
    @State private var tablesChoice: Bool?
    @State private var exporter = ReportExporter()

    private var options: FinanceReportHTML.Options {
        FinanceReportHTML.Options(includeTables: tablesChoice ?? preferences.includeTables, includeReview: includeReview)
    }

    var body: some View {
        let snapshot = data.snapshot
        let navigator = ReportScopeNavigator(snapshot: snapshot)
        let shown = navigator.resolved(value?.scope)
        let owners = snapshot.owners.map(\.name)
        let choice = ReportOwnerChoice(ownerName: value?.ownerName)
        let ownerName = choice.ownerName(preferred: nil, available: owners)
        let filter = choice.filter(preferred: nil, owners: snapshot.owners)
        let recipe: ReportRecipe? = shown.flatMap { shown in
            snapshot.household.map { household in
                ReportRecipe(scope: shown, household: household, filter: filter, deviceName: ReportNaming.deviceName(for: .sidebar), builtAt: builtAt)
            }
        }
        let report = recipe?.build(live: snapshot.live)
        let scope = shown ?? value?.scope
        let documentName = scope.map { ReportNaming.documentName(for: $0, ownerName: ownerName) } ?? "Report"

        NavigationSplitView {
            MacReportContents(session: session, options: options)
                .navigationSplitViewColumnWidth(min: 170, ideal: 216, max: 300)
        } detail: {
            MacReportPage(session: session, options: options, documentName: documentName, isWorking: exporter.isWorking)
        }
        .inspector(isPresented: $showsReview) {
            MacReportInspector(session: session)
                .inspectorColumnWidth(min: 280, ideal: 330, max: 440)
        }
        .navigationTitle(scope.map { "\($0.title) Report" } ?? "Report")
        .moduleSubtitle("Finance · \(ownerName ?? "Everyone")")
        .toolbar {
            if let scope {
                ToolbarItem(placement: .principal) {
                    ReportScopeStepper(
                        scope: Binding(get: { scope }, set: { step(to: $0, ownerName: ownerName) }),
                        navigator: navigator
                    )
                    .padding(.horizontal, 4)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if !owners.isEmpty {
                    Picker(selection: Binding(get: { ownerName }, set: { name in
                        if let scope { value = FinanceReportWindowValue(scope: scope, ownerName: name) }
                    })) {
                        Text("Everyone").tag(String?.none)
                        ForEach(owners, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    } label: {
                        Label("Whose", systemImage: "person.2")
                    }
                    .pickerStyle(.menu)
                    .help("Whose figures the report shows")
                }

                Toggle(isOn: $showsReview) {
                    Label(showsReview ? "Hide Review" : "Show Review", systemImage: "sparkles")
                }
                .help(showsReview ? "Hide the review" : "Show the review")

                if let file = session.shareFile {
                    ShareLink(item: file, preview: SharePreview(documentName)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .help("Share the report as a web page")
                }

                Button("Print", systemImage: "printer") {
                    guard let html = session.html(options: options) else { return }
                    Task { await exporter.print(html: html, jobName: documentName) }
                }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(session.data == nil || exporter.isWorking)
                .help("Print the report")

                Menu {
                    Button("Save as PDF…", systemImage: "doc") {
                        guard let html = session.html(options: options) else { return }
                        Task { await exporter.savePDF(html: html) }
                    }
                    .disabled(session.data == nil || exporter.isWorking)
                    Divider()
                    Toggle("Include Review in the Page", isOn: $includeReview)
                    Toggle("Include Table Views", isOn: Binding(get: { options.includeTables }, set: { tablesChoice = $0 }))
                    // The window has no menu bar commands of its own to put
                    // this in; the inspector has the same as a button.
                    if includeReview || showsReview {
                        WriteReviewAgainSection(model: session.model)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("Save as PDF, what the page includes, and writing the review again")
            }
        }
        .onChange(of: report, initial: true) { _, report in
            session.show(report, recipe: recipe)
        }
        // The review is written for the page and the inspector alike, once.
        .task(id: ReviewStart(model: session.modelID, isWanted: includeReview || showsReview, enabled: advisorEnabled)) {
            guard includeReview || showsReview else { return }
            await session.startReview(advisor: advisor, enabled: advisorEnabled)
        }
        .reportExports(exporter, fileName: documentName)
        .frame(minWidth: 760, minHeight: 520)
    }

    private func step(to scope: ReportScope, ownerName: String?) {
        value = FinanceReportWindowValue(scope: scope, ownerName: ownerName)
    }
}

/// The sidebar's "Contents": a row per section of the page, numbered like
/// the page's own headings; choosing one scrolls the page to it.
private struct MacReportContents: View {
    let session: ReportSession
    let options: FinanceReportHTML.Options

    @State private var selection: String?

    var body: some View {
        let sections = session.sections(options: options)
        List(selection: $selection) {
            Section("Contents") {
                ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                    HStack(spacing: 8) {
                        Text(String(format: "%02d", index + 1))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .leading)
                        Text(section.title)
                            .lineLimit(1)
                    }
                    .tag(section.id)
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, id in
            guard let id else { return }
            session.scrollTarget = id
        }
    }
}

/// The web report, or why there isn't one.
private struct MacReportPage: View {
    let session: ReportSession
    let options: FinanceReportHTML.Options
    let documentName: String
    let isWorking: Bool

    var body: some View {
        let html = session.html(options: options)
        Group {
            if let html {
                HTMLDocumentView(html: html, scrollTarget: Binding(get: { session.scrollTarget }, set: { session.scrollTarget = $0 }))
                    .overlay {
                        if isWorking {
                            ProgressView()
                                .controlSize(.large)
                                .padding(24)
                                .background(.regularMaterial, in: .rect(cornerRadius: 16))
                        }
                    }
            } else {
                ContentUnavailableView {
                    Label("No Report Yet", systemImage: "doc.text")
                } description: {
                    Text("A report is made from a month's balances. Start a month under Months to see one.")
                }
            }
        }
        .task(id: html) {
            guard let html else { return }
            session.prepareShareFile(html: html, name: documentName)
        }
    }
}

/// The inspector: the review, with its one-tap fixes, and "Ask about
/// <month>" under it (`ReviewPanel`). It's given the window's own model, so
/// the page's "in brief" and the inspector are one review, written once.
private struct MacReportInspector: View {
    let session: ReportSession

    var body: some View {
        if let model = session.model {
            ReviewPanel(model: model)
        } else {
            Color.clear
        }
    }
}

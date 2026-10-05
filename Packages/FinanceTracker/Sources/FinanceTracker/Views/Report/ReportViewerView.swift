import Core
import CoreData
import SwiftUI

/// The phone's report viewer: the generated web page full screen, Done on
/// the left, the month's name in the middle, Share and a ••• menu on the
/// right (Share Web Page, Save as PDF, Print, Whose, Month or Year, Include
/// Review, Include Table Views, Jump to Section, Write Review Again), and a
/// ‹ month › stepper floating at the bottom.
///
/// The page is built here from the store — never held back for Apple
/// Intelligence: it shows with the month check's own wording and is redrawn
/// once when the model's review is finished (`ReportSession`). The Mac opens
/// `MacReportWindow` instead; `presentsReport(_:)` picks.
struct ReportViewerView: View {
    @Environment(\.moduleLayout) private var layout
    @Environment(\.financeReportPreferences) private var preferences
    var data = FinanceFetches()

    @State private var scope: ReportScope
    @State private var ownerChoice: ReportOwnerChoice
    @State private var session = ReportSession()
    /// Fixed for as long as the viewer is open: a report "built" anew at
    /// every redraw would never compare equal to the last one, and every
    /// redraw would rebuild the page.
    @State private var builtAt = Date.now

    /// - Parameters:
    ///   - scope: the month or year to open on.
    ///   - filter: whose figures; nil takes Settings' "Whose by default".
    init(scope: ReportScope, filter: OwnerFilter? = nil) {
        _scope = State(initialValue: scope)
        _ownerChoice = State(initialValue: ReportOwnerChoice(filter))
    }

    /// For a `FinanceReportWindowValue`: nil is Everyone.
    init(scope: ReportScope, ownerName: String?) {
        _scope = State(initialValue: scope)
        _ownerChoice = State(initialValue: ReportOwnerChoice(ownerName: ownerName))
    }

    var body: some View {
        let snapshot = data.snapshot
        let navigator = ReportScopeNavigator(snapshot: snapshot)
        let shown = navigator.resolved(scope)
        let ownerName = ownerChoice.ownerName(preferred: preferences.defaultOwnerName, available: snapshot.owners.map(\.name))
        let filter = ownerChoice.filter(preferred: preferences.defaultOwnerName, owners: snapshot.owners)
        let recipe: ReportRecipe? = shown.flatMap { shown in
            snapshot.household.map { household in
                ReportRecipe(scope: shown, household: household, filter: filter, deviceName: ReportNaming.deviceName(for: layout), builtAt: builtAt)
            }
        }
        let report = recipe?.build(live: snapshot.live)
        NavigationStack {
            ReportViewerPage(
                session: session,
                scope: Binding(get: { shown ?? scope }, set: { scope = $0 }),
                navigator: navigator,
                ownerChoice: $ownerChoice,
                ownerName: ownerName,
                owners: snapshot.owners.map(\.name)
            )
        }
        .onChange(of: report, initial: true) { _, report in
            session.show(report, recipe: recipe)
        }
    }
}

/// The page and its chrome. Its own view so the review streaming in redraws
/// only this, never the report being rebuilt from the store above.
private struct ReportViewerPage: View {
    let session: ReportSession
    @Binding var scope: ReportScope
    let navigator: ReportScopeNavigator
    @Binding var ownerChoice: ReportOwnerChoice
    let ownerName: String?
    let owners: [String]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.financeAdvisor) private var advisor
    @Environment(\.financeAdvisorEnabled) private var advisorEnabled
    @Environment(\.financeReportPreferences) private var preferences

    @State private var includeReview = true
    /// nil until changed here: Settings' "Table views in shared reports".
    @State private var tablesChoice: Bool?
    @State private var exporter = ReportExporter()

    private var options: FinanceReportHTML.Options {
        FinanceReportHTML.Options(includeTables: tablesChoice ?? preferences.includeTables, includeReview: includeReview)
    }

    private var documentName: String { ReportNaming.documentName(for: scope, ownerName: ownerName) }

    var body: some View {
        let options = options
        let html = session.html(options: options)
        content(html: html)
            .navigationTitle(scope.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Done")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(scope.title)
                            .font(.headline)
                        // The page keeps the check's words until the review
                        // is done, so this is the one sign a review is being
                        // written — on opening, or after Write Review Again.
                        Text(includeReview && session.model?.isWriting == true
                            ? "Writing the review…"
                            : ownerName.map { "Report · \($0)" } ?? "Report")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if let file = session.shareFile {
                        ShareLink(item: file, preview: SharePreview(documentName)) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share Report")
                    }
                    menu(html: html, options: options)
                }
                // `.status` is the bottom bar's middle on the phone — the
                // floating stepper — and exists on both platforms, where
                // `.bottomBar` would break the Mac build.
                ToolbarItem(placement: .status) {
                    ReportScopeStepper(scope: $scope, navigator: navigator)
                }
            }
            .task(id: html) {
                guard let html else { return }
                session.prepareShareFile(html: html, name: documentName)
            }
            .task(id: ReviewStart(model: session.modelID, isWanted: includeReview, enabled: advisorEnabled)) {
                guard includeReview else { return }
                await session.startReview(advisor: advisor, enabled: advisorEnabled)
            }
            .reportExports(exporter, fileName: documentName)
    }

    @ViewBuilder
    private func content(html: String?) -> some View {
        if let html {
            // Under the bars, so the page scrolls beneath them: WebKit insets
            // its own content by the bars' safe area.
            HTMLDocumentView(html: html, scrollTarget: Binding(get: { session.scrollTarget }, set: { session.scrollTarget = $0 }))
                .ignoresSafeArea(.container, edges: .vertical)
                .overlay {
                    if exporter.isWorking {
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

    private func menu(html: String?, options: FinanceReportHTML.Options) -> some View {
        Menu {
            Section {
                if let file = session.shareFile {
                    ShareLink(item: file, preview: SharePreview(documentName)) {
                        Label("Share Web Page", systemImage: "square.and.arrow.up")
                    }
                }
                Button("Save as PDF", systemImage: "doc") {
                    guard let html else { return }
                    Task { await exporter.savePDF(html: html) }
                }
                Button("Print", systemImage: "printer") {
                    guard let html else { return }
                    Task { await exporter.print(html: html, jobName: documentName) }
                }
            }
            .disabled(html == nil || exporter.isWorking)

            if !owners.isEmpty {
                Section("Whose") {
                    Picker("Whose", selection: Binding(get: { ownerName }, set: { ownerChoice = ReportOwnerChoice(ownerName: $0) })) {
                        Text("Everyone").tag(String?.none)
                        ForEach(owners, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }

            Section {
                ReportScopeKindPicker(scope: $scope, navigator: navigator)
            }

            Section {
                Toggle(isOn: $includeReview) {
                    Label("Include Review", systemImage: "sparkles")
                }
                Toggle(isOn: Binding(get: { options.includeTables }, set: { tablesChoice = $0 })) {
                    Label("Include Table Views", systemImage: "tablecells")
                }
                Menu {
                    ForEach(session.sections(options: options)) { section in
                        Button(section.title) { session.scrollTarget = section.id }
                    }
                } label: {
                    Label("Jump to Section", systemImage: "list.bullet")
                }
            }

            // Only while the page carries the review: written with it left
            // out, the new one would show nowhere.
            if includeReview {
                WriteReviewAgainSection(model: session.model)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("More")
    }
}

/// What a review `.task` restarts on: a new report's model, Include Review
/// turned on, or the Apple Intelligence switch.
struct ReviewStart: Hashable {
    let model: ObjectIdentifier?
    let isWanted: Bool
    let enabled: Bool
}

/// ‹ September 2026 › — the previous and next report of the same kind. The
/// name in the middle switches between the month and its year in review.
struct ReportScopeStepper: View {
    @Binding var scope: ReportScope
    let navigator: ReportScopeNavigator

    var body: some View {
        let previous = navigator.previous(of: scope)
        let next = navigator.next(of: scope)
        HStack(spacing: 2) {
            Button {
                if let previous { scope = previous }
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .disabled(previous == nil)
            .accessibilityLabel(previous.map { "Previous, \($0.title)" } ?? "Previous")
            .keyboardShortcut("[", modifiers: .command)

            Menu {
                ReportScopeKindPicker(scope: $scope, navigator: navigator)
            } label: {
                Text(scope.title)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 6)
            }
            .menuIndicator(.hidden)
            .fixedSize()

            Button {
                if let next { scope = next }
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .disabled(next == nil)
            .accessibilityLabel(next.map { "Next, \($0.title)" } ?? "Next")
            .keyboardShortcut("]", modifiers: .command)
        }
        .buttonStyle(.borderless)
    }
}

/// Month or Year in Review, for the scope's own month or year.
struct ReportScopeKindPicker: View {
    @Binding var scope: ReportScope
    let navigator: ReportScopeNavigator

    var body: some View {
        let month = navigator.switching(scope, toYear: false)
        let year = navigator.switching(scope, toYear: true)
        Picker("Show", selection: Binding(get: { scope.isYear }, set: { scope = $0 ? year : month })) {
            Label(month.month?.monthName ?? "Month", systemImage: "calendar").tag(false)
            Label("\(String(year.year)) in Review", systemImage: "calendar.badge.clock").tag(true)
        }
        .pickerStyle(.inline)
    }
}

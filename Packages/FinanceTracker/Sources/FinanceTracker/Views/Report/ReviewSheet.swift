import Core
import CoreData
import SwiftUI

// MARK: - Keeping a review model current

/// Everything a report reads, hashed: when it changes, the report is built
/// again. Building one runs the whole check over every month and
/// transaction, which is far too much for every redraw of the Summary — and
/// a balance edit doesn't change any count `FinanceSnapshot.revision` reads,
/// so the counts alone left the card on the old figures.
struct ReportInputs: Hashable {
    let scope: ReportScope?
    let filterID: String
    let availability: FinanceAdvisorAvailability
    let pulse: Int

    @MainActor
    init(scope: ReportScope?, filter: OwnerFilter, snapshot: FinanceSnapshot, availability: FinanceAdvisorAvailability) {
        self.scope = scope
        switch filter {
        case .all: filterID = "all"
        case .owner(let owner): filterID = owner.objectID.uriRepresentation().absoluteString
        }
        self.availability = availability
        var hasher = Hasher()
        hasher.combine(snapshot.household?.objectID)
        for month in snapshot.months {
            hasher.combine(month.yearMonth)
            hasher.combine(month.closedAt)
            hasher.combine(month.goldPricePerOz)
            hasher.combine(month.silverPricePerOz)
            for balance in month.balances ?? [] {
                hasher.combine(balance.account?.objectID)
                hasher.combine(balance.amount)
            }
            for budget in month.budgets ?? [] {
                hasher.combine(budget.category)
                hasher.combine(budget.limit)
            }
        }
        for transaction in snapshot.transactions {
            hasher.combine(transaction.date)
            hasher.combine(transaction.actualCost)
            hasher.combine(transaction.category)
            hasher.combine(transaction.merchant)
            hasher.combine(transaction.card?.objectID)
        }
        for account in snapshot.accounts {
            hasher.combine(account.name)
            hasher.combine(account.institution)
            hasher.combine(account.categoryRaw)
            hasher.combine(account.limit)
            hasher.combine(account.owner?.objectID)
        }
        for metal in snapshot.metals {
            hasher.combine(metal.name)
            hasher.combine(metal.grams)
            hasher.combine(metal.location)
            hasher.combine(metal.manualValue)
            hasher.combine(metal.hasManualValue)
            hasher.combine(metal.purchaseValue)
            hasher.combine(metal.owner?.objectID)
        }
        for owner in snapshot.owners {
            hasher.combine(owner.name)
        }
        // Live prices value the open month, so a fresh quote is new figures.
        hasher.combine(snapshot.live?.gold)
        hasher.combine(snapshot.live?.silver)
        pulse = hasher.finalize()
    }
}

extension View {
    /// Keeps `model` on the report for `scope` and `filter`, and its review
    /// started: rebuilt when the figures, whose they are, or the advisor's
    /// availability change; kept — so a finished review isn't written again —
    /// when the check found the same things. Cancelling (the view going away)
    /// stops the model mid-review.
    func keepsReportReview(
        _ model: Binding<ReportReviewModel?>,
        scope: ReportScope?,
        filter: OwnerFilter,
        snapshot: FinanceSnapshot
    ) -> some View {
        modifier(ReportReviewKeeper(model: model, scope: scope, filter: filter, snapshot: snapshot))
    }
}

private struct ReportReviewKeeper: ViewModifier {
    @Binding var model: ReportReviewModel?
    let scope: ReportScope?
    let filter: OwnerFilter
    let snapshot: FinanceSnapshot

    @Environment(\.financeAdvisor) private var advisor
    @Environment(\.financeAdvisorEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let availability = advisor.availability(isEnabled: isEnabled)
        content.task(id: ReportInputs(scope: scope, filter: filter, snapshot: snapshot, availability: availability)) {
            guard let scope, let household = snapshot.household,
                  let data = FinanceReportData.build(scope: scope, household: household, filter: filter, live: snapshot.live, deviceName: "")
            else {
                model = nil
                return
            }
            // `data` itself never compares equal twice — its header carries
            // when it was built — so the findings decide whether anything the
            // review says has changed.
            let current: ReportReviewModel
            if let model, model.scope == data.scope, model.data.findings == data.findings,
               model.state == .idle || model.availability == availability {
                current = model
            } else {
                current = ReportReviewModel(data: data)
                model = current
            }
            await current.start(advisor: advisor, enabled: isEnabled)
        }
    }
}

/// Builds and keeps the review for a scope on its own, for a sheet opened
/// without a model in hand — today only `-FinanceOpenReview YES`'s debug
/// sheet. The Summary card, the finish screen and the Mac inspector all pass
/// the model they already hold, so the review isn't written twice.
private struct ReportReviewHost<Content: View>: View {
    let scope: ReportScope
    let filter: OwnerFilter
    @ViewBuilder let content: (ReportReviewModel) -> Content

    var data = FinanceFetches()
    @State private var model: ReportReviewModel?

    var body: some View {
        Group {
            if let model {
                content(model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .keepsReportReview($model, scope: scope, filter: filter, snapshot: data.snapshot)
    }
}

// MARK: - Shared pieces

/// The review's purple: the sparkle, "Try in…", "Writing…".
enum ReviewStyle {
    static let intelligence = Color(red: 0.43, green: 0.25, blue: 0.82)
    static let watch = Color.orange

    static func color(for group: ReportReview.Group) -> Color {
        switch group {
        case .wentWell: FinanceTrackerModule.accent.color
        case .watch: watch
        case .tryNext: intelligence
        }
    }

    static func symbol(for group: ReportReview.Group) -> String {
        switch group {
        case .wentWell: "checkmark.circle"
        case .watch: "exclamationmark.triangle"
        case .tryNext: "lightbulb"
        }
    }

    /// The sheet's title: "September Review" when the model is wording it,
    /// "September Check" when it's the check's own words.
    static func title(for scope: ReportScope, isPlain: Bool) -> String {
        "\(scope.shortTitle) \(isPlain ? "Check" : "Review")"
    }

    /// The line under it.
    static func subtitle(isPlain: Bool) -> String {
        isPlain ? "Worked out from your figures" : "Apple Intelligence · on this device"
    }

    /// The footer under every review: where it was written, and what it
    /// isn't.
    static func footer(isWrittenByModel: Bool) -> String {
        isWrittenByModel
            ? "Written on this device by Apple Intelligence from the app's own checks of your figures. Nothing leaves this device. Not investment advice."
            : "Worked out on this device from your figures. Not investment advice."
    }
}

/// What a screen shows of a review model, decided once so the sheet and the
/// Mac panel agree.
struct ReviewDisplay {
    let review: ReportReview
    let availability: FinanceAdvisorAvailability
    let isWriting: Bool
    /// Not the model's review: the check's own words, and its footnote.
    let isPlain: Bool

    @MainActor
    init(_ model: ReportReviewModel, availability: FinanceAdvisorAvailability) {
        self.availability = availability
        review = model.review
        isWriting = model.isWriting
        switch model.state {
        case .ready, .writing: isPlain = false
        case .plain: isPlain = true
        // Before the first start: the model's look only if it is about to
        // write, so a plain check doesn't flash "Review" first.
        case .idle: isPlain = availability != .available
        }
    }

    /// The headline to show, or nil while the model hasn't got one yet.
    var headline: String? {
        if isWriting, !review.isHeadlineWrittenByModel { return nil }
        return review.headline
    }

    /// Groups to show: those with items, and — while writing — every group,
    /// with placeholders where the model hasn't finished.
    var groups: [ReportReview.Group] {
        isWriting ? ReportReview.Group.allCases : review.groups
    }
}

/// One finding in the review: its group's mark, the words, and the fix.
struct ReviewItemRow: View {
    let item: ReportReview.Item
    var compact = false
    let open: (ReportFix) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: ReviewStyle.symbol(for: item.group))
                .foregroundStyle(ReviewStyle.color(for: item.group))
                .frame(width: compact ? 18 : 24)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.text)
                    .font(compact ? .callout : .body)
                    .fixedSize(horizontal: false, vertical: true)
                if let fix = item.fix {
                    // Borderless, so in a list row the fix is its own tap
                    // target rather than the whole row firing it.
                    Button {
                        open(fix)
                    } label: {
                        HStack(spacing: 3) {
                            Text(fix.title)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                        }
                        .font(compact ? .callout.weight(.semibold) : .subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderless)
                    .tint(FinanceTrackerModule.accent.color)
                }
            }
        }
        .padding(.vertical, compact ? 2 : 3)
    }
}

/// Grey bars where the model's words will be.
struct ReviewPlaceholderRow: View {
    var lines: [CGFloat] = [0.92, 0.6]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, width in
                GeometryReader { geometry in
                    Capsule()
                        .fill(.quaternary)
                        .frame(width: geometry.size.width * width, height: 10)
                }
                .frame(height: 10)
            }
        }
        .padding(.vertical, 6)
        .accessibilityLabel("Writing")
    }
}

/// "Writing from 14 figures…".
struct ReviewWritingLabel: View {
    let factCount: Int

    var body: some View {
        Label {
            Text("Writing from \(counted(factCount, "figure"))…")
        } icon: {
            Image(systemName: "sparkles")
        }
        .font(.footnote)
        .foregroundStyle(ReviewStyle.intelligence)
    }
}

// MARK: - The sheet

/// The review of one month (or year): its headline, then Went well, To watch
/// and Try in <next month>, each finding with its one-tap fix into the real
/// editor — streamed in as Apple Intelligence words it, or in the check's
/// own words when the model is off, can't run or got something wrong.
///
/// Opened from the Summary's "<Month> in brief" card and the finish screen
/// with their own model (so the review isn't written twice), and with just
/// the scope by `-FinanceOpenReview YES`.
struct ReviewSheet: View {
    private enum Source {
        case model(ReportReviewModel)
        case scope(ReportScope, OwnerFilter)
    }

    private let source: Source
    /// What "Open Full Report" does; nil opens it from here — over this
    /// sheet on the phone, in its window on the Mac.
    var onOpenReport: (() -> Void)?

    init(scope: ReportScope, filter: OwnerFilter, onOpenReport: (() -> Void)? = nil) {
        source = .scope(scope, filter)
        self.onOpenReport = onOpenReport
    }

    init(model: ReportReviewModel, onOpenReport: (() -> Void)? = nil) {
        source = .model(model)
        self.onOpenReport = onOpenReport
    }

    var body: some View {
        switch source {
        case .model(let model):
            ReviewSheetContent(model: model, filter: nil, onOpenReport: onOpenReport)
        case .scope(let scope, let filter):
            ReportReviewHost(scope: scope, filter: filter) { model in
                ReviewSheetContent(model: model, filter: filter, onOpenReport: onOpenReport)
            }
        }
    }
}

private struct ReviewSheetContent: View {
    let model: ReportReviewModel
    /// Whose figures, for the report "Open Full Report" opens; nil reads it
    /// back off the report's own header.
    let filter: OwnerFilter?
    let onOpenReport: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.financeAdvisor) private var advisor
    @Environment(\.financeAdvisorEnabled) private var isEnabled
    @Environment(\.openFinanceSection) private var openSection

    var data = FinanceFetches()
    @State private var route: ReportFixRoute?
    @State private var report: FinanceReportWindowValue?
    @State private var rewrite: Task<Void, Never>?

    var body: some View {
        let availability = advisor.availability(isEnabled: isEnabled)
        let display = ReviewDisplay(model, availability: availability)
        // SheetStack, not a bare NavigationStack: on the Mac a bare sheet
        // takes its List's ideal size, a cramped box that squeezed the
        // headline, the groups and "Open Full Report" together. It is still a
        // NavigationStack, so the fixes and Ask push as before.
        SheetStack {
            List {
                Section {
                    if let headline = display.headline {
                        Text(headline)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    } else {
                        ReviewPlaceholderRow(lines: [0.95, 0.9, 0.5])
                    }
                    if display.isWriting {
                        ReviewWritingLabel(factCount: model.factCount)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 4, trailing: 20))

                ForEach(display.groups, id: \.self) { group in
                    Section(display.review.title(for: group)) {
                        let items = display.review.items(in: group)
                        ForEach(items) { item in
                            ReviewItemRow(item: item, open: open)
                        }
                        if display.isWriting {
                            ReviewPlaceholderRow(lines: items.isEmpty ? [0.88, 0.5] : [0.7])
                        }
                    }
                }

                if display.review.allItems.isEmpty, !display.isWriting {
                    Section {
                        Label("Nothing else stood out", systemImage: "checkmark.circle")
                            .foregroundStyle(FinanceTrackerModule.accent.color)
                    }
                }

                if availability == .available, !display.isWriting {
                    Section {
                        NavigationLink {
                            AskScreen(model: model)
                        } label: {
                            Label("Ask about \(model.scope.shortTitle)", systemImage: "bubble.left.and.text.bubble.right")
                        }
                    }
                }

                Section {
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        if display.isWriting {
                            Text("The checks below are already worked out. Apple Intelligence is only wording them, and nothing leaves this device.")
                        } else if display.isPlain, let footnote = availability.footnote {
                            Text(footnote)
                        }
                        Text(ReviewStyle.footer(isWrittenByModel: display.review.isWrittenByModel))
                    }
                }
            }
            .animation(.default, value: display.review)
            .safeAreaInset(edge: .bottom) {
                Button {
                    openFullReport()
                } label: {
                    Label("Open Full Report", systemImage: "doc.text")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .primaryActionStyle(tint: FinanceTrackerModule.accent.color)
                .controlSize(.large)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(ReviewStyle.title(for: model.scope, isPlain: display.isPlain))
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(ReviewStyle.title(for: model.scope, isPlain: display.isPlain))
                            .font(.headline)
                        HStack(spacing: 4) {
                            if !display.isPlain {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(ReviewStyle.intelligence)
                            }
                            Text(ReviewStyle.subtitle(isPlain: display.isPlain))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "xmark")
                    }
                }
                if availability == .available {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            writeAgain()
                        } label: {
                            Label("Write Again", systemImage: "arrow.clockwise")
                        }
                        .disabled(display.isWriting)
                        .help("Have Apple Intelligence write the review again")
                    }
                }
            }
            .reportFixDestinations($route, pushes: true)
        }
        .presentsReport($report)
        .tint(FinanceTrackerModule.accent.color)
    }

    private func open(_ fix: ReportFix) {
        guard let route = ReportFixRoute.resolve(
            fix,
            in: data.snapshot.household,
            period: model.data.period,
            spendingPeriods: model.data.spending.periods
        ) else { return }
        // Every holdings fix is about gold and silver ("Open Gold & Silver"):
        // Holdings otherwise opened on Accounts, a tap away from the item.
        if route == .holdings { HoldingsModeRequest.shared.showsMetals = true }
        if route == .holdings, openSection.isAvailable {
            dismiss()
            openSection("holdings")
        } else {
            self.route = route
        }
    }

    private func writeAgain() {
        rewrite?.cancel()
        // Not cancelled when the sheet closes: the Summary's card shows the
        // same model, and a review finished after the sheet is gone is still
        // kept for next time.
        rewrite = Task { await model.writeAgain(advisor: advisor, enabled: isEnabled) }
    }

    private func openFullReport() {
        if let onOpenReport {
            onOpenReport()
            return
        }
        report = FinanceReportWindowValue(scope: model.scope, ownerName: filter.map(\.reportOwnerName) ?? headerOwnerName)
    }

    /// The report's owner read back off its header, for a sheet given only
    /// the model: the header says "Everyone" or the owner's name.
    private var headerOwnerName: String? {
        let label = model.data.header.ownerLabel
        return data.snapshot.owners.contains { $0.name == label } ? label : nil
    }
}

/// Ask, pushed from the phone's review sheet.
private struct AskScreen: View {
    let model: ReportReviewModel

    var body: some View {
        ScrollView {
            AskView(model: model, showsTitle: false)
                .padding(20)
                .readableWidthInSidebar()
        }
        .navigationTitle("Ask about \(model.scope.shortTitle)")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - The Mac inspector

/// The review for the Mac report window's inspector: the same review as the
/// sheet, compact, with "Ask about <month>" under it. Fixes open their
/// editors in sheets — the inspector has no stack to push onto — and
/// Holdings in a sheet of its own, the module's tabs being in another window.
struct ReviewPanel: View {
    /// The window's own model, so the report's "in brief" section and the
    /// inspector are one review, written once.
    let model: ReportReviewModel

    var body: some View {
        ReviewPanelContent(model: model)
    }
}

private struct ReviewPanelContent: View {
    let model: ReportReviewModel

    @Environment(\.financeAdvisor) private var advisor
    @Environment(\.financeAdvisorEnabled) private var isEnabled
    @Environment(\.openFinanceSection) private var openSection

    var data = FinanceFetches()
    @State private var route: ReportFixRoute?
    @State private var rewrite: Task<Void, Never>?

    var body: some View {
        let availability = advisor.availability(isEnabled: isEnabled)
        let display = ReviewDisplay(model, availability: availability)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(display.isPlain ? "Check" : "Review")
                            .font(.headline)
                        HStack(spacing: 4) {
                            if !display.isPlain {
                                Image(systemName: "sparkles")
                                    .foregroundStyle(ReviewStyle.intelligence)
                            }
                            Text(ReviewStyle.subtitle(isPlain: display.isPlain))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if availability == .available {
                        Button {
                            rewrite?.cancel()
                            rewrite = Task { await model.writeAgain(advisor: advisor, enabled: isEnabled) }
                        } label: {
                            Label("Write Again", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .disabled(display.isWriting)
                        .help("Have Apple Intelligence write the review again")
                    }
                }

                if let headline = display.headline {
                    Text(headline)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ReviewPlaceholderRow(lines: [0.95, 0.9, 0.5])
                }
                if display.isWriting {
                    ReviewWritingLabel(factCount: model.factCount)
                }

                ForEach(display.groups, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(display.review.title(for: group))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        let items = display.review.items(in: group)
                        ForEach(items) { item in
                            ReviewItemRow(item: item, compact: true, open: open)
                        }
                        if display.isWriting {
                            ReviewPlaceholderRow(lines: items.isEmpty ? [0.88, 0.5] : [0.7])
                        }
                    }
                }

                if display.isPlain, let footnote = availability.footnote {
                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if availability == .available {
                    Divider()
                    AskView(model: model)
                }

                Text(ReviewStyle.footer(isWrittenByModel: display.review.isWrittenByModel))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(.default, value: display.review)
        .reportFixDestinations($route, pushes: false)
        .tint(FinanceTrackerModule.accent.color)
    }

    private func open(_ fix: ReportFix) {
        guard let route = ReportFixRoute.resolve(
            fix,
            in: data.snapshot.household,
            period: model.data.period,
            spendingPeriods: model.data.spending.periods
        ) else { return }
        // Every holdings fix is about gold and silver ("Open Gold & Silver"):
        // Holdings otherwise opened on Accounts, a tap away from the item.
        if route == .holdings { HoldingsModeRequest.shared.showsMetals = true }
        if route == .holdings, openSection.isAvailable {
            openSection("holdings")
        } else {
            self.route = route
        }
    }
}

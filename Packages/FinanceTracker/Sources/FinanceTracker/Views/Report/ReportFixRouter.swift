import Core
import CoreData
import SwiftUI

// MARK: - Where a fix leads

/// Where one of the review's one-tap fixes (`ReportFix`, worked out by
/// `MonthCheck` / `YearCheck`) takes the person: always one of the module's
/// real editors, never a copy of one — so a fix made from the review is the
/// same edit, with the same rules, as one made from its own tab.
enum ReportFixRoute: Identifiable, Hashable {
    /// The category's budget editor (`CategoryBudgetEditorView`), on the
    /// month a new limit would count in.
    case budget(SharedFinanceMonth, category: String)
    /// The charges behind a category or a merchant.
    case charges(ReportChargesQuery)
    /// A month's balances (`MonthEntryView`).
    case month(SharedFinanceMonth)
    /// Holdings — Gold & silver lives there.
    case holdings

    var id: String {
        switch self {
        case .budget(let month, let category): "budget|\(month.objectID.uriRepresentation())|\(SpendingSummary.key(category))"
        case .charges(let query): "charges|\(query.id)"
        case .month(let month): "month|\(month.objectID.uriRepresentation())"
        case .holdings: "holdings"
        }
    }

    /// The route for `fix` in `household`, or nil when what it points at is
    /// gone (a month deleted since the report was built) — the button then
    /// does nothing rather than open an editor on nothing.
    ///
    /// - Parameters:
    ///   - period: the report's own month (a year's last reported one).
    ///   - spendingPeriods: the months the report's spending covers.
    @MainActor
    static func resolve(
        _ fix: ReportFix,
        in household: SharedFinanceHousehold?,
        period: YearMonth,
        spendingPeriods: [YearMonth]
    ) -> ReportFixRoute? {
        switch fix {
        case .adjustBudget(let category):
            guard let household else { return nil }
            // The budget a change would count against: the open month's when
            // there is one — September's over-run is fixed in October's
            // budget, "Try in October" — else the report's own month.
            let latest = household.latestMonth
            let target = latest.flatMap { $0.isClosed ? nil : $0 } ?? household.month(for: period) ?? latest
            return target.map { .budget($0, category: category) }
        case .showCharges(let category, let merchant):
            // A merchant's charges are looked at over half a year, so a new
            // recurring charge shows next to the months it wasn't there.
            let periods = merchant != nil
                ? (0..<FinanceReportBuilder.recurringLookbackMonths).reversed().map { period.adding(months: -$0) }
                : (spendingPeriods.isEmpty ? [period] : spendingPeriods)
            return .charges(ReportChargesQuery(category: category, merchant: merchant, periods: periods))
        case .showRecurring(let merchants):
            // The report's own month: the recurring total is a monthly one.
            return .charges(ReportChargesQuery(category: nil, merchant: nil, periods: [period], merchants: merchants))
        case .updateBalances(let target), .openMonth(let target):
            return household?.month(for: target).map(ReportFixRoute.month)
        case .openHoldings:
            return .holdings
        }
    }
}

/// Which charges a "Show Charges" fix lists. The transactions are looked up
/// live when the list shows, so one edited from there updates in place.
struct ReportChargesQuery: Hashable, Identifiable {
    let category: String?
    let merchant: String?
    let periods: [YearMonth]
    /// Any of these merchants (the recurring ones); empty is no narrowing.
    var merchants: [String] = []

    var id: String {
        "\(category.map(SpendingSummary.key) ?? "")|\(merchant?.lowercased() ?? "")|\(periods.map(\.rawValue).joined(separator: ","))"
            + "|\(merchants.map { $0.lowercased() }.joined(separator: ","))"
    }

    var title: String { merchant ?? category ?? (merchants.isEmpty ? "Charges" : "Recurring Charges") }

    /// The household's matching transactions, newest first. Categories are
    /// compared the way budgets are ("food " is Food; "Other" takes the
    /// uncategorised), merchants ignoring case and stray spaces.
    func transactions(in all: [SharedFinanceTransaction]) -> [SharedFinanceTransaction] {
        var matching = all.filter { transaction in periods.contains { $0.contains(transaction.date) } }
        if let category {
            matching = SpendingSummary.transactions(matching, inCategory: category)
        }
        if let merchant {
            let wanted = merchant.trimmingCharacters(in: .whitespaces).lowercased()
            matching = matching.filter { $0.merchant.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
        }
        if !merchants.isEmpty {
            let wanted = Set(merchants.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            matching = matching.filter { wanted.contains($0.merchant.trimmingCharacters(in: .whitespaces).lowercased()) }
        }
        return matching.sorted { $0.date != $1.date ? $0.date > $1.date : $0.createdAt > $1.createdAt }
    }
}

private extension YearMonth {
    func adding(months count: Int) -> YearMonth {
        var period = self
        if count > 0 {
            for _ in 0..<count { period = period.next }
        } else {
            for _ in 0..<(-count) { period = period.previous }
        }
        return period
    }
}

// MARK: - Switching the module's section

/// Lets a screen inside Finance switch the module to another of its sections
/// — the review's "Open Gold & Silver" goes to Holdings rather than stacking
/// a second copy of it over the sheet. Set by `FinanceRootView`; outside it
/// (the Mac's report window) it's unavailable and the fix opens Holdings in a
/// sheet instead.
///
/// Always-equal for the same reason as Core's `PresentShareSheetAction`: a
/// closure in the environment otherwise invalidates every reader on every
/// update of the host.
struct OpenFinanceSectionAction: Equatable {
    private let action: (@MainActor (String) -> Void)?

    init(_ action: (@MainActor (String) -> Void)?) {
        self.action = action
    }

    var isAvailable: Bool { action != nil }

    @MainActor
    func callAsFunction(_ sectionID: String) {
        action?(sectionID)
    }

    static func == (lhs: OpenFinanceSectionAction, rhs: OpenFinanceSectionAction) -> Bool {
        lhs.isAvailable == rhs.isAvailable
    }
}

extension EnvironmentValues {
    @Entry var openFinanceSection = OpenFinanceSectionAction(nil)
}

/// Asks Holdings to show its Gold & silver mode the next time it appears or
/// sees this change — set by a review's "Open Gold & Silver", whether that
/// switches the module to its Holdings tab (already built, its mode in
/// `@State`) or opens Holdings in a sheet. Holdings clears it once honoured.
@MainActor @Observable
final class HoldingsModeRequest {
    static let shared = HoldingsModeRequest()
    var showsMetals = false
}

// MARK: - Presenting a route

extension View {
    /// Shows `route` when set: the budget editor as a sheet, as everywhere
    /// else; charges and a month pushed onto the enclosing `NavigationStack`
    /// when `pushes` (the phone's review sheet), else in a sheet of their own
    /// (the Mac report window's inspector, which has no stack to push onto).
    func reportFixDestinations(_ route: Binding<ReportFixRoute?>, pushes: Bool) -> some View {
        modifier(ReportFixPresenter(route: route, pushes: pushes))
    }
}

private struct ReportFixPresenter: ViewModifier {
    @Binding var route: ReportFixRoute?
    let pushes: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: budgetTarget) { target in
                CategoryBudgetEditorView(target: target)
            }
            .navigationDestination(item: pushes ? pushed : .constant(nil)) { route in
                destination(route)
            }
            .sheet(item: pushes ? .constant(nil) : pushed) { route in
                SheetStack {
                    destination(route)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                DismissButton()
                            }
                        }
                }
            }
            // Holdings carries its own NavigationStack, so it can't be pushed
            // onto another or wrapped in a SheetStack.
            .sheet(isPresented: showsHoldings) {
                HoldingsSheet()
            }
    }

    @ViewBuilder
    private func destination(_ route: ReportFixRoute) -> some View {
        switch route {
        case .charges(let query): ReportChargesView(query: query)
        case .month(let month): MonthEntryView(month: month)
        case .budget, .holdings: EmptyView()
        }
    }

    private var budgetTarget: Binding<CategoryBudgetEditorView.Target?> {
        Binding {
            if case .budget(let month, let category) = route {
                return CategoryBudgetEditorView.Target(month: month, category: category)
            }
            return nil
        } set: { target in
            if target == nil, case .budget = route { route = nil }
        }
    }

    private var pushed: Binding<ReportFixRoute?> {
        Binding {
            switch route {
            case .charges, .month: route
            default: nil
            }
        } set: { newValue in
            if newValue == nil {
                if case .charges = route { route = nil }
                if case .month = route { route = nil }
            } else {
                route = newValue
            }
        }
    }

    private var showsHoldings: Binding<Bool> {
        Binding {
            route == .holdings
        } set: { shown in
            if !shown, route == .holdings { route = nil }
        }
    }
}

private struct DismissButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button("Done") { dismiss() }
    }
}

/// Holdings in a sheet, for where the module's own Holdings tab can't be
/// switched to. A bar of its own carries Done: Holdings' toolbar belongs to
/// its own stack, and a sheet with no way out on the Mac is a trap.
private struct HoldingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HoldingsView()
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 480, idealHeight: 640)
    }
}

/// The charges a "Show Charges" fix asked for: one category's in the report's
/// months, or one merchant's over half a year.
struct ReportChargesView: View {
    let query: ReportChargesQuery
    var data = FinanceFetches()

    var body: some View {
        let transactions = query.transactions(in: data.snapshot.transactions)
        List {
            if transactions.isEmpty {
                Section {
                    Text("No charges here any more.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(transactions) { transaction in
                        TransactionRow(transaction: transaction)
                    }
                } footer: {
                    Text("\(counted(transactions.count, "charge")), \(FinanceFormat.cents(SpendingSummary.total(transactions))) in all, \(periodLabel).")
                }
            }
        }
        .navigationTitle(query.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// "in September 2026", "from April to September 2026".
    private var periodLabel: String {
        guard let first = query.periods.min(), let last = query.periods.max() else { return "" }
        if first == last { return "in \(first.title)" }
        return first.year == last.year ? "from \(first.monthName) to \(last.title)" : "from \(first.title) to \(last.title)"
    }
}

// MARK: - Opening the report

extension OwnerFilter {
    /// The owner's name a report is opened with (`FinanceReportWindowValue`
    /// names owners, which can't leave the store); nil is Everyone.
    var reportOwnerName: String? {
        switch self {
        case .all: nil
        case .owner(let owner): owner.name
        }
    }

    /// Settings' "Whose by default", if that person is still in the
    /// household — for a report opened with no filter chosen (a notification,
    /// a launch argument); nil is Everyone.
    static func reportDefaultOwnerName(preferred: String?, owners: [SharedFinanceOwner]) -> String? {
        guard let preferred, owners.contains(where: { $0.name == preferred }) else { return nil }
        return preferred
    }
}

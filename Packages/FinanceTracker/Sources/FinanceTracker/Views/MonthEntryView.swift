import Core
import CoreData
import SwiftUI

/// Typing in a month: metal prices (live while it's the open latest month —
/// see `MetalPriceFeed`), then every account's balance category by category,
/// person by person. A new month starts every balance at zero; a row not yet
/// filled in offers last month's figure as one tap. Cards are read-only here
/// — their figure is their transactions. The Mac has its own grid,
/// `MacMonthEntryView`.
struct MonthEntryView: View {
    @ObservedObject var month: SharedFinanceMonth

    @Environment(\.moduleLayout) private var layout
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    var data = FinanceFetches()

    init(month: SharedFinanceMonth) {
        self.month = month
    }

    var body: some View {
        if layout == .sidebar {
            MacMonthEntryView(month: month)
        } else {
            phoneList
        }
    }

    private var phoneList: some View {
        let snapshot = data.snapshot
        let isEditable = canEdit(month, in: container)
        let previousName = month.previousMonth?.monthName
        let feed = MetalPriceFeed.shared
        let carryable = MonthRollover.unfilledWithPrevious(in: month).count
        return List {
            if !month.isClosed {
                Section {
                    MonthProgressRow(month: month, progress: MonthRollover.progress(of: month, live: feed.live))
                    if isEditable, carryable > 0, let previousName {
                        Button("Same as \(previousName) for the other \(carryable)", systemImage: "arrow.uturn.backward") {
                            MonthRollover.carryOverUnfilled(in: month)
                            save()
                        }
                    }
                }
            }

            Section {
                if feed.isLive(month), let live = feed.live {
                    livePriceRow("Gold", value: live.gold)
                    livePriceRow("Silver", value: live.silver)
                } else {
                    priceRow("Gold", value: month.goldPricePerOz, isEditable: isEditable) { month.goldPricePerOz = $0 }
                    priceRow("Silver", value: month.silverPricePerOz, isEditable: isEditable) { month.silverPricePerOz = $0 }
                }
            } header: {
                Text("Metal prices")
            } footer: {
                Group {
                    if feed.isLive(month) {
                        Text("Live, per ounce, from gold and silver futures (\(MetalQuoteClient.goldSymbol) and \(MetalQuoteClient.silverSymbol))\(updated(feed.fetchedAt)). Weights are in regular ounces, as in the Numbers sheet. Closing \(month.monthName) saves the prices with it.")
                    } else {
                        Text("Per ounce. Gold & silver are valued at these, by weight in regular ounces as in the Numbers sheet.")
                    }
                }
                // A Mac list footer is one line unless told otherwise, and cut
                // this one off mid-word.
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(AccountCategory.monthlyCases) { category in
                let rows = accounts(in: category, snapshot: snapshot)
                if !rows.isEmpty {
                    let groups = AccountGrouping.byOwner(rows)
                    Section {
                        ForEach(groups) { group in
                            // A sub-heading per person; none when no one owns
                            // anything in the category.
                            if group.owner != nil || groups.count > 1 {
                                OwnerGroupHeader(group: group, total: total(of: group.accounts))
                                    .listRowSeparator(.hidden, edges: .bottom)
                            }
                            ForEach(group.accounts) { account in
                                let balance = month.balance(for: account)
                                BalanceRow(
                                    account: account,
                                    amount: balance?.amount ?? 0,
                                    edited: balance?.edited ?? false,
                                    hasBalance: balance != nil,
                                    previous: MonthRollover.previousAmount(for: account, in: month),
                                    previousName: previousName,
                                    isEditable: isEditable,
                                    commit: { _ = month.setBalance($0, for: account) },
                                    useAmount: { amount in
                                        month.setBalance(amount, for: account)
                                        save()
                                    },
                                    save: save
                                )
                            }
                        }
                    } header: {
                        HStack {
                            Text(category.displayName)
                            Spacer()
                            Text(FinanceFormat.money(total(of: rows)))
                                .monospacedDigit()
                        }
                    }
                }
            }

            let cards = snapshot.cards.filter { !$0.isArchived || $0.value(in: month) != 0 }
            if !cards.isEmpty {
                Section {
                    ForEach(cards) { card in
                        HStack {
                            OwnerBadge(owner: card.owner)
                            Text(card.displayName)
                                .lineLimit(1)
                            Spacer()
                            Text(FinanceFormat.cents(card.value(in: month)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Cards")
                } footer: {
                    Text("Added up from \(month.monthName)'s transactions — add those under Spending.")
                }
            }

            if isEditable {
                Section {
                    if let closedAt = month.closedAt {
                        LabeledContent("Closed", value: closedAt.formatted(date: .abbreviated, time: .omitted))
                        Button("Reopen \(month.monthName)") {
                            month.reopen()
                            save()
                        }
                    } else {
                        Button("Close \(month.monthName)") {
                            // The live prices it's been valued at become its
                            // own; see MetalPriceFeed for why not before.
                            let prices = feed.prices(for: month)
                            month.goldPricePerOz = prices.gold
                            month.silverPricePerOz = prices.silver
                            month.close()
                            save()
                        }
                        .fontWeight(.semibold)
                    }
                } footer: {
                    if !month.isClosed {
                        Text("Closing marks the month done. Figures can still be changed afterwards.")
                    }
                }
            }
        }
        .readableWidthInSidebar()
        .navigationTitle(month.title)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: save)
        .task { await MetalPriceFeed.shared.refreshIfStale() }
    }

    private func livePriceRow(_ title: String, value: Double) -> some View {
        LabeledContent(title) {
            Text(FinanceFormat.cents(value))
                .monospacedDigit()
        }
    }

    private func updated(_ date: Date?) -> String {
        guard let date else { return "" }
        return ", updated \(date.formatted(.relative(presentation: .named)))"
    }

    private func accounts(in category: AccountCategory, snapshot: FinanceSnapshot) -> [SharedFinanceAccount] {
        Self.accounts(in: category, of: month, snapshot: snapshot)
    }

    /// Every account with a balance this month, plus open accounts added
    /// since it started (which get a balance the moment one's typed).
    static func accounts(in category: AccountCategory, of month: SharedFinanceMonth, snapshot: FinanceSnapshot) -> [SharedFinanceAccount] {
        snapshot.accounts.filter { account in
            account.category == category && (month.balance(for: account) != nil || !account.isArchived)
        }
    }

    private func total(of accounts: [SharedFinanceAccount]) -> Double {
        accounts.reduce(0) { $0 + (month.balance(for: $1)?.amount ?? 0) }
    }

    private func priceRow(_ title: String, value: Double, isEditable: Bool, set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            if isEditable {
                AmountField(title: "Price per oz", value: value, commit: set, endEditing: save)
            } else {
                Text(FinanceFormat.cents(value))
                    .monospacedDigit()
            }
        }
    }

    private func save() {
        try? context.saveIfNeeded()
    }
}

private struct BalanceRow: View {
    @ObservedObject var account: SharedFinanceAccount
    let amount: Double
    let edited: Bool
    let hasBalance: Bool
    /// Last month's figure, if it had one.
    let previous: Double?
    let previousName: String?
    let isEditable: Bool
    let commit: (Double) -> Void
    /// Fills in last month's figure and saves.
    let useAmount: (Double) -> Void
    let save: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                AccountNameText(account: account)
                status
            }
            Spacer(minLength: 8)
            if isEditable {
                AmountField(title: "0", value: amount, commit: commit, endEditing: save)
                    .frame(maxWidth: 140)
            } else {
                Text(FinanceFormat.money(amount))
                    .monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if edited, let previous {
            DeltaText(delta: amount - previous, upIsGood: !account.category.isLiability)
                .font(.caption)
        } else if !edited {
            if let previous, let previousName {
                if isEditable {
                    // Unchanged is an answer too: this takes last month's
                    // figure without retyping it.
                    Button {
                        useAmount(previous)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.uturn.backward")
                                .imageScale(.small)
                            Text("\(previousName) \(FinanceFormat.money(previous))")
                        }
                        .font(.caption)
                        .lineLimit(1)
                    }
                    .buttonStyle(.borderless)
                    .tint(FinanceTrackerModule.accent.color)
                    .accessibilityLabel("Same as \(previousName), \(FinanceFormat.money(previous))")
                } else {
                    Text("\(previousName) \(FinanceFormat.money(previous))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(hasBalance ? "Not filled in" : "No balance yet")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// "Chase" over "Checking" — the institution first, since that's what the
/// accounts are sorted by, and the account's own name small beneath.
struct AccountNameText: View {
    @ObservedObject var account: SharedFinanceAccount

    var body: some View {
        let institution = account.institution.trimmingCharacters(in: .whitespaces)
        let name = account.name.trimmingCharacters(in: .whitespaces)
        VStack(alignment: .leading, spacing: 1) {
            Text(institution.isEmpty ? (name.isEmpty ? "Untitled" : name) : institution)
                .lineLimit(1)
            if !institution.isEmpty, !name.isEmpty {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

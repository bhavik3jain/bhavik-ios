import Core
import CoreData
import SwiftUI

/// Typing in a month: metal prices (live while it's the open latest month —
/// see `MetalPriceFeed`), then every account's balance category by category. Rows still showing last month's figure say so until changed or
/// confirmed. Cards are read-only here — their figure is their transactions.
struct MonthEntryView: View {
    @ObservedObject var month: SharedFinanceMonth

    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    var data = FinanceFetches()

    init(month: SharedFinanceMonth) {
        self.month = month
    }

    var body: some View {
        let snapshot = data.snapshot
        let isEditable = canEdit(month, in: container)
        let previousName = month.previousMonth?.monthName
        let feed = MetalPriceFeed.shared
        List {
            if !month.isClosed {
                Section {
                    MonthProgressRow(month: month, progress: MonthRollover.progress(of: month, live: feed.live))
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
                    Section {
                        ForEach(rows) { account in
                            let balance = month.balance(for: account)
                            BalanceRow(
                                account: account,
                                amount: balance?.amount ?? 0,
                                edited: balance?.edited ?? false,
                                hasBalance: balance != nil,
                                previousName: previousName,
                                isEditable: isEditable,
                                commit: { _ = month.setBalance($0, for: account) },
                                confirm: {
                                    month.setBalance(balance?.amount ?? 0, for: account)
                                    save()
                                },
                                save: save
                            )
                        }
                    } header: {
                        HStack {
                            Text(category.displayName)
                            Spacer()
                            Text(FinanceFormat.money(rows.reduce(0) { $0 + (month.balance(for: $1)?.amount ?? 0) }))
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

    /// Every account with a balance this month, plus open accounts added
    /// since it started (which get a balance the moment one's typed).
    private func accounts(in category: AccountCategory, snapshot: FinanceSnapshot) -> [SharedFinanceAccount] {
        snapshot.accounts.filter { account in
            account.category == category && (month.balance(for: account) != nil || !account.isArchived)
        }
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
    let previousName: String?
    let isEditable: Bool
    let commit: (Double) -> Void
    let confirm: () -> Void
    let save: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            OwnerBadge(owner: account.owner)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName.isEmpty ? "Untitled" : account.displayName)
                    .lineLimit(1)
                if !hasBalance {
                    Text("No balance yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !edited, let previousName {
                    HStack(spacing: 6) {
                        Text("Still \(previousName)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        if isEditable {
                            // Unchanged is an answer too: this marks the
                            // copied figure as checked without retyping it.
                            Button("Same", systemImage: "checkmark.circle", action: confirm)
                                .labelStyle(.iconOnly)
                                .font(.caption)
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Unchanged since \(previousName)")
                        }
                    }
                }
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
}

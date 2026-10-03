import Core
import CoreData
import SwiftUI

/// A month's balances on the Mac, laid out like the sheet it replaced: a
/// card per category, a row per account under each person, last month's
/// figure beside this month's field and the change after it. Return moves to
/// the next field (Tab does too), the first one not yet filled in has focus
/// on open, and ↺ takes last month's figure. The phone's list, stretched
/// across a window, put each field a foot from its name under paragraphs of
/// footer text.
struct MacMonthEntryView: View {
    @ObservedObject var month: SharedFinanceMonth

    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    var data = FinanceFetches()

    @FocusState private var focus: NSManagedObjectID?
    @State private var focusedOnOpen = false

    private var accent: Color { FinanceTrackerModule.accent.color }

    /// Fixed so every category's card lines its columns up with the others;
    /// a `Grid` left to size itself put each card's columns somewhere else.
    private enum Column {
        static let previous: CGFloat = 110
        static let field: CGFloat = 130
        static let change: CGFloat = 90
        static let reuse: CGFloat = 20
    }

    var body: some View {
        let snapshot = data.snapshot
        let isEditable = canEdit(month, in: container)
        let sections = AccountCategory.monthlyCases.compactMap { category -> (AccountCategory, [AccountGroup])? in
            let accounts = MonthEntryView.accounts(in: category, of: month, snapshot: snapshot)
            return accounts.isEmpty ? nil : (category, AccountGrouping.byOwner(accounts))
        }
        // The order Return walks the fields in: the order they're shown.
        let order = sections.flatMap { $0.1.flatMap(\.accounts) }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(snapshot: snapshot, isEditable: isEditable)

                ForEach(sections, id: \.0) { category, groups in
                    categoryCard(category, groups: groups, order: order, isEditable: isEditable)
                }

                cardsCard(snapshot)
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(month.title)
        .moduleSubtitle(month.isClosed ? "Closed" : MonthRollover.progress(of: month, live: snapshot.live).label)
        .toolbar {
            if isEditable {
                ToolbarItem(placement: .primaryAction) {
                    if month.isClosed {
                        Button("Reopen", systemImage: "lock.open") {
                            month.reopen()
                            save()
                        }
                        .help("Reopen \(month.monthName)")
                    } else {
                        Button("Close Month", systemImage: "checkmark.seal") { close() }
                            .help("Mark \(month.monthName) done. Figures can still be changed afterwards.")
                    }
                }
            }
        }
        .onDisappear(perform: save)
        .task { await MetalPriceFeed.shared.refreshIfStale() }
        .onAppear {
            // The first field still to fill in, so typing can start at once.
            guard !focusedOnOpen, isEditable, !month.isClosed else { return }
            focusedOnOpen = true
            focus = order.first { month.balance(for: $0)?.edited != true }?.objectID
        }
    }

    // MARK: - Header

    private func header(snapshot: FinanceSnapshot, isEditable: Bool) -> some View {
        let progress = MonthRollover.progress(of: month, live: snapshot.live)
        let carryable = MonthRollover.unfilledWithPrevious(in: month).count
        let feed = MetalPriceFeed.shared
        let prices = feed.prices(for: month)
        let isLive = feed.isLive(month)
        return HStack(alignment: .center, spacing: 18) {
            if !month.isClosed {
                Gauge(value: progress.fraction) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(progress.updated)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(accent)
                .help(progress.label)
            } else {
                Image(systemName: "checkmark.seal.fill")
                    .font(.largeTitle)
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 4) {
                // Until every balance is in, the total is only what's been
                // typed so far — see `FinanceHome.reportedMonth`.
                Text(progress.isComplete || month.isClosed ? "Net worth" : "Net worth so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(FinanceFormat.money(snapshot.summary(for: month).netWorth))
                    .font(.title.weight(.bold))
                    .monospacedDigit()
            }

            Spacer()

            HStack(spacing: 10) {
                MetalPriceChip(symbol: "Au", title: "Gold", price: prices.gold, isLive: isLive, fill: Color(red: 0.80, green: 0.62, blue: 0.16)) {
                    month.goldPricePerOz = $0
                } save: { save() }
                MetalPriceChip(symbol: "Ag", title: "Silver", price: prices.silver, isLive: isLive, fill: .gray) {
                    month.silverPricePerOz = $0
                } save: { save() }
            }
            .disabled(!isEditable)

            if isEditable, !month.isClosed, carryable > 0, let previous = month.previousMonth {
                Button {
                    MonthRollover.carryOverUnfilled(in: month)
                    save()
                } label: {
                    Label("Same as \(previous.monthName)", systemImage: "arrow.uturn.backward")
                }
                .help("Fill the \(counted(carryable, "balance")) not yet filled in with \(previous.monthName)'s figures")
            }
        }
        .padding(18)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }

    // MARK: - Categories

    private func categoryCard(
        _ category: AccountCategory,
        groups: [AccountGroup],
        order: [SharedFinanceAccount],
        isEditable: Bool
    ) -> some View {
        let previous = month.previousMonth
        let accounts = groups.flatMap(\.accounts)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Label(category.displayName, systemImage: category.symbolName)
                    .font(.headline)
                Spacer()
                Text(FinanceFormat.money(total(of: accounts)))
                    .font(.headline)
                    .monospacedDigit()
            }
            .padding(.bottom, 10)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
                    Text(previous?.period?.shortName ?? "")
                        .frame(width: Column.previous, alignment: .trailing)
                    Text(month.period?.shortName ?? "")
                        .frame(width: Column.field, alignment: .trailing)
                    Text("Change")
                        .frame(width: Column.change, alignment: .trailing)
                    Color.clear.frame(width: Column.reuse, height: 1)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

                ForEach(groups) { group in
                    Divider()
                    GridRow {
                        HStack(spacing: 6) {
                            OwnerBadge(owner: group.owner)
                            Text(group.title)
                                .font(.subheadline.weight(.semibold))
                        }
                        .gridCellColumns(2)
                        Text(FinanceFormat.money(total(of: group.accounts)))
                            .font(.subheadline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 6)
                            .frame(width: Column.field, alignment: .trailing)
                        Color.clear.gridCellColumns(2).frame(height: 1)
                    }
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                    ForEach(group.accounts) { account in
                        row(account, previous: previous, order: order, isEditable: isEditable)
                    }
                }
            }
        }
        .padding(18)
        .background(.background.secondary, in: .rect(cornerRadius: 16))
    }

    private func row(
        _ account: SharedFinanceAccount,
        previous: SharedFinanceMonth?,
        order: [SharedFinanceAccount],
        isEditable: Bool
    ) -> some View {
        let balance = month.balance(for: account)
        let amount = balance?.amount ?? 0
        let edited = balance?.edited ?? false
        let last = previous?.balance(for: account)?.amount
        return GridRow {
            HStack(spacing: 6) {
                AccountNameText(account: account)
                if !edited, !month.isClosed {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                        .help("Not filled in yet")
                }
            }
            .padding(.leading, 26)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(last.map(FinanceFormat.money) ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Column.previous, alignment: .trailing)

            Group {
                if isEditable {
                    AmountTextField(
                        title: "0",
                        value: amount,
                        isFocused: focus == account.objectID,
                        commit: { _ = month.setBalance($0, for: account) },
                        endEditing: save
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: account.objectID)
                    .onSubmit { focus = next(after: account, in: order)?.objectID }
                } else {
                    Text(FinanceFormat.money(amount))
                        .monospacedDigit()
                }
            }
            .frame(width: Column.field)

            Group {
                if edited, let last {
                    DeltaText(delta: amount - last, upIsGood: !account.category.isLiability)
                } else {
                    Text("")
                }
            }
            .frame(width: Column.change, alignment: .trailing)

            Group {
                if isEditable, !edited, let last {
                    Button {
                        month.setBalance(last, for: account)
                        save()
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(accent)
                    .help("Same as \(previous?.monthName ?? "last month"): \(FinanceFormat.money(last))")
                } else {
                    Color.clear
                }
            }
            .frame(width: Column.reuse)
        }
        .padding(.vertical, 5)
    }

    // MARK: - Cards

    @ViewBuilder
    private func cardsCard(_ snapshot: FinanceSnapshot) -> some View {
        let cards = snapshot.cards.filter { !$0.isArchived || $0.value(in: month) != 0 }
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Cards", systemImage: AccountCategory.card.symbolName)
                        .font(.headline)
                    Text("from Spending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(FinanceFormat.money(cards.reduce(0) { $0 + $1.value(in: month) }))
                        .font(.headline)
                        .monospacedDigit()
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
                    ForEach(AccountGrouping.ordered(cards)) { card in
                        HStack(spacing: 8) {
                            OwnerBadge(owner: card.owner)
                            AccountNameText(account: card)
                            Spacer(minLength: 4)
                            Text(FinanceFormat.cents(card.value(in: month)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(.background, in: .rect(cornerRadius: 10))
                    }
                }
            }
            .padding(18)
            .background(.background.secondary, in: .rect(cornerRadius: 16))
        }
    }

    // MARK: -

    private func next(after account: SharedFinanceAccount, in order: [SharedFinanceAccount]) -> SharedFinanceAccount? {
        guard let index = order.firstIndex(of: account), index + 1 < order.count else { return nil }
        return order[index + 1]
    }

    private func total(of accounts: [SharedFinanceAccount]) -> Double {
        accounts.reduce(0) { $0 + (month.balance(for: $1)?.amount ?? 0) }
    }

    private func close() {
        // The live prices it's been valued at become its own; see
        // MetalPriceFeed for why not before.
        let prices = MetalPriceFeed.shared.prices(for: month)
        month.goldPricePerOz = prices.gold
        month.silverPricePerOz = prices.silver
        month.close()
        save()
    }

    private func save() {
        try? context.saveIfNeeded()
    }
}

/// "Au $4,512.30 · Live" — a metal's price per ounce. Live prices are read
/// only; otherwise a click edits it in a popover.
private struct MetalPriceChip: View {
    let symbol: String
    let title: String
    let price: Double
    let isLive: Bool
    let fill: Color
    let commit: (Double) -> Void
    let save: () -> Void

    @State private var editing = false

    var body: some View {
        Button {
            if !isLive { editing = true }
        } label: {
            HStack(spacing: 8) {
                Text(symbol)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(fill, in: .rect(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 0) {
                    Text(FinanceFormat.cents(price))
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                    Text(isLive ? "Live / oz" : "per oz")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.background, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help(isLive
              ? "\(title), live from futures. Closing the month saves it."
              : "\(title) per ounce — click to change")
        .popover(isPresented: $editing) {
            LabeledContent("\(title) per oz") {
                AmountField(title: "0", value: price, commit: commit, endEditing: save)
                    .frame(width: 120)
            }
            .padding()
        }
    }
}

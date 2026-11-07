import Core
import CoreData
import SwiftUI

/// The seal a verified transaction wears, wherever it's listed.
struct VerifiedSeal: View {
    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .foregroundStyle(VerifiedStyle.seal)
            .accessibilityLabel("Verified")
    }
}

enum VerifiedStyle {
    /// Holds 3:1 on both a white and a dark row.
    static let seal = Color(red: 0.09, green: 0.57, blue: 0.48)
    /// The sheet's teal (#6DCFB9), thinned so a row's text reads over it in
    /// light and dark alike.
    static let rowTint = Color(red: 109 / 255, green: 207 / 255, blue: 185 / 255).opacity(0.25)
}

/// Saves the ticks together: a save per tick is an upload per tick, and an
/// iCloud alert on the partner's phone per upload. Called on leaving, and on
/// going to the background, where the app could be killed with them unsaved.
private func saveVerification(in context: NSManagedObjectContext) {
    try? context.saveIfNeeded()
}

private extension StatementProgress {
    /// "14 of 38 verified", "Not started · 12 charges", "All 9 verified".
    var status: String {
        if isComplete { return "All \(total) verified" }
        if verified == 0 { return "Not started · \(counted(total, "charge"))" }
        return "\(verified) of \(total) verified"
    }
}

/// A tick or an empty circle, as a button of its own beside the row's content.
private struct VerifyToggle: View {
    @ObservedObject var transaction: SharedFinanceTransaction
    let size: CGFloat
    let toggle: () -> Void

    var body: some View {
        // Deleted, here or on another device, while on screen: see `isGone`.
        if !transaction.isGone { content }
    }

    private var content: some View {
        Button(action: toggle) {
            Image(systemName: transaction.isVerified ? "checkmark.seal.fill" : "circle")
                .font(.system(size: size))
                .foregroundStyle(transaction.isVerified ? VerifiedStyle.seal : Color.secondary.opacity(0.6))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(transaction.isVerified
            ? "Unverify \(transaction.merchant)"
            : "Verify \(transaction.merchant)")
    }
}

private struct StatementProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(VerifiedStyle.seal)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

// MARK: - Phone

/// Pick a card, then tick off its charges. Presented from Spending's seal.
struct StatementVerifySheet: View {
    @Environment(\.dismiss) private var dismiss
    var data = FinanceFetches()

    @State private var period: YearMonth

    init(startingPeriod: YearMonth) {
        _period = State(initialValue: startingPeriod)
    }

    var body: some View {
        let snapshot = data.snapshot
        let cards = StatementVerification.cards(among: snapshot.accounts, transactions: snapshot.transactions, in: period)
        SheetStack {
            List {
                Section {
                    Picker("Counts toward", selection: $period) {
                        ForEach(periods(snapshot)) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    if cards.isEmpty {
                        Text("No card charges in \(period.title).")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(cards) { card in
                        let progress = StatementProgress(StatementVerification.charges(of: card, among: snapshot.transactions, in: period))
                        NavigationLink {
                            StatementChecklistView(card: card, period: period) { dismiss() }
                        } label: {
                            StatementCardRow(card: card, progress: progress)
                        }
                    }
                } header: {
                    Text("Cards")
                } footer: {
                    Text("Only this month's charges are listed, including ones dated in another month that count toward it.")
                }
            }
            .navigationTitle("Verify a Statement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
    }

    private func periods(_ snapshot: FinanceSnapshot) -> [YearMonth] {
        var periods = Set(snapshot.months.compactMap(\.period))
        periods.formUnion(snapshot.transactions.map(\.countedPeriod))
        periods.insert(period)
        return periods.sorted(by: >)
    }
}

private struct StatementCardRow: View {
    let card: SharedFinanceAccount
    let progress: StatementProgress

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress.fraction)
                    .stroke(VerifiedStyle.seal, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if progress.isComplete {
                    Image(systemName: "checkmark")
                        .font(.caption.bold())
                        .foregroundStyle(VerifiedStyle.seal)
                }
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.name.isEmpty ? card.displayName : card.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(progress.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(FinanceFormat.cents(progress.totalCost))
                .font(.subheadline)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }
}

/// One card's charges for the month: tap the circle to verify, the row to edit.
private struct StatementChecklistView: View {
    let card: SharedFinanceAccount
    let period: YearMonth
    let done: () -> Void

    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    var data = FinanceFetches()

    @State private var editing: SharedFinanceTransaction?
    /// Unsaved ticks don't come through the fetches, so the header's counts
    /// wouldn't move; bumped on each one, and read in the body.
    @State private var ticks = 0

    var body: some View {
        let charges = StatementVerification.charges(of: card, among: data.snapshot.transactions, in: period)
        let progress = StatementProgress(charges)
        let _ = ticks
        List {
            ForEach(charges) { charge in
                StatementChargeRow(transaction: charge) {
                    charge.setVerified(!charge.isVerified)
                    ticks &+= 1
                } edit: {
                    editing = charge
                }
            }
        }
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(progress.verified) of \(progress.total) verified")
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(FinanceFormat.cents(progress.verifiedCost)) of \(FinanceFormat.cents(progress.totalCost))")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                StatementProgressBar(fraction: progress.fraction)
            }
            .padding(14)
            .background(.background, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
        .navigationTitle(card.name.isEmpty ? card.displayName : card.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: done)
                    .fontWeight(.semibold)
            }
        }
        .sheet(item: $editing) { transaction in
            TransactionEditorView(transaction: transaction, defaultDate: transaction.date)
        }
        .onDisappear { saveVerification(in: context) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveVerification(in: context) }
        }
    }
}

private struct StatementChargeRow: View {
    @ObservedObject var transaction: SharedFinanceTransaction
    let toggle: () -> Void
    let edit: () -> Void

    var body: some View {
        // Deleted, here or on another device, while on screen: see `isGone`.
        if !transaction.isGone { content }
    }

    private var content: some View {
        HStack(spacing: 4) {
            VerifyToggle(transaction: transaction, size: 24, toggle: toggle)
            Button(action: edit) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transaction.merchant.isEmpty ? "Untitled" : transaction.merchant)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text(transaction.statementDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    StatementAmount(transaction: transaction)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 16))
        .listRowBackground(transaction.isVerified ? VerifiedStyle.rowTint : nil)
    }
}

private struct StatementAmount: View {
    @ObservedObject var transaction: SharedFinanceTransaction

    var body: some View {
        // Deleted, here or on another device, while on screen: see `isGone`.
        if !transaction.isGone { content }
    }

    private var content: some View {
        Text(FinanceFormat.cents(transaction.cost))
            .monospacedDigit()
            .foregroundStyle(transaction.cost < 0 ? Color.green : Color.primary)
    }
}

private extension SharedFinanceTransaction {
    /// "Oct 4 · Home". The date shows when a charge is dated outside the month.
    var statementDetail: String {
        [date.formatted(.dateTime.month(.abbreviated).day()), category].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Mac

/// Spending's verify mode on the Mac: the month's cards down the side, the
/// chosen one's charges beside them. A `List` with columns laid out by hand, not
/// the `Table` the transactions use: a `Table` can't tint a whole row, and row
/// tint is how this screen shows what's left.
struct MacStatementVerifyView: View {
    let period: YearMonth
    let isEditable: Bool
    let edit: (SharedFinanceTransaction) -> Void
    let done: () -> Void

    @Environment(\.managedObjectContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    var data = FinanceFetches()

    @State private var chosenCard: SharedFinanceAccount?
    @State private var selection: NSManagedObjectID?
    /// See `StatementChecklistView.ticks`.
    @State private var ticks = 0
    @FocusState private var isListFocused: Bool

    private static let dateWidth: CGFloat = 70
    private static let categoryWidth: CGFloat = 150
    private static let amountWidth: CGFloat = 90

    var body: some View {
        let snapshot = data.snapshot
        let cards = StatementVerification.cards(among: snapshot.accounts, transactions: snapshot.transactions, in: period)
        let progressByCard = Dictionary(uniqueKeysWithValues: cards.map { card in
            (card, StatementProgress(StatementVerification.charges(of: card, among: snapshot.transactions, in: period)))
        })
        // A month with none of the chosen card's charges falls back to the
        // first card with something left to do.
        let card = chosenCard.flatMap { cards.contains($0) ? $0 : nil }
            ?? cards.first { progressByCard[$0]?.isComplete == false }
            ?? cards.first
        let charges = card.map { StatementVerification.charges(of: $0, among: snapshot.transactions, in: period) } ?? []
        let _ = ticks

        Group {
            if cards.isEmpty {
                ContentUnavailableView("No card charges in \(period.title)", systemImage: "checkmark.seal")
            } else {
                HStack(spacing: 0) {
                    cardList(cards, progressByCard: progressByCard, selected: card)
                        .frame(width: 230)
                    Divider()
                    checklist(charges)
                }
            }
        }
        .toolbar {
            if !charges.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    let allVerified = StatementProgress(charges).isComplete
                    Button(allVerified ? "Clear All" : "Mark All Verified") {
                        charges.forEach { $0.setVerified(!allVerified) }
                        ticks &+= 1
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Done", action: done)
                    .buttonStyle(.borderedProminent)
            }
        }
        .onDisappear { saveVerification(in: context) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { saveVerification(in: context) }
        }
        .onChange(of: card) { _, _ in selection = nil }
    }

    private func cardList(
        _ cards: [SharedFinanceAccount],
        progressByCard: [SharedFinanceAccount: StatementProgress],
        selected: SharedFinanceAccount?
    ) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(cards) { card in
                    let progress = progressByCard[card] ?? StatementProgress([])
                    Button {
                        saveVerification(in: context)
                        chosenCard = card
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.name.isEmpty ? card.displayName : card.name)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            Text(progress.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ProgressView(value: progress.fraction)
                                .tint(VerifiedStyle.seal)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(card == selected ? FinanceTrackerModule.accent.color.opacity(0.18) : .clear, in: .rect(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
        }
    }

    private func checklist(_ charges: [SharedFinanceTransaction]) -> some View {
        let progress = StatementProgress(charges)
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(FinanceFormat.cents(progress.verifiedCost))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                Text("verified of \(FinanceFormat.cents(progress.totalCost)) · \(progress.verified) of \(counted(progress.total, "charge"))")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Space verifies the selected row and moves down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            Divider()
            HStack(spacing: 8) {
                Color.clear.frame(width: 44, height: 1)
                Text("Date").frame(width: Self.dateWidth, alignment: .leading)
                Text("Merchant").frame(maxWidth: .infinity, alignment: .leading)
                Text("Category").frame(width: Self.categoryWidth, alignment: .leading)
                Text("Amount").frame(width: Self.amountWidth, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            // The rows' own trailing inset plus the one the plain list adds.
            .padding(.leading, 12)
            .padding(.trailing, 21)
            .padding(.vertical, 6)
            Divider()
            List(charges, selection: $selection) { charge in
                MacStatementRow(
                    transaction: charge,
                    dateWidth: Self.dateWidth,
                    categoryWidth: Self.categoryWidth,
                    amountWidth: Self.amountWidth
                ) {
                    toggle(charge)
                }
                .tag(charge.objectID)
            }
            .listStyle(.plain)
            .focused($isListFocused)
            .onKeyPress(.space) {
                guard isEditable, let charge = selected(in: charges) else { return .ignored }
                toggle(charge)
                moveSelection(from: charge, in: charges)
                return .handled
            }
            .contextMenu(forSelectionType: NSManagedObjectID.self) { _ in
            } primaryAction: { ids in
                if let id = ids.first, let charge = charges.first(where: { $0.objectID == id }) { edit(charge) }
            }
            .onAppear {
                selection = (charges.first { !$0.isVerified } ?? charges.first)?.objectID
                isListFocused = true
            }
        }
    }

    private func toggle(_ charge: SharedFinanceTransaction) {
        charge.setVerified(!charge.isVerified)
        ticks &+= 1
    }

    private func selected(in charges: [SharedFinanceTransaction]) -> SharedFinanceTransaction? {
        selection.flatMap { id in charges.first { $0.objectID == id } }
    }

    private func moveSelection(from charge: SharedFinanceTransaction, in charges: [SharedFinanceTransaction]) {
        guard let index = charges.firstIndex(of: charge), charges.indices.contains(index + 1) else { return }
        selection = charges[index + 1].objectID
    }
}

private struct MacStatementRow: View {
    @ObservedObject var transaction: SharedFinanceTransaction
    let dateWidth: CGFloat
    let categoryWidth: CGFloat
    let amountWidth: CGFloat
    let toggle: () -> Void

    var body: some View {
        // Deleted, here or on another device, while on screen: see `isGone`.
        if !transaction.isGone { content }
    }

    private var content: some View {
        HStack(spacing: 8) {
            VerifyToggle(transaction: transaction, size: 17, toggle: toggle)
                .frame(height: 30)
            Text(transaction.date.formatted(.dateTime.month(.abbreviated).day()))
                .monospacedDigit()
                .frame(width: dateWidth, alignment: .leading)
            Text(transaction.merchant.isEmpty ? "Untitled" : transaction.merchant)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(transaction.category)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(width: categoryWidth, alignment: .leading)
            StatementAmount(transaction: transaction)
                .frame(width: amountWidth, alignment: .trailing)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 12))
        .listRowBackground(transaction.isVerified ? VerifiedStyle.rowTint : nil)
    }
}

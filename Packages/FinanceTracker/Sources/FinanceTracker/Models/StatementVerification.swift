import Foundation

/// Ticking a card's charges off against its statement.
///
/// Goes by `cost`, what the statement says, not `actualCost`: a charge split
/// with a friend is on the statement in full, so the totals here are meant to
/// differ from the Spending screen's and match the bank's.
public enum StatementVerification {
    /// The cards with something to check in `period`. Archived ones too: a card
    /// closed since still has this month's statement. Cash accounts have no
    /// statement, and a card with no charges has nothing to tick.
    public static func cards(
        among accounts: [SharedFinanceAccount],
        transactions: [SharedFinanceTransaction],
        in period: YearMonth
    ) -> [SharedFinanceAccount] {
        let charged = Set(transactions.filter { $0.counts(in: period) }.compactMap(\.card))
        return accounts.filter { $0.category == .card && charged.contains($0) }
    }

    /// A card's charges counted in `period`, in statement order, oldest first.
    /// By `counts(in:)`, never the date: an Oct statement runs into November.
    public static func charges(
        of card: SharedFinanceAccount,
        among transactions: [SharedFinanceTransaction],
        in period: YearMonth
    ) -> [SharedFinanceTransaction] {
        transactions
            .filter { $0.card == card && $0.counts(in: period) }
            .sorted { ($0.date, $0.createdAt) < ($1.date, $1.createdAt) }
    }

    /// Whether an edit makes this a different line on the statement, so whoever
    /// ticked it off didn't check what it now says. Fixing its category or
    /// who owes what changes nothing the bank printed.
    public static func editChangesStatementLine(
        of transaction: SharedFinanceTransaction,
        date: Date,
        cost: Double,
        merchant: String,
        card: SharedFinanceAccount?
    ) -> Bool {
        FinanceCalendar.dayString(transaction.date) != FinanceCalendar.dayString(date)
            || abs(transaction.cost - cost) >= 0.005
            || MerchantSuggestions.key(transaction.merchant) != MerchantSuggestions.key(merchant)
            || transaction.card != card
    }
}

/// How far through one card's statement someone is.
public struct StatementProgress: Equatable, Sendable {
    public var total = 0
    public var verified = 0
    public var totalCost = 0.0
    public var verifiedCost = 0.0

    public init(_ charges: [SharedFinanceTransaction]) {
        for charge in charges {
            total += 1
            totalCost += charge.cost
            if charge.isVerified {
                verified += 1
                verifiedCost += charge.cost
            }
        }
    }

    public var fraction: Double { total == 0 ? 0 : Double(verified) / Double(total) }
    public var isComplete: Bool { total > 0 && verified == total }
}

public extension SharedFinanceTransaction {
    var isVerified: Bool { verifiedAt != nil }

    /// Leaves an already verified one's date alone, so a repeat tick or Mark All
    /// isn't a change to sync.
    func setVerified(_ verified: Bool, asOf now: Date = .now) {
        guard verified != isVerified else { return }
        verifiedAt = verified ? now : nil
    }
}

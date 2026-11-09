import Core
import Foundation

/// What the Split face says about balances, transfers and expenses — built
/// here so the phone, the Mac column and the tests all read the same words.
public struct SplitWording: Sendable {
    public let people: TripPeople
    public let locale: Locale

    public init(people: TripPeople, locale: Locale = .current) {
        self.people = people
        self.locale = locale
    }

    func money(_ minor: Int64, _ code: String) -> String {
        TripMoney.format(minor, code: code, locale: locale)
    }

    /// The hero line for this device's user in one currency: "You're owed
    /// €38.00", "You owe €12.00", "You're square".
    public func myBalance(_ minor: Int64, code: String) -> String {
        if minor > 0 { return "You're owed \(money(minor, code))" }
        if minor < 0 { return "You owe \(money(-minor, code))" }
        return "You're square"
    }

    /// A Balances row's figure: "owed €38.00", "owes €12.00", "square".
    /// "You" takes "are owed" / "owe".
    public func balance(_ minor: Int64, code: String, isMe: Bool) -> String {
        if minor > 0 { return isMe ? "are owed \(money(minor, code))" : "is owed \(money(minor, code))" }
        if minor < 0 { return isMe ? "owe \(money(-minor, code))" : "owes \(money(-minor, code))" }
        return isMe ? "are square" : "is square"
    }

    /// "You pay Saloni €38.00", "Saloni pays you €38.00", "Alex pays Saloni
    /// €10.00".
    public func transfer(_ transfer: SettleUp.Transfer) -> String {
        let amount = money(transfer.amountMinor, transfer.currencyCode)
        let from = people.label(for: transfer.from)
        let to = isMe(transfer.to) ? "you" : people.label(for: transfer.to)
        return isMe(transfer.from) ? "You pay \(to) \(amount)" : "\(from) pays \(to) \(amount)"
    }

    /// A payment row's title: "You paid Saloni", "Saloni paid you", "Alex
    /// paid Saloni".
    public func payment(_ expense: ExpenseRecord) -> String {
        let to = expense.split.keys.first.map { isMe($0) ? "you" : people.label(for: $0) } ?? "someone"
        let from = people.label(for: expense.payer)
        return "\(from) paid \(to)"
    }

    /// An expense row's second line: "Saloni paid €236.40".
    public func paidBy(_ expense: ExpenseRecord) -> String {
        "\(people.label(for: expense.payer)) paid \(money(expense.amountMinor, expense.currencyCode))"
    }

    /// What an expense means for this device's user, for the row's trailing
    /// figure: "you lent €118.20", "you borrowed €59.10". Nil when it doesn't
    /// involve them, or nobody can tell who they are.
    public func involvement(_ involvement: ExpenseInvolvement, code: String) -> String? {
        switch involvement {
        case .notInvolved: nil
        case .lent(let minor): "you lent \(money(minor, code))"
        case .borrowed(let minor): "you borrowed \(money(minor, code))"
        case .even: "your share"
        case .paid(let minor): "you paid \(money(minor, code))"
        case .received(let minor): "you got \(money(minor, code))"
        }
    }

    /// The Mac's subtitle on Split: "€1,116.40 · 4 people", one total per
    /// currency.
    public func subtitle(ledger: TripLedger) -> String {
        let totals = ledger.currencies.compactMap { code in
            ledger.totals[code].flatMap { $0 == 0 ? nil : money($0, code) }
        }
        let count = people.roster.filter { $0.key != nil && $0.source != .pending && !$0.isHidden }.count
        return (totals + [counted(count, "person", plural: "people")]).joined(separator: " · ")
    }

    private func isMe(_ key: PersonKey) -> Bool {
        guard let me = people.me else { return false }
        return people.resolve(key) == me
    }
}

import Foundation

/// Suggested transfers that square everyone up, one currency at a time.
///
/// Greedy: the person owing most pays the person owed most, as much as
/// settles one of them, then again — at most n−1 transfers for n people with
/// a balance. Not always the fewest possible (that's NP-hard, and greedy is
/// what Splitwise does too), but always correct. Ties go by ascending key, and
/// currencies by code, so every device suggests the same transfers in the
/// same order.
public enum SettleUp {
    public struct Transfer: Identifiable, Sendable, Hashable {
        public let from: PersonKey
        public let to: PersonKey
        public let amountMinor: Int64
        public let currencyCode: String

        public init(from: PersonKey, to: PersonKey, amountMinor: Int64, currencyCode: String) {
            self.from = from
            self.to = to
            self.amountMinor = amountMinor
            self.currencyCode = currencyCode
        }

        public var id: String { "\(currencyCode):\(from.raw)>\(to.raw)" }
    }

    /// Every currency's transfers, currencies in code order.
    public static func transfers(balances: [String: [PersonKey: Int64]]) -> [Transfer] {
        balances.keys.sorted().flatMap { transfers(balances[$0] ?? [:], currencyCode: $0) }
    }

    /// One currency's transfers. Balances positive for those owed.
    public static func transfers(_ balances: [PersonKey: Int64], currencyCode: String) -> [Transfer] {
        var debtors = balances.filter { $0.value < 0 }.map { (key: $0.key, amount: -$0.value) }
        var creditors = balances.filter { $0.value > 0 }.map { (key: $0.key, amount: $0.value) }
        let largestFirst: ((key: PersonKey, amount: Int64), (key: PersonKey, amount: Int64)) -> Bool = {
            $0.amount != $1.amount ? $0.amount > $1.amount : $0.key < $1.key
        }
        var transfers: [Transfer] = []
        while !debtors.isEmpty, !creditors.isEmpty {
            debtors.sort(by: largestFirst)
            creditors.sort(by: largestFirst)
            let amount = min(debtors[0].amount, creditors[0].amount)
            transfers.append(Transfer(from: debtors[0].key, to: creditors[0].key, amountMinor: amount, currencyCode: currencyCode))
            debtors[0].amount -= amount
            creditors[0].amount -= amount
            if debtors[0].amount == 0 { debtors.removeFirst() }
            if creditors[0].amount == 0 { creditors.removeFirst() }
        }
        return transfers
    }
}

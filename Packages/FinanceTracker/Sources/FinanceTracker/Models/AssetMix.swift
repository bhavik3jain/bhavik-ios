import Foundation

/// What a month's assets are made of, largest first — the bar and the line
/// under it on the Mac Overview's Finance card.
///
/// With a single month there is no "since August" to show, and the card was
/// a net worth, a caption and a blank lower half: the least said by the
/// widest figure on the page.
public struct AssetMix: Equatable, Sendable {
    public struct Share: Equatable, Sendable, Identifiable {
        public let metric: FinanceMetric
        public let amount: Double
        /// Of the month's total assets, 0…1.
        public let fraction: Double

        public var id: FinanceMetric { metric }
    }

    /// Every asset kind with a positive balance, largest first. Empty when
    /// the month holds no assets at all.
    public let shares: [Share]

    public init(_ summary: MonthSummary) {
        let parts: [(FinanceMetric, Double)] = [
            (.cash, summary.cash),
            (.investments, summary.investments),
            (.retirement, summary.retirement),
            (.fixed, summary.fixed),
            (.metals, summary.metals),
        ]
        // Only what's there: a negative balance (an overdrawn account) has no
        // width to draw, and would make the others add up past the whole.
        let positive = parts.filter { $0.1 > 0 }
        let total = positive.reduce(0) { $0 + $1.1 }
        shares = positive
            .map { Share(metric: $0.0, amount: $0.1, fraction: total > 0 ? $0.1 / total : 0) }
            // Ties in the metric's own order, so the bar doesn't swap
            // colours from one render to the next.
            .sorted { lhs, rhs in
                lhs.amount != rhs.amount
                    ? lhs.amount > rhs.amount
                    : FinanceMetric.allCases.firstIndex(of: lhs.metric)! < FinanceMetric.allCases.firstIndex(of: rhs.metric)!
            }
    }

    /// "Investments 48% · Retirement 30% · Cash 12%" — the largest `limit`.
    public func legend(limit: Int = 3) -> String {
        shares.prefix(limit)
            .map { "\($0.metric.displayName) \(Int(($0.fraction * 100).rounded()))%" }
            .joined(separator: " · ")
    }
}

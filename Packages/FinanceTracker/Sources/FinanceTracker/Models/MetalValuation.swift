import Foundation

/// Prices for a month, per ounce, as quoted (per troy ounce). `MetalValuation`
/// applies them per regular ounce, deliberately; see there.
public struct MetalPrices: Equatable, Sendable {
    public var gold: Double
    public var silver: Double

    public init(gold: Double = 0, silver: Double = 0) {
        self.gold = gold
        self.silver = silver
    }

    public func price(for metal: MetalKind) -> Double {
        switch metal {
        case .gold: gold
        case .silver: silver
        }
    }
}

/// Weight-to-value arithmetic for gold and silver, in **regular (avoirdupois)
/// ounces** of 28.349523125 g — the ounce the user's Numbers sheet values
/// metals in, through its `CONVERT(Weight (g),"g","ozm")`, and so the ounce
/// the Numbers export (`FinanceNumbersSpec`, scripts/finance) writes.
///
/// Deliberately not what the market does. GC=F and SI=F, and every dealer,
/// quote per **troy** ounce (31.1035 g), so pricing a regular ounce at them
/// makes every metal value here ~9.7% (31.1035 / 28.349523125) above market.
/// It used to divide by the troy ounce: right against the market, but every
/// month's metals, assets and net worth then disagreed with the sheet by that
/// same 9.7%, and the user chose to match the sheet. Only grams are stored, so
/// going back is this one constant (plus the export's `--troy-fix`); no data
/// moves either way.
public enum MetalValuation {
    /// The avoirdupois ounce, exactly: what Numbers' "ozm" converts with.
    public static let gramsPerOunce = 28.349523125
    /// What metal prices are quoted in. Not used to value anything (see
    /// above); kept so the gap between the two is written down in one place.
    public static let gramsPerTroyOunce = 31.1035

    public static func ounces(grams: Double) -> Double {
        grams / gramsPerOunce
    }

    public static func grams(ounces: Double) -> Double {
        ounces * gramsPerOunce
    }

    /// A hand-set value wins; otherwise weight × that metal's price.
    public static func value(grams: Double, metal: MetalKind, manualValue: Double?, prices: MetalPrices) -> Double {
        if let manualValue { return manualValue }
        return ounces(grams: grams) * prices.price(for: metal)
    }

    /// What an item cost: its purchase value if recorded, else weight × the
    /// price paid per ounce if that was, else unknown.
    public static func cost(grams: Double, pricePaidPerOz: Double, purchaseValue: Double) -> Double? {
        if purchaseValue > 0 { return purchaseValue }
        if pricePaidPerOz > 0 { return ounces(grams: grams) * pricePaidPerOz }
        return nil
    }
}

/// The Gold & silver screen's header: what everything's worth, and how the
/// items with a known cost have done.
public struct MetalHoldings: Equatable, Sendable {
    public var value = 0.0
    /// Total cost of the items whose cost is known.
    public var paid = 0.0
    /// Current value of those same items, less `paid` — items with no cost
    /// recorded are left out rather than counted as pure gain.
    public var gain = 0.0
    public var gold = 0.0
    public var silver = 0.0

    public init() {}

    public init(_ items: [SharedFinanceMetalItem], prices: MetalPrices) {
        for item in items {
            let worth = item.value(at: prices)
            value += worth
            switch item.metal {
            case .gold: gold += worth
            case .silver: silver += worth
            }
            if let cost = item.cost {
                paid += cost
                gain += worth - cost
            }
        }
    }

    /// Every location in use with how many items are there, most-used first.
    public static func locations(_ items: [SharedFinanceMetalItem]) -> [MetalLocation] {
        var counts: [String: Int] = [:]
        for item in items {
            let location = item.location.trimmingCharacters(in: .whitespaces)
            guard !location.isEmpty else { continue }
            counts[location, default: 0] += 1
        }
        return counts
            .map { MetalLocation(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// A place metals are kept, and how many are there.
public struct MetalLocation: Identifiable, Equatable, Sendable {
    public let name: String
    public let count: Int

    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }

    public var id: String { name }
}

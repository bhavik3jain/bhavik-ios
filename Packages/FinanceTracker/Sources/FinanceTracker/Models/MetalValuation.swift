import Foundation

/// Spot prices for a month, per troy ounce.
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

/// Weight-to-value arithmetic for gold and silver. Precious metals are priced
/// per **troy** ounce (31.1035 g), not the everyday 28.35 g ounce — using the
/// wrong one undervalues everything by about 9%.
public enum MetalValuation {
    public static let gramsPerTroyOunce = 31.1035

    public static func troyOunces(grams: Double) -> Double {
        grams / gramsPerTroyOunce
    }

    public static func grams(troyOunces: Double) -> Double {
        troyOunces * gramsPerTroyOunce
    }

    /// A hand-set value wins; otherwise weight × that metal's price.
    public static func value(grams: Double, metal: MetalKind, manualValue: Double?, prices: MetalPrices) -> Double {
        if let manualValue { return manualValue }
        return troyOunces(grams: grams) * prices.price(for: metal)
    }

    /// What an item cost: its purchase value if recorded, else weight × the
    /// price paid per ounce if that was, else unknown.
    public static func cost(grams: Double, pricePaidPerOz: Double, purchaseValue: Double) -> Double? {
        if purchaseValue > 0 { return purchaseValue }
        if pricePaidPerOz > 0 { return troyOunces(grams: grams) * pricePaidPerOz }
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

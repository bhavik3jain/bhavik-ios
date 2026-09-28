import Foundation
import Observation

/// Live gold and silver prices, for the month that's still open.
///
/// Deliberately **not written into the month** as they arrive. Every save
/// of a shared month syncs, and iCloud's alert subscriptions fire on any
/// change in the household's zone — so a price stored on each refresh would
/// have sent a partner (and this person's other devices) a "Finance changed"
/// alert every time anyone opened the app. Instead the latest month, while
/// open, is *valued* at the live price everywhere (`prices(for:)`), and
/// closing it saves the prices it was showing. Closed and earlier months keep
/// their stored prices, which stay editable by hand.
@MainActor
@Observable
public final class MetalPriceFeed {
    public static let shared = MetalPriceFeed()

    /// nil until the first fetch lands, and after one fails with none before.
    public private(set) var live: MetalPrices?
    public private(set) var fetchedAt: Date?
    public private(set) var isFetching = false

    /// How old live prices may get before a screen opening refetches them.
    static let maxAge: TimeInterval = 15 * 60

    private let client: MetalQuoteClient

    public init(client: MetalQuoteClient = MetalQuoteClient()) {
        self.client = client
    }

    /// Fetches unless the prices are fresh. A failure keeps whatever was
    /// fetched before; with nothing, every month shows its stored prices.
    public func refreshIfStale(asOf now: Date = .now) async {
        if let fetchedAt, now.timeIntervalSince(fetchedAt) < Self.maxAge { return }
        await refresh()
    }

    public func refresh() async {
        guard !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        guard let prices = try? await client.latestPrices() else { return }
        live = prices
        fetchedAt = .now
    }

    /// What `month` is valued at: see `effectivePrices`.
    public func prices(for month: SharedFinanceMonth) -> MetalPrices {
        Self.effectivePrices(for: month, live: live)
    }

    /// Whether `month` shows live prices rather than its own.
    public func isLive(_ month: SharedFinanceMonth) -> Bool {
        Self.usesLivePrices(month, live: live)
    }

    /// The live prices for the household's latest month while it's open,
    /// else the month's own.
    public nonisolated static func effectivePrices(for month: SharedFinanceMonth, live: MetalPrices?) -> MetalPrices {
        guard let live, usesLivePrices(month, live: live) else { return month.metalPrices }
        return live
    }

    nonisolated static func usesLivePrices(_ month: SharedFinanceMonth, live: MetalPrices?) -> Bool {
        guard live != nil, !month.isClosed, let household = month.household else { return false }
        return household.latestMonth?.yearMonth == month.yearMonth
    }
}

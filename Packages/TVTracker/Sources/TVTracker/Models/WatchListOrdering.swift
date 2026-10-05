import Foundation

/// How a list's "To Watch" items are shown. A per-device choice
/// (`@AppStorage`), not a field on the list: one person sorting by newest
/// mustn't reorder the other's screen.
public enum WatchListOrder: String, CaseIterable, Identifiable, Sendable {
    /// The order the two of you dragged them into; new items on top.
    case custom
    /// Most recently added first.
    case newest

    /// Where this device keeps its choice, for every list at once.
    public static let defaultsKey = "tv.watchLists.order"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .custom: "Custom Order"
        case .newest: "Newest First"
        }
    }
}

/// The order of a list's items, and the arithmetic behind dragging one.
///
/// `sortIndex` is a `Double` so a move writes one item, not the whole list:
/// the moved item takes a value between its new neighbours. Renumbering every
/// item on each drag would upload every one of them and tell the partner
/// about each.
public enum WatchListOrdering {
    /// What ordering reads off an item.
    public struct Key: Sendable {
        public var sortIndex: Double
        public var addedAt: Date
        public var title: String
        public var watchedAt: Date?

        public init(sortIndex: Double, addedAt: Date, title: String, watchedAt: Date? = nil) {
            self.sortIndex = sortIndex
            self.addedAt = addedAt
            self.title = title
            self.watchedAt = watchedAt
        }
    }

    /// Still to watch, in `order`. Custom order breaks ties — two devices
    /// adding offline can pick the same index — newest first, then by title,
    /// so every device shows tied items the same way round.
    public static func toWatch<Item>(_ items: [Item], order: WatchListOrder, key: (Item) -> Key) -> [Item] {
        let keyed = items.map { (key: key($0), item: $0) }.filter { $0.key.watchedAt == nil }
        return keyed.sorted { a, b in
            switch order {
            case .custom:
                if a.key.sortIndex != b.key.sortIndex { return a.key.sortIndex < b.key.sortIndex }
                fallthrough
            case .newest:
                if a.key.addedAt != b.key.addedAt { return a.key.addedAt > b.key.addedAt }
                return a.key.title.localizedStandardCompare(b.key.title) == .orderedAscending
            }
        }.map(\.item)
    }

    /// Watched together, most recent first.
    public static func watched<Item>(_ items: [Item], key: (Item) -> Key) -> [Item] {
        items.map { (key: key($0), item: $0) }
            .compactMap { pair in pair.key.watchedAt.map { (date: $0, title: pair.key.title, item: pair.item) } }
            .sorted { a, b in
                if a.date != b.date { return a.date > b.date }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
            .map(\.item)
    }

    /// A new item's index: just above the top of the list, so it's the first
    /// thing either of you sees in custom order too.
    public static func sortIndexForNewItem(existing: [Double]) -> Double {
        (existing.min() ?? 1) - 1
    }

    /// The new `sortIndex` for each item a drag moved, keyed by its position
    /// in `sortIndexes` — the indexes of the items as currently shown, in
    /// order. Same arguments as SwiftUI's `onMove`.
    ///
    /// Usually only the moved items change, taking evenly spaced values
    /// between their new neighbours. When those neighbours share a value (two
    /// offline adds) or have no room left between them, the whole list is
    /// renumbered 0, 1, 2… and only the items whose value changes come back.
    public static func reorder(sortIndexes: [Double], moving source: IndexSet, to destination: Int) -> [Int: Double] {
        let count = sortIndexes.count
        let moving: [Int] = Array(source).filter { $0 < count }
        guard !moving.isEmpty else { return [:] }

        // `onMove`'s destination counts the moved items as still in place.
        let staying = (0..<count).filter { !source.contains($0) }
        let insertAt = destination - source.count { $0 < destination }
        let position = max(0, min(insertAt, staying.count))
        let newOrder = Array(staying[..<position]) + moving + Array(staying[position...])
        guard newOrder != Array(0..<count) else { return [:] }

        let lower = position > 0 ? sortIndexes[staying[position - 1]] : nil
        let upper = position < staying.count ? sortIndexes[staying[position]] : nil
        let steps = Double(moving.count + 1)

        var values: [Double]?
        switch (lower, upper) {
        case (nil, nil):
            values = moving.indices.map(Double.init)
        case (nil, let upper?):
            values = moving.indices.map { upper - Double(moving.count - $0) }
        case (let lower?, nil):
            values = moving.indices.map { lower + Double($0 + 1) }
        case (let lower?, let upper?):
            let gap = (upper - lower) / steps
            // Far below a Double's precision at these magnitudes would make
            // neighbours equal again; renumber well before that.
            if gap > 1e-6 {
                values = moving.indices.map { lower + gap * Double($0 + 1) }
            }
        }

        if let values {
            return Dictionary(uniqueKeysWithValues: zip(moving, values))
        }
        var renumbered: [Int: Double] = [:]
        for (rank, index) in newOrder.enumerated() where sortIndexes[index] != Double(rank) {
            renumbered[index] = Double(rank)
        }
        return renumbered
    }
}

import Core
import CoreData
import Foundation

/// What adding a title to a list did.
public enum WatchListAddOutcome {
    case added(SharedWatchListItem)
    /// Nothing was added: this is the item already on the list.
    case alreadyOnList(SharedWatchListItem)
}

public extension SharedWatchList {
    /// Adds `title` to the top of the list, unless the same title is already
    /// on it (`WatchListDuplicates.matches`) — then it says which item that
    /// is instead of adding it twice. The caller saves.
    @discardableResult
    func add(_ title: WatchListTitle, addedByName: String, asOf now: Date = .now) -> WatchListAddOutcome {
        let items = allItems
        if let index = WatchListDuplicates.firstMatch(for: title, in: items.map(\.watchListTitle)) {
            return .alreadyOnList(items[index])
        }
        let item = SharedWatchListItem(
            title: title,
            list: self,
            addedByName: addedByName.trimmingCharacters(in: .whitespacesAndNewlines),
            sortIndex: WatchListOrdering.sortIndexForNewItem(existing: items.map(\.sortIndex)),
            addedAt: now
        )
        return .added(item)
    }

    /// Still to watch, in `order`.
    func itemsToWatch(_ order: WatchListOrder) -> [SharedWatchListItem] {
        WatchListOrdering.toWatch(allItems, order: order, key: \.orderingKey)
    }

    /// Watched together, most recent first.
    var itemsWatched: [SharedWatchListItem] {
        WatchListOrdering.watched(allItems, key: \.orderingKey)
    }

    /// "4 to watch · 2 watched" — or "Nothing on it yet".
    var countsLine: String {
        let items = allItems
        guard !items.isEmpty else { return "Nothing on it yet" }
        let watched = items.count(where: \.isWatched)
        let toWatch = items.count - watched
        if watched == 0 { return "\(toWatch) to watch" }
        if toWatch == 0 { return "\(watched) watched" }
        return "\(toWatch) to watch · \(watched) watched"
    }
}

public extension SharedWatchListItem {
    var orderingKey: WatchListOrdering.Key {
        WatchListOrdering.Key(sortIndex: sortIndex, addedAt: addedAt, title: title, watchedAt: watchedAt)
    }
}

/// Moves `items` — shown in this order — the way SwiftUI's `onMove` says,
/// writing only the indexes that change. The caller saves.
func moveWatchListItems(_ items: [SharedWatchListItem], from source: IndexSet, to destination: Int) {
    let changes = WatchListOrdering.reorder(sortIndexes: items.map(\.sortIndex), moving: source, to: destination)
    for (index, value) in changes {
        items[index].sortIndex = value
    }
}

/// The words around a title on a list, as plain functions so they're tested.
public enum WatchListItemText {
    /// "Show · 2022 · Added by Saloni" — or just "Show · 2022" when nobody
    /// knows who added it, which is every item added before the list was
    /// shared.
    public static func detailLine(kind: String, addedByName: String) -> String {
        let name = addedByName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? kind : "\(kind) · Added by \(name)"
    }

    /// "Oct 3, 2026 by Saloni", or just the date.
    public static func addedLine(at date: Date, by addedByName: String) -> String {
        let day = date.formatted(date: .abbreviated, time: .omitted)
        let name = addedByName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? day : "\(day) by \(name)"
    }
}

/// Who "Added by" names on a new item.
///
/// The current user's name as the list's `CKShare` has it — read from the
/// share `SharingStatusCache` already holds for the list's badge, never
/// fetched here — or blank. Never a guess: before a list is shared there is
/// no share to ask, and an item added then says nothing about who added it.
public enum WatchListAuthorship {
    public static func name(among participants: [ShareParticipantRecord]) -> String {
        participants.first(where: \.isCurrentUser)?.displayName ?? ""
    }

    @MainActor
    public static func currentUserName(for list: SharedWatchList) -> String {
        guard let share = SharingStatusCache.shared.cachedShare(for: list.objectID) else { return "" }
        return name(among: SharedChangeAuthorResolver.participants(of: share))
    }
}

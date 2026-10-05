import Core
import CoreData
import Foundation

public extension TVTrackerModule {
    /// TV's wording for Core's shared-change notifications — see
    /// `SharedChangeNotifier`, which `BhavikApp` hands this to for the
    /// watch-list store. The root is always the list; the library is
    /// SwiftData, never shared, and never described.
    static func describeSharedChange(_ object: NSManagedObject, _ change: SharedObjectChange) -> SharedChangeDescription? {
        switch object {
        case let list as SharedWatchList:
            let action: String
            if change.kind == .inserted {
                action = "shared \(list.displayName)"
            } else if change.updatedProperties.isSubset(of: ["items"]) {
                // Only the inverse of an item being added or removed: the
                // item's own change says it better.
                return nil
            } else if change.updatedProperties.contains("name") {
                action = "renamed a list to \(list.displayName)"
            } else {
                action = "updated \(list.displayName)"
            }
            return SharedChangeDescription(rootID: list.objectID, rootTitle: list.displayName, action: action)

        case let item as SharedWatchListItem:
            guard let list = item.list else { return nil }
            let title = itemTitle(item)
            let action: String
            if change.kind == .inserted {
                action = "added \(title) to \(list.displayName)"
            } else if change.updatedProperties.isSubset(of: ["sortIndex"]) {
                // A drag in custom order. Not worth a buzz on someone's phone.
                return nil
            } else if change.updatedProperties.contains("watchedAt") {
                action = item.isWatched ? "marked \(title) watched" : "moved \(title) back to watch"
            } else if change.updatedProperties == ["note"] {
                action = item.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "removed the note on \(title)"
                    : "left a note on \(title)"
            } else {
                action = "changed \(title)"
            }
            return SharedChangeDescription(rootID: list.objectID, rootTitle: list.displayName, action: action)

        default:
            return nil
        }
    }

    private static func itemTitle(_ item: SharedWatchListItem) -> String {
        let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? (item.mediaType == .movie ? "a film" : "a show") : trimmed
    }
}

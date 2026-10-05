import CoreData
import Foundation

/// Whether a title on a watch list is a series or a film. Stored as
/// `mediaTypeRaw`, never as the enum, so a new case is not a schema change.
public enum WatchListMediaType: String, CaseIterable, Identifiable, Sendable {
    case show
    case movie

    public var id: String { rawValue }

    /// "Film", not "Movie", beside a year — "Film · 2024" — and in pickers.
    public var displayName: String {
        switch self {
        case .show: "Show"
        case .movie: "Film"
        }
    }

    public var systemImage: String {
        switch self {
        case .show: "tv"
        case .movie: "film"
        }
    }
}

/// A list of shows and films two people mean to watch together — the CKShare
/// root, so sharing one hands over every item on it and lets the other person
/// add their own. Lives in TV's own Core Data store; see `TVListModel`.
@objc(SharedWatchList)
public final class SharedWatchList: NSManagedObject, Identifiable {
    @NSManaged public var name: String
    @NSManaged public var notes: String
    @NSManaged public var createdAt: Date

    @NSManaged public var items: Set<SharedWatchListItem>?

    /// `name:` has no default on purpose: a bare `SharedWatchList(context:)`
    /// would resolve to NSManagedObject's inherited `init(context:)`, which
    /// skips this body and looks the entity up by class — see
    /// `HouseholdResolver` in Points for the log that caused.
    public convenience init(context: NSManagedObjectContext, name: String) {
        let entity = NSEntityDescription.entity(forEntityName: TVListModel.EntityName.list, in: context)!
        self.init(entity: entity, insertInto: context)
        self.name = name
        self.createdAt = .now
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedWatchList> {
        let request = NSFetchRequest<SharedWatchList>(entityName: TVListModel.EntityName.list)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

/// One show or film on a watch list.
@objc(SharedWatchListItem)
public final class SharedWatchListItem: NSManagedObject, Identifiable {
    /// TMDB's id, zero for a title typed by someone without a TMDB key. Each
    /// person looks titles up with their own key; the id is what lets
    /// "Add to My Library" and "In your library" find the same title.
    @NSManaged public var tmdbID: Int
    @NSManaged public var mediaTypeRaw: String
    @NSManaged public var title: String
    @NSManaged public var posterPath: String
    @NSManaged public var overview: String
    /// First-air or release year; zero when unknown.
    @NSManaged public var year: Int
    @NSManaged public var addedAt: Date
    /// The adder's name as the list's share knows it — blank when it
    /// doesn't, which is always the case before a list is shared.
    @NSManaged public var addedByName: String
    @NSManaged public var note: String
    /// When it was watched together; nil while it's still to watch.
    @NSManaged public var watchedAt: Date?
    /// Custom order, ascending. New items take one less than the smallest,
    /// so they land on top; see `WatchListOrdering`.
    @NSManaged public var sortIndex: Double

    @NSManaged public var list: SharedWatchList?

    /// Inserted into the list's own store: Core Data can't relate objects
    /// across stores, and a list shared with this device lives in the shared
    /// one — added to the private store, the item failed to save as a
    /// cross-store relationship.
    convenience init(title: WatchListTitle, list: SharedWatchList, addedByName: String, sortIndex: Double, addedAt: Date) {
        let context = list.managedObjectContext!
        let entity = NSEntityDescription.entity(forEntityName: TVListModel.EntityName.item, in: context)!
        self.init(entity: entity, insertInto: context)
        context.assignToStore(of: list, self)
        self.tmdbID = title.tmdbID
        self.mediaTypeRaw = title.mediaType.rawValue
        self.title = title.title
        self.posterPath = title.posterPath
        self.overview = title.overview
        self.year = title.year ?? 0
        self.addedAt = addedAt
        self.addedByName = addedByName
        self.sortIndex = sortIndex
        self.list = list
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedWatchListItem> {
        let request = NSFetchRequest<SharedWatchListItem>(entityName: TVListModel.EntityName.item)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

extension NSManagedObjectContext {
    /// Puts a new object in the same store as the one it hangs off. Left to
    /// itself Core Data puts every new object in the first store — the
    /// private one — and an item added to a list shared *with* this device
    /// would then fail to save as a cross-store relationship.
    func assignToStore(of existing: NSManagedObject, _ new: NSManagedObject) {
        // A temporary ID has no store yet; making it permanent fixes the one
        // `existing` was itself assigned to (Points hit this with an entry on
        // a just-created account).
        if existing.objectID.isTemporaryID {
            try? obtainPermanentIDs(for: [existing])
        }
        guard let store = existing.objectID.persistentStore else { return }
        assign(new, to: store)
    }
}

// MARK: - Behaviour

public extension SharedWatchList {
    var id: NSManagedObjectID { objectID }

    var allItems: [SharedWatchListItem] { Array(items ?? []) }

    /// What the list is called, or "Untitled List" for one never named.
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled List" : trimmed
    }
}

public extension SharedWatchListItem {
    var id: NSManagedObjectID { objectID }

    var mediaType: WatchListMediaType {
        get { WatchListMediaType(rawValue: mediaTypeRaw) ?? .show }
        set { mediaTypeRaw = newValue.rawValue }
    }

    var isWatched: Bool { watchedAt != nil }

    /// "Show · 2022", "Film" — the line under the title.
    var kindLine: String {
        year > 0 ? "\(mediaType.displayName) · \(year)" : mediaType.displayName
    }

    /// The title as the matching and library code sees it.
    var watchListTitle: WatchListTitle {
        WatchListTitle(
            mediaType: mediaType,
            tmdbID: tmdbID,
            title: title,
            posterPath: posterPath,
            overview: overview,
            year: year > 0 ? year : nil
        )
    }

    /// Everything folding needs, as plain values.
    var entry: WatchListEntry {
        WatchListEntry(
            title: watchListTitle,
            addedAt: addedAt,
            addedByName: addedByName,
            note: note,
            watchedAt: watchedAt,
            sortIndex: sortIndex
        )
    }

    func setWatched(_ watched: Bool, at date: Date = .now) {
        watchedAt = watched ? date : nil
    }
}

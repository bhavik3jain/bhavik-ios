import CoreData
import Foundation

/// When two titles on a watch list are the same one, and what to do about a
/// list that holds both.
///
/// By hand, because CloudKit can't have unique constraints. Adding a title
/// that's already there is refused in the add sheet (`firstMatch`); two
/// devices adding the same title offline can't see each other's, so both
/// rows arrive, and `folds` merges them when the list is next shown.
public enum WatchListDuplicates {
    /// The same kind, and then the same TMDB id when both have one, or the
    /// same title when either was typed by hand. Two TMDB titles with one
    /// name — the US and UK "The Office" — are different titles; a typed
    /// "The Office" is either, so it matches both.
    public static func matches(_ a: WatchListTitle, _ b: WatchListTitle) -> Bool {
        guard a.mediaType == b.mediaType else { return false }
        if a.isFromTMDB && b.isFromTMDB { return a.tmdbID == b.tmdbID }
        return a.normalizedTitle == b.normalizedTitle
    }

    /// The first of `existing` that is the same title as `candidate`.
    public static func firstMatch(for candidate: WatchListTitle, in existing: [WatchListTitle]) -> Int? {
        existing.firstIndex { matches($0, candidate) }
    }

    /// One set of items that are the same title: the one to keep, the ones
    /// to delete, and what the kept one should say afterwards.
    public struct Fold: Equatable, Sendable {
        public let keeper: Int
        public let duplicates: [Int]
        public let merged: WatchListEntry
    }

    /// Every set of duplicates among `entries`, as indexes into it.
    ///
    /// TMDB titles group by id and typed ones by title; a typed group then
    /// joins the TMDB group of the same kind and title, but only when there
    /// is exactly one — with two "Dune"s on the list there's no telling which
    /// film someone meant, so the typed one stays as it is.
    ///
    /// The keeper is the TMDB one if there is one, else the first added — the
    /// same choice on every device, since two of them can fold the same list
    /// at once and must not keep different rows.
    public static func folds(_ entries: [WatchListEntry]) -> [Fold] {
        var groups: [[Int]] = []
        var tmdbGroup: [String: Int] = [:]
        var typedGroup: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            let key = entry.title.id
            if entry.title.isFromTMDB {
                if let group = tmdbGroup[key] { groups[group].append(index) } else {
                    tmdbGroup[key] = groups.count
                    groups.append([index])
                }
            } else if let group = typedGroup[key] {
                groups[group].append(index)
            } else {
                typedGroup[key] = groups.count
                groups.append([index])
            }
        }

        var absorbed: Set<Int> = []
        for group in typedGroup.values.sorted() {
            let typed = entries[groups[group][0]].title
            let homes = tmdbGroup.values.sorted().filter { candidate in
                groups[candidate].contains { matches(entries[$0].title, typed) }
            }
            guard homes.count == 1, let home = homes.first else { continue }
            groups[home] += groups[group]
            absorbed.insert(group)
        }

        return groups.indices
            .filter { !absorbed.contains($0) && groups[$0].count > 1 }
            .map { fold(groups[$0], of: entries) }
    }

    private static func fold(_ members: [Int], of entries: [WatchListEntry]) -> Fold {
        // First added first; ties (two offline adds in the same instant) by
        // values every device sees alike, never by object IDs, which differ.
        let byAdded = members.sorted { lhs, rhs in
            let a = entries[lhs], b = entries[rhs]
            return (a.addedAt, a.title.title, a.addedByName, a.note, a.sortIndex, a.title.posterPath)
                < (b.addedAt, b.title.title, b.addedByName, b.note, b.sortIndex, b.title.posterPath)
        }
        let keeper = byAdded.first { entries[$0].title.isFromTMDB } ?? byAdded[0]
        let ordered = byAdded.map { entries[$0] }

        var merged = entries[keeper]
        // The first add's date *and* its adder, blank or not. Taking the
        // first name anyone left put a later adder's name on the earlier
        // add's date: "Added 30 days ago by Saloni", when she added hers two
        // days ago and nobody knows who added the first.
        merged.addedAt = ordered[0].addedAt
        merged.addedByName = ordered[0].addedByName
        var notes: [String] = []
        for note in ordered.map({ $0.note.trimmingCharacters(in: .whitespacesAndNewlines) }) where !note.isEmpty && !notes.contains(note) {
            notes.append(note)
        }
        merged.note = notes.joined(separator: "\n")
        merged.watchedAt = ordered.compactMap(\.watchedAt).min()
        merged.sortIndex = ordered.map(\.sortIndex).min() ?? merged.sortIndex
        if merged.title.posterPath.isEmpty {
            merged.title.posterPath = ordered.first { !$0.title.posterPath.isEmpty }?.title.posterPath ?? ""
        }
        if merged.title.overview.isEmpty {
            merged.title.overview = ordered.first { !$0.title.overview.isEmpty }?.title.overview ?? ""
        }
        if merged.title.year == nil {
            merged.title.year = ordered.compactMap(\.title.year).first
        }
        return Fold(keeper: keeper, duplicates: byAdded.filter { $0 != keeper }.sorted(), merged: merged)
    }
}

public extension SharedWatchList {
    /// Folds every set of duplicate items into one, keeping notes, the
    /// earliest "watched" and the earliest add. Returns how many rows went.
    /// The caller saves, and only calls this on a list it can edit.
    @discardableResult
    func foldDuplicates() -> Int {
        guard let context = managedObjectContext else { return 0 }
        let items = allItems
        var removed = 0
        for fold in WatchListDuplicates.folds(items.map(\.entry)) {
            items[fold.keeper].apply(fold.merged)
            for index in fold.duplicates {
                context.delete(items[index])
                removed += 1
            }
        }
        return removed
    }
}

extension SharedWatchListItem {
    /// Writes only what differs: every write is a CloudKit update, and an
    /// update is a notification on the partner's phone.
    func apply(_ entry: WatchListEntry) {
        func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<SharedWatchListItem, Value>, _ value: Value) {
            if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
        }
        set(\.tmdbID, entry.title.tmdbID)
        set(\.mediaTypeRaw, entry.title.mediaType.rawValue)
        set(\.title, entry.title.title)
        set(\.posterPath, entry.title.posterPath)
        set(\.overview, entry.title.overview)
        set(\.year, entry.title.year ?? 0)
        set(\.addedAt, entry.addedAt)
        set(\.addedByName, entry.addedByName)
        set(\.note, entry.note)
        set(\.watchedAt, entry.watchedAt)
        set(\.sortIndex, entry.sortIndex)
    }
}

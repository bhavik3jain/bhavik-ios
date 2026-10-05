#if DEBUG
import CoreData
import Foundation

/// Two watch lists, so the Lists tab has something in it on a fresh
/// simulator. Debug builds only, only when launched with `-TVListSeed YES`,
/// and a no-op once the list store holds any list.
///
/// "Watch Together" carries the same show twice — once from TMDB, once typed
/// by hand with a note of its own — so opening it shows the fold that two
/// devices adding the same title offline would need.
public enum WatchListDebugSeed {
    public static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "TVListSeed")
    }

    @MainActor
    public static func run(context: NSManagedObjectContext) {
        guard ((try? context.count(for: SharedWatchList.fetchRequest())) ?? 0) == 0 else { return }
        let day: TimeInterval = 86_400

        let together = SharedWatchList(context: context, name: "Watch Together")
        together.notes = "Friday nights."
        together.createdAt = .now.addingTimeInterval(-40 * day)
        let entries: [(WatchListTitle, addedDaysAgo: Double, by: String, note: String, watchedDaysAgo: Double?)] = [
            (WatchListTitle(mediaType: .show, tmdbID: 95396, title: "Severance", year: 2022), 30, "", "Season 2 first", nil),
            (WatchListTitle(mediaType: .show, tmdbID: 126308, title: "Shōgun", year: 2024), 21, "Saloni", "", nil),
            (WatchListTitle(mediaType: .movie, tmdbID: 693134, title: "Dune: Part Two", year: 2024), 12, "", "", nil),
            (WatchListTitle(mediaType: .show, tmdbID: 136315, title: "The Bear", year: 2022), 25, "Saloni", "", 10),
            (WatchListTitle(mediaType: .movie, tmdbID: 666277, title: "Past Lives", year: 2023), 35, "", "Bring tissues", 3),
        ]
        for (index, entry) in entries.enumerated() {
            let item = SharedWatchListItem(
                title: entry.0,
                list: together,
                addedByName: entry.by,
                sortIndex: Double(index),
                addedAt: .now.addingTimeInterval(-entry.addedDaysAgo * day)
            )
            item.note = entry.note
            item.watchedAt = entry.watchedDaysAgo.map { .now.addingTimeInterval(-$0 * day) }
        }
        // The second device's offline add, which the list folds when shown.
        let typed = SharedWatchListItem(
            title: WatchListTitle(mediaType: .show, title: "severance"),
            list: together,
            addedByName: "Saloni",
            sortIndex: 5,
            addedAt: .now.addingTimeInterval(-2 * day)
        )
        typed.note = "Everyone at work is talking about it"

        // Older than "Watch Together", which so tops the list and is the one
        // `-MacOpenFirstItem YES` opens.
        let films = SharedWatchList(context: context, name: "Film Club")
        films.createdAt = .now.addingTimeInterval(-60 * day)
        _ = SharedWatchListItem(
            title: WatchListTitle(mediaType: .movie, tmdbID: 872585, title: "Oppenheimer", year: 2023),
            list: films,
            addedByName: "",
            sortIndex: 0,
            addedAt: .now.addingTimeInterval(-50 * day)
        )
        try? context.save()
    }
}
#endif

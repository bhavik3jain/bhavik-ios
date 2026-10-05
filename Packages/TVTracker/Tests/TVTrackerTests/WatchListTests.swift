import Core
import CoreData
import Foundation
import SwiftData
import Testing
@testable import TVTracker

/// A fresh, uniquely-named in-memory list store per test, kept alive for the
/// test's whole body — a context doesn't retain its own container, and
/// Swift Testing runs tests in parallel, where two containers under one name
/// share a store URL.
@MainActor
private func withListContext(_ body: (NSManagedObjectContext, NSPersistentCloudKitContainer) throws -> Void) throws {
    let container = CloudSharedStore.makeContainer(
        name: "TVListTests-\(UUID().uuidString)",
        model: TVListModel.make(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
    try withExtendedLifetime(container) { try body(container.viewContext, container) }
}

@MainActor
private func makeLibraryContext() throws -> ModelContext {
    let schema = Schema(TVTrackerModule.models)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    return ModelContext(try ModelContainer(for: schema, configurations: [configuration]))
}

private let start = Date(timeIntervalSince1970: 1_750_000_000)
private func daysLater(_ days: Double) -> Date { start.addingTimeInterval(days * 86_400) }

private let severance = WatchListTitle(mediaType: .show, tmdbID: 95396, title: "Severance", year: 2022)
private let dune = WatchListTitle(mediaType: .movie, tmdbID: 693134, title: "Dune: Part Two", year: 2024)

@MainActor
private func describe(_ object: NSManagedObject, _ kind: SharedChangeKind, _ properties: Set<String> = []) -> SharedChangeDescription? {
    TVTrackerModule.describeSharedChange(object, SharedObjectChange(kind: kind, updatedProperties: properties))
}

// MARK: - The model

@MainActor
@Test func theModelLoadsWithEveryAttributeDefaultedAndBothInversesSet() throws {
    // CloudKit's rules, checked where a slip would otherwise surface: as a
    // fatalError at container load on the first launch.
    let model = TVListModel.make()
    #expect(Set(model.entities.compactMap(\.name)) == ["SharedWatchList", "SharedWatchListItem"])
    for entity in model.entities {
        #expect(entity.uniquenessConstraints.isEmpty, "\(entity.name ?? "") must not be unique — CloudKit can't")
        for attribute in entity.attributesByName.values where !attribute.isOptional {
            #expect(attribute.defaultValue != nil, "\(entity.name ?? "").\(attribute.name) needs a default")
        }
        for relationship in entity.relationshipsByName.values {
            #expect(relationship.inverseRelationship != nil, "\(entity.name ?? "").\(relationship.name) needs its inverse")
        }
    }
    try withListContext { context, _ in
        let list = SharedWatchList(context: context, name: "Watch Together")
        _ = list.add(severance, addedByName: "", asOf: start)
        try context.save()
        context.delete(list)
        try context.save()
        #expect(try context.count(for: SharedWatchListItem.fetchRequest()) == 0, "Deleting a list takes its titles with it")
    }
}

@MainActor
@Test func anUnknownMediaTypeReadsAsAShow() throws {
    try withListContext { context, _ in
        let list = SharedWatchList(context: context, name: "List")
        guard case .added(let item) = list.add(dune, addedByName: "", asOf: start) else {
            Issue.record("Expected an add")
            return
        }
        #expect(item.mediaType == .movie)
        #expect(item.kindLine == "Film · 2024")
        // A kind a later build adds, synced to this one.
        item.mediaTypeRaw = "miniseries"
        #expect(item.mediaType == .show)
        item.mediaType = .movie
        #expect(item.mediaTypeRaw == "movie")
        item.year = 0
        #expect(item.kindLine == "Film", "No year says nothing about one")
    }
}

// MARK: - Ordering

@MainActor
@Test func newTitlesGoOnTopAndWatchedOnesMoveDown() throws {
    try withListContext { context, _ in
        let list = SharedWatchList(context: context, name: "List")
        let titles = ["The Bear", "Shōgun", "Slow Horses"].map { WatchListTitle(mediaType: .show, title: $0) }
        for (index, title) in titles.enumerated() {
            _ = list.add(title, addedByName: "", asOf: daysLater(Double(index)))
        }
        #expect(list.itemsToWatch(.custom).map(\.title) == ["Slow Horses", "Shōgun", "The Bear"])
        #expect(list.itemsToWatch(.newest).map(\.title) == ["Slow Horses", "Shōgun", "The Bear"])

        let bear = try #require(list.allItems.first { $0.title == "The Bear" })
        bear.setWatched(true, at: daysLater(5))
        let shogun = try #require(list.allItems.first { $0.title == "Shōgun" })
        shogun.setWatched(true, at: daysLater(6))
        #expect(list.itemsToWatch(.custom).map(\.title) == ["Slow Horses"])
        #expect(list.itemsWatched.map(\.title) == ["Shōgun", "The Bear"], "Most recently watched first")
        #expect(list.countsLine == "1 to watch · 2 watched")
    }
}

@Test func customOrderBreaksTiesTheSameWayOnEveryDevice() {
    // Two devices adding offline can both pick index -1.
    let keys = [
        WatchListOrdering.Key(sortIndex: -1, addedAt: daysLater(1), title: "Beta"),
        WatchListOrdering.Key(sortIndex: -1, addedAt: daysLater(2), title: "Alpha"),
        WatchListOrdering.Key(sortIndex: -1, addedAt: daysLater(2), title: "Aardvark"),
        WatchListOrdering.Key(sortIndex: 0, addedAt: daysLater(9), title: "Gamma"),
    ]
    let custom = WatchListOrdering.toWatch(keys, order: .custom) { $0 }.map(\.title)
    #expect(custom == ["Aardvark", "Alpha", "Beta", "Gamma"])
    #expect(WatchListOrdering.toWatch(keys.reversed(), order: .custom) { $0 }.map(\.title) == custom)
    #expect(WatchListOrdering.toWatch(keys, order: .newest) { $0 }.map(\.title) == ["Gamma", "Aardvark", "Alpha", "Beta"])
}

@Test func draggingWritesOnlyTheMovedTitle() {
    let indexes: [Double] = [0, 1, 2, 3]
    // Last to first: one write, below the old first.
    #expect(WatchListOrdering.reorder(sortIndexes: indexes, moving: [3], to: 0) == [3: -1])
    // First to last: one write, above the old last.
    #expect(WatchListOrdering.reorder(sortIndexes: indexes, moving: [0], to: 4) == [0: 4])
    // Between two neighbours: halfway.
    #expect(WatchListOrdering.reorder(sortIndexes: indexes, moving: [3], to: 1) == [3: 0.5])
    // Dropped where it already was.
    #expect(WatchListOrdering.reorder(sortIndexes: indexes, moving: [1], to: 1).isEmpty)
    #expect(WatchListOrdering.reorder(sortIndexes: indexes, moving: [1], to: 2).isEmpty)
}

@Test func tiedNeighboursAreRenumberedRatherThanStackedOnOneValue() {
    // Two offline adds share -1; dropping between them has no room.
    let changes = WatchListOrdering.reorder(sortIndexes: [-1, -1, 0], moving: [2], to: 1)
    let order = [0, 1, 2].sorted { (changes[$0] ?? [-1, -1, 0][$0], $0) < (changes[$1] ?? [-1, -1, 0][$1], $1) }
    #expect(order == [0, 2, 1])
    #expect(Set(changes.values).count == changes.count, "Every rewritten index distinct")
}

@MainActor
@Test func movingItemsAsShownUpdatesTheirOrder() throws {
    try withListContext { context, _ in
        let list = SharedWatchList(context: context, name: "List")
        for (index, name) in ["One", "Two", "Three"].enumerated() {
            _ = list.add(WatchListTitle(mediaType: .show, title: name), addedByName: "", asOf: daysLater(Double(index)))
        }
        let shown = list.itemsToWatch(.custom)
        #expect(shown.map(\.title) == ["Three", "Two", "One"])
        moveWatchListItems(shown, from: [2], to: 0)
        #expect(list.itemsToWatch(.custom).map(\.title) == ["One", "Three", "Two"])
        #expect(list.itemsToWatch(.newest).map(\.title) == ["Three", "Two", "One"], "Newest First ignores the drag")
    }
}

// MARK: - De-duplication

@Test func theSameTitleIsTheSameIdOrTheSameName() {
    let typed = WatchListTitle(mediaType: .show, title: "  SEVERANCE ")
    #expect(WatchListDuplicates.matches(severance, typed), "Case and spaces don't count")
    #expect(WatchListDuplicates.matches(WatchListTitle(mediaType: .show, title: "Shogun"), WatchListTitle(mediaType: .show, title: "Shōgun")))
    #expect(!WatchListDuplicates.matches(severance, WatchListTitle(mediaType: .movie, title: "Severance")), "A film isn't the show")
    // The US and UK "The Office" share a name but not an id.
    let us = WatchListTitle(mediaType: .show, tmdbID: 2316, title: "The Office")
    let uk = WatchListTitle(mediaType: .show, tmdbID: 2996, title: "The Office")
    #expect(!WatchListDuplicates.matches(us, uk))
    #expect(WatchListDuplicates.matches(us, WatchListTitle(mediaType: .show, title: "the office")))
}

@MainActor
@Test func addingATitleAlreadyOnTheListSaysSoInsteadOfAddingIt() throws {
    try withListContext { context, _ in
        let list = SharedWatchList(context: context, name: "Watch Together")
        guard case .added(let first) = list.add(severance, addedByName: "Saloni", asOf: start) else {
            Issue.record("The first add should add")
            return
        }
        #expect(first.addedByName == "Saloni")
        guard case .alreadyOnList(let existing) = list.add(WatchListTitle(mediaType: .show, title: "severance"), addedByName: "", asOf: daysLater(1)) else {
            Issue.record("The second add should be refused")
            return
        }
        #expect(existing == first)
        #expect(list.allItems.count == 1)
    }
}

@Test func twoOfflineAddsFoldIntoTheFirstKeepingBothNotes() {
    let mine = WatchListEntry(title: severance, addedAt: daysLater(2), addedByName: "", note: "Season 2 first", sortIndex: -2)
    let theirs = WatchListEntry(
        title: WatchListTitle(mediaType: .show, title: "Severance"),
        addedAt: daysLater(1),
        addedByName: "Saloni",
        note: "Everyone's talking about it",
        watchedAt: daysLater(3),
        sortIndex: -1
    )
    let other = WatchListEntry(title: dune, addedAt: daysLater(1))
    let folds = WatchListDuplicates.folds([mine, other, theirs])
    #expect(folds.count == 1)
    let fold = folds[0]
    #expect(fold.keeper == 0, "The TMDB one is kept, so the poster and id stay")
    #expect(fold.duplicates == [2])
    #expect(fold.merged.title == severance)
    #expect(fold.merged.addedAt == daysLater(1), "The earliest add")
    #expect(fold.merged.addedByName == "Saloni")
    #expect(fold.merged.note == "Everyone's talking about it\nSeason 2 first")
    #expect(fold.merged.watchedAt == daysLater(3), "Watched on either device is watched")
    #expect(fold.merged.sortIndex == -2)

    // Every device must choose the same keeper, whatever order it fetched in.
    let reversed = WatchListDuplicates.folds([theirs, other, mine])
    #expect(reversed.first?.keeper == 2)
    #expect(reversed.first?.merged == fold.merged)

    // A named later add doesn't lend its name to an unnamed earlier one.
    var later = theirs
    later.addedAt = daysLater(5)
    let unnamedFirst = WatchListDuplicates.folds([mine, later])
    #expect(unnamedFirst.first?.merged.addedAt == daysLater(2))
    #expect(unnamedFirst.first?.merged.addedByName == "", "Nobody knows who added the first")
}

@Test func aTypedTitleMatchingTwoTMDBTitlesIsLeftAlone() {
    let us = WatchListEntry(title: WatchListTitle(mediaType: .show, tmdbID: 2316, title: "The Office"), addedAt: daysLater(1))
    let uk = WatchListEntry(title: WatchListTitle(mediaType: .show, tmdbID: 2996, title: "The Office"), addedAt: daysLater(2))
    let typed = WatchListEntry(title: WatchListTitle(mediaType: .show, title: "The Office"), addedAt: daysLater(3))
    #expect(WatchListDuplicates.folds([us, uk, typed]).isEmpty, "No telling which one was meant")
    let typedTwice = WatchListDuplicates.folds([typed, WatchListEntry(title: typed.title, addedAt: daysLater(4))])
    #expect(typedTwice.count == 1)
}

@MainActor
@Test func foldingAListDeletesTheCopiesAndKeepsOne() throws {
    try withListContext { context, _ in
        let list = SharedWatchList(context: context, name: "Watch Together")
        _ = list.add(severance, addedByName: "", asOf: daysLater(2))
        // The partner's offline copy, as an import would bring it in.
        let copy = SharedWatchListItem(
            title: WatchListTitle(mediaType: .show, title: "Severance"),
            list: list,
            addedByName: "Saloni",
            sortIndex: 0,
            addedAt: daysLater(1)
        )
        copy.note = "Their note"
        _ = list.add(dune, addedByName: "", asOf: daysLater(3))
        try context.save()

        #expect(list.foldDuplicates() == 1)
        try context.save()
        let kept = try #require(list.allItems.first { $0.mediaType == .show })
        #expect(list.allItems.count == 2)
        #expect(kept.tmdbID == 95396)
        #expect(kept.note == "Their note")
        #expect(kept.addedByName == "Saloni")
        #expect(list.foldDuplicates() == 0, "Nothing left to fold")
        #expect(!context.hasChanges, "A list with nothing to fold writes nothing")
    }
}

@MainActor
@Test func aTitleAddedToAListSharedWithThisDeviceStaysInTheSharedStore() throws {
    try withListContext { context, container in
        let sharedStore = try #require(container.persistentStoreCoordinator.persistentStores.first {
            $0 != container.privatePersistentStore
        })
        let theirs = SharedWatchList(context: context, name: "Saloni's")
        context.assign(theirs, to: sharedStore)
        try context.save()

        guard case .added(let item) = theirs.add(severance, addedByName: "", asOf: start) else {
            Issue.record("Expected an add")
            return
        }
        try context.save()
        #expect(item.objectID.persistentStore == sharedStore, "Core Data can't relate objects across stores")
        #expect(!WatchListOwnership.isOwn(theirs, in: container))
        #expect(WatchListOwnership.isOwn(SharedWatchList(context: context, name: "Mine"), in: container))
    }
}

// MARK: - Who added it, and the words around it

@Test func addedByIsTheCurrentUsersOwnNameOrNothing() {
    let participants = [
        ShareParticipantRecord(userRecordName: "_owner", displayName: "Bhavik", isCurrentUser: false),
        ShareParticipantRecord(userRecordName: "_saloni", displayName: "Saloni", isCurrentUser: true),
    ]
    #expect(WatchListAuthorship.name(among: participants) == "Saloni")
    #expect(WatchListAuthorship.name(among: []) == "", "No share yet: no guess")
    let unnamed = [ShareParticipantRecord(userRecordName: "_me", displayName: nil, isCurrentUser: true)]
    #expect(WatchListAuthorship.name(among: unnamed) == "")
}

@MainActor
@Test func aListNobodyHasSharedNamesNoAdder() throws {
    try withListContext { context, _ in
        let list = SharedWatchList(context: context, name: "Mine")
        try context.save()
        #expect(WatchListAuthorship.currentUserName(for: list) == "")
    }
}

@Test func itemLinesMentionTheAdderOnlyWhenKnown() {
    #expect(WatchListItemText.detailLine(kind: "Show · 2022", addedByName: "Saloni") == "Show · 2022 · Added by Saloni")
    #expect(WatchListItemText.detailLine(kind: "Film", addedByName: "  ") == "Film")
    let day = start.formatted(date: .abbreviated, time: .omitted)
    #expect(WatchListItemText.addedLine(at: start, by: "Saloni") == "\(day) by Saloni")
    #expect(WatchListItemText.addedLine(at: start, by: "") == day)
}

// MARK: - Shared-change notifications

@MainActor
@Test func aPartnersAddReadsAsAddingToTheList() throws {
    try withListContext { context, _ in
        let list = SharedWatchList(context: context, name: "Watch Together")
        guard case .added(let item) = list.add(severance, addedByName: "Saloni", asOf: start) else {
            Issue.record("Expected an add")
            return
        }
        try context.save()

        let added = try #require(describe(item, .inserted))
        #expect(added.rootID == list.objectID)
        #expect(added.rootTitle == "Watch Together")
        #expect(added.action == "added Severance to Watch Together")

        item.setWatched(true, at: start)
        #expect(describe(item, .updated, ["watchedAt"])?.action == "marked Severance watched")
        item.setWatched(false)
        #expect(describe(item, .updated, ["watchedAt"])?.action == "moved Severance back to watch")
        item.note = "Season 2 first"
        #expect(describe(item, .updated, ["note"])?.action == "left a note on Severance")
        item.note = ""
        #expect(describe(item, .updated, ["note"])?.action == "removed the note on Severance")
        #expect(describe(item, .updated, ["sortIndex"]) == nil, "A drag isn't worth a buzz")
        #expect(describe(item, .updated, ["title", "posterPath"])?.action == "changed Severance")
    }
}

@MainActor
@Test func theListItselfAndALooseTitle() throws {
    try withListContext { context, _ in
        let list = SharedWatchList(context: context, name: "Film Club")
        #expect(describe(list, .inserted)?.action == "shared Film Club")
        #expect(describe(list, .updated, ["name"])?.action == "renamed a list to Film Club")
        #expect(describe(list, .updated, ["notes"])?.action == "updated Film Club")
        #expect(describe(list, .updated, ["items"]) == nil, "The item's own change says it better")

        list.name = "  "
        #expect(describe(list, .updated, ["notes"])?.rootTitle == "Untitled List")

        let orphan = NSEntityDescription.insertNewObject(forEntityName: "SharedWatchListItem", into: context)
        #expect(describe(orphan, .inserted) == nil, "A title with no list has no root to notify about")
    }
}

// MARK: - Add to My Library

@Test func aListTitleBecomesALibraryShowOrFilm() {
    let show = TVLibrary.makeShow(WatchListTitle(mediaType: .show, tmdbID: 95396, title: "Severance", posterPath: "/sev.jpg", overview: "Work and life, split."))
    #expect(show.tmdbID == 95396)
    #expect(show.name == "Severance")
    #expect(show.posterPath == "/sev.jpg")
    #expect(show.overview == "Work and life, split.")
    #expect(show.status == .notStarted)
    #expect(TVLibrary.makeShow(WatchListTitle(mediaType: .show, title: "  ")).name == "New Show")

    let typedFilm = TVLibrary.makeMovie(WatchListTitle(mediaType: .movie, title: "Past Lives"))
    #expect(typedFilm.tmdbID == 0)
    #expect(typedFilm.releaseDate == nil, "A list keeps only the year, and a year isn't a date")

    let detail = TMDBMovieSummary(id: 693134, title: "Dune: Part Two", overview: "", posterPath: "/dune.jpg", releaseDate: daysLater(0), runtime: 166)
    let film = TVLibrary.makeMovie(WatchListTitle(mediaType: .movie, tmdbID: 693134, title: "Dune 2", overview: "Paul goes south."), detail: detail)
    #expect(film.title == "Dune: Part Two", "TMDB's own record wins")
    #expect(film.overview == "Paul goes south.", "…but not with a blank")
    #expect(film.runtime == 166)
    #expect(film.releaseDate == daysLater(0))
}

@MainActor
@Test func addToMyLibraryAddsOnceAndThenSaysItsThere() async throws {
    let library = try makeLibraryContext()
    // No key: nothing goes to the network, and a TMDB show keeps its id.
    guard case .addedShow(let show, let error) = await TVLibrary.add(severance, apiKey: "", to: library) else {
        Issue.record("Expected a show")
        return
    }
    #expect(error == nil)
    #expect(show.tmdbID == 95396)
    #expect(show.episodeCount == 0)
    try library.save()
    #expect(TVLibrary.problem(after: .addedShow(show, episodesError: nil), adding: severance, apiKey: "")?.contains("no TMDB API key") == true)
    #expect(TVLibrary.problem(after: .addedShow(show, episodesError: nil), adding: severance, apiKey: "key") == nil)

    guard case .alreadyInLibrary = await TVLibrary.add(WatchListTitle(mediaType: .show, title: "severance"), apiKey: "", to: library) else {
        Issue.record("A second copy must not be added")
        return
    }
    #expect(try library.fetchCount(FetchDescriptor<Show>()) == 1)

    guard case .addedMovie(let movie) = await TVLibrary.add(dune, apiKey: "", to: library) else {
        Issue.record("Expected a film")
        return
    }
    #expect(movie.title == "Dune: Part Two")
    #expect(try library.fetchCount(FetchDescriptor<Movie>()) == 1)
}

@MainActor
@Test func inYourLibraryMeansTheSameTitleAsTheListsOwnMatching() throws {
    let library = try makeLibraryContext()
    library.insert(Show(tmdbID: 95396, name: "Severance"))
    library.insert(Show(name: "Slow Horses"))
    library.insert(Movie(tmdbID: 693134, title: "Dune: Part Two", releaseDate: daysLater(0)))
    try library.save()
    let shows = try library.fetch(FetchDescriptor<Show>())
    let movies = try library.fetch(FetchDescriptor<Movie>())
    let index = LibraryIndex(shows: shows, movies: movies)
    let owned = shows.map(WatchListTitle.init(libraryShow:)) + movies.map(WatchListTitle.init(libraryMovie:))

    let candidates = [
        severance,
        WatchListTitle(mediaType: .show, title: "SEVERANCE"),
        WatchListTitle(mediaType: .show, tmdbID: 1, title: "Severance"),
        WatchListTitle(mediaType: .show, tmdbID: 95480, title: "Slow Horses"),
        WatchListTitle(mediaType: .show, title: "slow horses"),
        WatchListTitle(mediaType: .movie, title: "Severance"),
        dune,
        WatchListTitle(mediaType: .movie, tmdbID: 438631, title: "Dune"),
        WatchListTitle(mediaType: .show, title: "The Bear"),
    ]
    for candidate in candidates {
        let expected = owned.contains { WatchListDuplicates.matches($0, candidate) }
        #expect(index.contains(candidate) == expected, "\(candidate.id)")
    }
    #expect(index.contains(severance))
    #expect(!index.contains(WatchListTitle(mediaType: .show, tmdbID: 1, title: "Severance")), "Another show of the same name")
    #expect(index.contains(WatchListTitle(mediaType: .show, tmdbID: 95480, title: "Slow Horses")), "Added by hand, matched by name")
}

import Foundation
import Testing
@testable import TVTracker

/// Shaped exactly like a real export, down to the byte order mark the
/// first header carries. Kept small and invented rather than using a real
/// export, which is several thousand rows of someone's viewing history.
private let libraryCSV = """
\u{FEFF}type,title,original_title,year,tvdb_id,tmdb_id,favorite,list_status,added_at,for_later_at,stopped_watching_at,hidden_at
show,Criminal Minds,Criminal Minds,2005,,4614,no,watching,2023-01-04T11:12:13.000Z,,,
show,Some Dropped Show,Some Dropped Show,2011,,9999,no,stopped,2022-05-01T09:00:00.000Z,,2022-08-01T09:00:00.000Z,
movie,Spider-Man: Brand New Day,Spider-Man: Brand New Day,2026,,969681,no,following,2026-08-12T03:22:32.215Z,,,
movie,Trouble with the Curve,Trouble with the Curve,2012,,87825,no,for_later,2026-06-27T19:32:12.000Z,2026-06-27T19:32:12.000Z,
"""

private let watchesCSV = """
\u{FEFF}type,title,tvdb_id,tmdb_id,season_number,episode_number,first_watched_at,last_watched_at,plays
episode,Criminal Minds,,4614,1,1,2023-07-28T01:43:56.901Z,2023-07-28T01:43:56.901Z,1
episode,Criminal Minds,,4614,1,2,2023-07-29T01:00:00.000Z,2023-07-30T02:00:00.000Z,1
episode,Criminal Minds,,4614,0,4,2018-12-06T02:04:29.000Z,2018-12-06T02:04:29.000Z,1
movie,Spider-Man: Brand New Day,,969681,,,2026-09-01T20:00:00.000Z,2026-09-01T20:00:00.000Z,1
"""

@Test func parsesLibraryIntoShowsAndMovies() {
    let export = LibraryImporter.parse(libraryText: libraryCSV, watchesText: watchesCSV)

    #expect(export.shows.count == 2)
    #expect(export.movies.count == 2)
    #expect(export.titleCount == 4)
}

@Test func stripsTheByteOrderMarkFromTheFirstColumn() {
    // Left in place the BOM becomes part of the "type" header, so every row
    // would fall through the type switch and import nothing at all.
    let export = LibraryImporter.parse(libraryText: libraryCSV, watchesText: watchesCSV)
    #expect(export.shows.contains { $0.name == "Criminal Minds" })
}

@Test func mapsOnlyStoppedToDropped() {
    let export = LibraryImporter.parse(libraryText: libraryCSV, watchesText: watchesCSV)

    let criminalMinds = try! #require(export.shows.first { $0.tmdbID == 4614 })
    let stopped = try! #require(export.shows.first { $0.tmdbID == 9999 })

    #expect(criminalMinds.isDropped == false)
    #expect(stopped.isDropped)
}

@Test func recordsEpisodeWatchesBySeasonAndEpisode() {
    let export = LibraryImporter.parse(libraryText: libraryCSV, watchesText: watchesCSV)
    let watches = try! #require(export.episodeWatches[4614])

    #expect(watches.count == 2)
    #expect(watches[.init(season: 1, episode: 1)] != nil)
    #expect(watches[.init(season: 1, episode: 2)] != nil)
}

@Test func countsSpecialsRatherThanDroppingThemSilently() {
    // TMDB files season 0 outside the numbered seasons, so there is no episode
    // to attach these to. Reporting the count is honest; discarding it quietly
    // would make the totals look wrong for no visible reason.
    let export = LibraryImporter.parse(libraryText: libraryCSV, watchesText: watchesCSV)

    #expect(export.specialsSkipped == 1)
    #expect(export.episodeWatches[4614]?[.init(season: 0, episode: 4)] == nil)
}

@Test func prefersLastWatchedOverFirstWatched() {
    let export = LibraryImporter.parse(libraryText: libraryCSV, watchesText: watchesCSV)
    let watched = try! #require(export.episodeWatches[4614]?[.init(season: 1, episode: 2)])

    // last_watched_at is 30 July; first_watched_at is 29 July.
    let expected = try! #require(LibraryImporter.parseTimestamp("2023-07-30T02:00:00.000Z"))
    #expect(watched == expected)
}

@Test func recordsMovieWatchesSeparately() {
    let export = LibraryImporter.parse(libraryText: libraryCSV, watchesText: watchesCSV)

    #expect(export.movieWatches[969681] != nil)
    // On the watchlist but never watched.
    #expect(export.movieWatches[87825] == nil)
}

@Test func parsesTimestampsWithAndWithoutFractionalSeconds() {
    #expect(LibraryImporter.parseTimestamp("2023-07-28T01:43:56.901Z") != nil)
    #expect(LibraryImporter.parseTimestamp("2023-07-28T01:43:56Z") != nil)
    #expect(LibraryImporter.parseTimestamp("") == nil)
    #expect(LibraryImporter.parseTimestamp("not a date") == nil)
}

@Test func ignoresRowsWithoutATMDBIdentifier() {
    // Every title has to be looked up by id, so a row without one cannot be
    // imported at all.
    let library = """
    \u{FEFF}type,title,tmdb_id,list_status
    show,Nameless,,watching
    show,Fine,4614,watching
    """
    let export = LibraryImporter.parse(libraryText: library, watchesText: watchesCSV)

    #expect(export.shows.count == 1)
    #expect(export.shows.first?.tmdbID == 4614)
}

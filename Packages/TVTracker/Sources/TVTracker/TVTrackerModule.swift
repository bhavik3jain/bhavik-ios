import CoreData
import SwiftData
import SwiftUI
import Core

public enum TVTrackerModule {
    public static let accent = ModuleAccent(name: "TV", color: Color(red: 0.42, green: 0.36, blue: 0.91))

    /// The white-on-accent symbol on the hub row, the Mac sidebar tile and
    /// its Overview card.
    public static let symbolName = "tv.fill"

    /// Its tabs on the phone and, in the same order, the rows nested under it
    /// in the Mac sidebar. The first is where the module opens.
    ///
    /// Four at most: with the Home tab that's the five an iPhone tab bar
    /// shows. Lists made it six, and iOS put Lists and Settings behind a
    /// "More" tab whose own navigation bar wrapped the Lists screen's, with a
    /// stray back button above its title. So TV's settings aren't a tab: a
    /// gear on Watching, Movies and Up Next opens them on the phone
    /// (`TVSettingsToolbarLink`), and the Mac has them in its Settings window
    /// (`settingsView()`), as before.
    public static let sections = [
        ModuleSection("watching", title: "Watching", systemImage: "tv"),
        ModuleSection("movies", title: "Movies", systemImage: "film"),
        ModuleSection("upnext", title: "Up Next", systemImage: "calendar"),
        ModuleSection("lists", title: "Lists", systemImage: "list.bullet.rectangle.portrait"),
    ]

    /// Where the TMDB API key is stored. Kept in user defaults rather than the
    /// source tree so it never lands in version control.
    public static let apiKeyDefaultsKey = "tmdb.apiKey"

    public static var models: [any PersistentModel.Type] {
        [Show.self, Episode.self, Movie.self]
    }

    /// TV's settings on their own, for the Mac's Settings window. The phone
    /// reaches the same screen from a gear on Watching, Movies and Up Next — see
    /// `sections`.
    @MainActor
    public static func settingsView() -> some View {
        NavigationStack { TVSettingsView() }
            .tint(accent.color)
    }

    /// `context` and `container` are TV's watch-list store — Core Data, the
    /// one part of TV two people share (see `TVListModel`) — built in
    /// `BhavikApp.init()` and re-scoped onto the standard keys here, so the
    /// Lists tab reads `@Environment(\.managedObjectContext)` and
    /// `\.tvListPersistentContainer` as Points' views do. The library tabs
    /// read SwiftData's `\.modelContext`, which this leaves alone.
    ///
    /// `section` is the Mac sidebar's selection, which picks the section in
    /// place of a tab bar; leave it nil on the phone.
    @MainActor
    public static func rootView(
        context: NSManagedObjectContext,
        container: NSPersistentCloudKitContainer,
        section: Binding<String>? = nil
    ) -> some View {
        TVRootView(section: section)
            .environment(\.managedObjectContext, context)
            .environment(\.tvListPersistentContainer, container)
    }
}

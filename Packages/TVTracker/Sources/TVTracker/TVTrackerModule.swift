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
    public static let sections = [
        ModuleSection("watching", title: "Watching", systemImage: "tv"),
        ModuleSection("movies", title: "Movies", systemImage: "film"),
        ModuleSection("upnext", title: "Up Next", systemImage: "calendar"),
        ModuleSection("settings", title: "Settings", systemImage: "gear"),
    ]

    /// Where the TMDB API key is stored. Kept in user defaults rather than the
    /// source tree so it never lands in version control.
    public static let apiKeyDefaultsKey = "tmdb.apiKey"

    public static var models: [any PersistentModel.Type] {
        [Show.self, Episode.self, Movie.self]
    }

    /// `section` is the Mac sidebar's selection, which picks the section in
    /// place of a tab bar; leave it nil on the phone.
    @MainActor
    public static func rootView(section: Binding<String>? = nil) -> some View {
        TVRootView(section: section)
    }
}

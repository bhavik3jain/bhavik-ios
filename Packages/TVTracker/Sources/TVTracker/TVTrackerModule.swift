import SwiftData
import SwiftUI
import Core

public enum TVTrackerModule {
    public static let accent = ModuleAccent(name: "TV", color: Color(red: 0.42, green: 0.36, blue: 0.91))

    /// Where the TMDB API key is stored. Kept in user defaults rather than the
    /// source tree so it never lands in version control.
    public static let apiKeyDefaultsKey = "tmdb.apiKey"

    public static var models: [any PersistentModel.Type] {
        [Show.self, Episode.self, Movie.self]
    }

    @MainActor
    public static func rootView() -> some View {
        TVRootView()
    }
}

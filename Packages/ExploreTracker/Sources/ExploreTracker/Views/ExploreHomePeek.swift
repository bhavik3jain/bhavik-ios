import Core
import SwiftUI

public extension ExploreTrackerModule {
    /// What long-pressing Explore on the home screen shows: the newest guides,
    /// how big each is and how much of it has been tried.
    @MainActor
    static func homePeek(guides: [SharedGuide]) -> some View {
        // Pins read from the guides' own context rather than passed in, so the
        // hub doesn't need to know pins are a separate entity. A one-off read
        // is enough: a peek is built fresh each time it's opened.
        let pinDates = guides.first?.managedObjectContext.map(GuidePins.pinDates(in:)) ?? [:]
        return ExploreHomePeek(summaries: GuideSummary.all(guides, pinDates: pinDates))
    }
}

struct ExploreHomePeek: View {
    let summaries: [GuideSummary]

    var body: some View {
        ModulePeekCard(
            accent: ExploreTrackerModule.accent,
            icon: "map.fill",
            subtitle: GuideSummary.overview(summaries)
        ) {
            if summaries.isEmpty {
                PeekEmpty("No guides yet. Start one for a city or a neighbourhood.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(summaries.prefix(4)) { summary in
                        PeekRow(
                            summary.name,
                            detail: summary.peekDetail,
                            value: counted(summary.placeCount, "place"),
                            tint: ExploreTrackerModule.accent.color
                        )
                    }
                    if summaries.count > 4 {
                        PeekEmpty("and \(counted(summaries.count - 4, "more guide"))")
                    }
                }
            }
        }
    }
}

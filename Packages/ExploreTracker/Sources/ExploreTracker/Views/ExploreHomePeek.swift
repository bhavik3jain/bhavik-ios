import Core
import SwiftUI

public extension ExploreTrackerModule {
    /// What long-pressing Explore on the home screen shows: the newest guides,
    /// how big each is and how much of it has been tried.
    @MainActor
    static func homePeek(guides: [SharedGuide]) -> some View {
        ExploreHomePeek(summaries: GuideSummary.all(guides))
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

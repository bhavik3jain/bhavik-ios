import Core
import SwiftUI

public extension ExploreTrackerModule {
    /// The Mac Overview's Explore card: how many guides and places, and a bar
    /// per guide (largest first) sized by how much of the collection it holds.
    @MainActor
    static func overviewCard(guides: [SharedGuide], open: @escaping () -> Void) -> some View {
        // Counts only, so no pins needed — order doesn't change a total.
        ExploreOverviewCard(summaries: guides.map { GuideSummary.summarize($0) }, open: open)
    }
}

struct ExploreOverviewCard: View {
    let summaries: [GuideSummary]
    let open: () -> Void

    private var placeCount: Int { summaries.reduce(0) { $0 + $1.placeCount } }

    var body: some View {
        let accent = ExploreTrackerModule.accent.color
        let largest = summaries.sorted { $0.placeCount > $1.placeCount }.prefix(4)
        OverviewCard(accent: ExploreTrackerModule.accent, icon: ExploreTrackerModule.symbolName, open: open) {
            VStack(alignment: .leading, spacing: 4) {
                OverviewValue(summaries.isEmpty ? "No guides" : counted(summaries.count, "guide"))
                Text(placeCount == 0 ? "Start one for a city or a neighbourhood" : "\(counted(placeCount, "place")) saved")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 10)
                if placeCount > 0 {
                    GeometryReader { proxy in
                        let gaps = CGFloat(largest.count - 1) * 6
                        let total = CGFloat(largest.reduce(0) { $0 + max($1.placeCount, 1) })
                        HStack(spacing: 6) {
                            ForEach(Array(largest.enumerated()), id: \.element.id) { index, guide in
                                Capsule()
                                    .fill(accent.opacity([1, 0.7, 0.45, 0.25][index]))
                                    .frame(width: max(6, (proxy.size.width - gaps) * CGFloat(max(guide.placeCount, 1)) / total))
                                    .help("\(guide.name) · \(counted(guide.placeCount, "place"))")
                            }
                        }
                    }
                    .frame(height: 6)
                    .accessibilityHidden(true)
                }
            }
        }
    }
}

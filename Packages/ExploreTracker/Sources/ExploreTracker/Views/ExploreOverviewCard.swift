import Core
import CoreData
import SwiftUI

public extension ExploreTrackerModule {
    /// The Mac Overview's Explore card: how many guides and places, and a bar
    /// per guide (largest first) sized by how much of the collection it holds.
    @MainActor
    static func overviewCard(guides: [SharedGuide], open: @escaping () -> Void) -> some View {
        // Counts only, so no pins needed — order doesn't change a total.
        ExploreOverviewCard(summaries: guides.map(GuideShare.init), open: open)
    }

    /// The figure beside Explore in the Mac sidebar: every guide's places
    /// together, "256". Nil with none saved.
    @MainActor
    static func sidebarDetail(guides: [SharedGuide]) -> String? {
        let places = guides.reduce(0) { $0 + GuideShare($1).placeCount }
        return places > 0 ? String(places) : nil
    }
}

/// A guide's name and size — all the Overview and the sidebar draw.
///
/// Both used `GuideSummary.summarize`, which reads every place's category,
/// tried flag and coordinate to work out counts and a map region neither
/// shows; on every render of the sidebar, that was each click in it.
struct GuideShare: Identifiable {
    let id: NSManagedObjectID
    let name: String
    let placeCount: Int

    @MainActor
    init(_ guide: SharedGuide) {
        id = guide.objectID
        name = guide.name
        placeCount = guide.places?.count ?? 0
    }
}

struct ExploreOverviewCard: View {
    let summaries: [GuideShare]
    let open: () -> Void

    private var placeCount: Int { summaries.reduce(0) { $0 + $1.placeCount } }

    var body: some View {
        let largest = summaries.sorted { $0.placeCount > $1.placeCount }.prefix(4)
        OverviewCard(accent: ExploreTrackerModule.accent, icon: ExploreTrackerModule.symbolName, open: open) {
            if summaries.isEmpty {
                OverviewEmptyState("No guides yet", message: "Start one for a city or a neighbourhood.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    OverviewValue(String(summaries.count), unit: summaries.count == 1 ? "guide" : "guides")
                    OverviewCaption(placeCount == 0 ? "No places saved yet" : "\(counted(placeCount, "place")) saved")
                    Spacer(minLength: 10)
                    if placeCount > 0 {
                        shares(Array(largest))
                        // The bars alone said nothing without a hover: which
                        // guides they are, largest first.
                        Text(largest.prefix(3).map { "\($0.name) \($0.placeCount)" }.joined(separator: " · "))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .padding(.top, 4)
                    }
                }
            }
        }
    }

    private func shares(_ largest: [GuideShare]) -> some View {
        let accent = ExploreTrackerModule.accent.color
        return GeometryReader { proxy in
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

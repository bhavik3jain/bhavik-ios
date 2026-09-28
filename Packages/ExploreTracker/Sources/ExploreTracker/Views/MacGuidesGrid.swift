import Core
import CoreData
import SwiftUI

/// Guides on the Mac: each a card with its places on a map, in a grid —
/// the phone's rows, across a desktop window, were a thumbnail at one edge
/// and a temperature a foot away at the other.
struct MacGuidesGrid: View {
    let summaries: [GuideSummary]
    let guide: (GuideSummary) -> SharedGuide?
    let open: (SharedGuide) -> Void
    @ViewBuilder let menu: (SharedGuide, GuideSummary) -> AnyView

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(GuideSummary.overview(summaries))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250, maximum: 340), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(summaries) { summary in
                        if let guide = guide(summary) {
                            Button { open(guide) } label: {
                                MacGuideCard(summary: summary, points: guide.allPlaces.compactMap(\.point))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { menu(guide, summary) }
                        }
                    }
                }
                if summaries.contains(where: { $0.region != nil }) {
                    WeatherAttributionView()
                        .padding(.top, 8)
                }
            }
            .padding(24)
        }
    }
}

private struct MacGuideCard: View {
    let summary: GuideSummary
    let points: [GeoPoint]

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GuideMapThumbnail(region: summary.region, points: points)
                .frame(height: 140)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    GuideWeatherChip(point: summary.region?.center, compact: true)
                        .padding(6)
                        .background(.regularMaterial, in: .capsule)
                        .padding(8)
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if summary.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(ExploreTrackerModule.accent.color)
                    }
                    Text(summary.name)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(summary.detailLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(14)
        }
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.08)) }
        .shadow(color: .black.opacity(isHovered ? 0.25 : 0.1), radius: isHovered ? 12 : 4, y: isHovered ? 6 : 2)
        .scaleEffect(isHovered ? 1.01 : 1)
        .animation(.snappy(duration: 0.18), value: isHovered)
        .onHover { isHovered = $0 }
        .contentShape(.rect(cornerRadius: 16))
    }
}

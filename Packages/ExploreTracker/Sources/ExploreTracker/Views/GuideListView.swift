import Core
import CoreData
import MapKit
import SwiftUI

struct GuideListView: View {
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.explorePersistentContainer) private var container
    @Environment(\.presentShareSheet) private var presentShareSheet
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedGuide.createdAt, ascending: false)])
    private var guideResults: FetchedResults<SharedGuide>
    private var guides: [SharedGuide] { Array(guideResults) }
    /// Fetched here rather than looked up per guide so a pin made on another
    /// of this person's devices re-sorts the list the moment it's imported.
    @FetchRequest(sortDescriptors: [])
    private var pinResults: FetchedResults<GuidePin>

    @State private var showingNewGuide = false
    @State private var pendingDeletion: GuideSummary?
    @State private var opened: SharedGuide?
    @Environment(\.moduleLayout) private var layout

    private var summaries: [GuideSummary] {
        GuideSummary.all(guides, pinDates: GuidePins.earliestPinDates(pinResults))
    }
    private var pins: GuidePins { GuidePins(context: modelContext, container: container) }

    var body: some View {
        NavigationStack {
            Group {
                if guides.isEmpty {
                    ContentUnavailableView {
                        Label("No guides", systemImage: "map")
                    } description: {
                        Text("A guide is a list of places — somewhere to eat, something to see, something to do. Start one for a city or a neighbourhood.")
                    } actions: {
                        Button("New Guide") { showingNewGuide = true }
                            .primaryActionStyle(tint: ExploreTrackerModule.accent.color)
                    }
                    .scrollsForRefresh()
                } else if layout == .sidebar {
                    MacGuidesGrid(
                        summaries: summaries,
                        guide: guide(for:),
                        open: { opened = $0 }
                    ) { guide, summary in
                        AnyView(Group {
                            Button("Open", systemImage: "arrow.up.forward.app") { opened = guide }
                            pinButton(for: guide, isPinned: summary.isPinned)
                            if let container {
                                Button("Share Guide", systemImage: "person.crop.circle.badge.plus") {
                                    presentShareSheet(ShareSheetRequest(object: guide, container: container))
                                }
                            }
                            Divider()
                            Button("Delete Guide", systemImage: "trash", role: .destructive) {
                                pendingDeletion = summary
                            }
                        })
                    }
                } else {
                    List {
                        Section {
                            ForEach(summaries) { summary in
                                if let guide = guide(for: summary) {
                                    NavigationLink {
                                        GuideDetailView(guide: guide)
                                    } label: {
                                        GuideCard(guide: guide, summary: summary, points: guide.allPlaces.compactMap(\.point))
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        // Red explicitly: the module's magenta tint otherwise
                                        // wins, and delete looked like any other action.
                                        Button("Delete", systemImage: "trash", role: .destructive) {
                                            pendingDeletion = summary
                                        }
                                        .tint(.red)
                                    }
                                    .swipeActions(edge: .leading) {
                                        pinButton(for: guide, isPinned: summary.isPinned)
                                            .tint(ExploreTrackerModule.accent.color)
                                    }
                                    .contextMenu {
                                        pinButton(for: guide, isPinned: summary.isPinned)
                                        if let container {
                                            Button("Share Guide", systemImage: "person.crop.circle.badge.plus") {
                                                presentShareSheet(ShareSheetRequest(object: guide, container: container))
                                            }
                                        }
                                        Button("Delete Guide", systemImage: "trash", role: .destructive) {
                                            pendingDeletion = summary
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text(GuideSummary.overview(summaries))
                                .textCase(nil)
                        } footer: {
                            // The cards carry weather chips, and WeatherKit's terms
                            // want its credit wherever its data is shown — gated as
                            // Trips does, on there being anywhere to fetch it for.
                            if summaries.contains(where: { $0.region != nil }) {
                                WeatherAttributionView()
                            }
                        }
                    }
                }
            }
            .refreshesFromCloud()
            .navigationTitle("Guides")
            .navigationDestination(item: $opened) { GuideDetailView(guide: $0) }
            .debugOpensFirstItem { opened = guides.first }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingNewGuide = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("New guide")
                }
            }
            .sheet(isPresented: $showingNewGuide) {
                GuideFormView(guide: nil)
            }
            // A swipe can't be undone and a guide can hold dozens of places,
            // so deleting one always asks first.
            .confirmationDialog(
                deletionTitle,
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { summary in
                Button("Delete Guide", role: .destructive) {
                    if let guide = guide(for: summary) {
                        // A pin has no relationship to cascade through (see
                        // `GuidePin`), so it's removed by hand or it outlives
                        // its guide forever.
                        pins.setPinned(false, guide)
                        modelContext.delete(guide)
                        try? modelContext.saveIfNeeded()
                    }
                    pendingDeletion = nil
                }
            } message: { summary in
                Text(summary.placeCount == 0
                     ? "This guide has no places yet."
                     : "Its \(counted(summary.placeCount, "place")) will be deleted too.")
            }
        }
    }

    private var deletionTitle: String {
        pendingDeletion.map { "Delete “\($0.name)”?" } ?? "Delete guide?"
    }

    /// Offered on every guide, shared read-only ones included — a pin is this
    /// person's own record, not an edit to the guide.
    private func pinButton(for guide: SharedGuide, isPinned: Bool) -> some View {
        Button(
            isPinned ? "Unpin" : "Pin",
            systemImage: isPinned ? "pin.slash" : "pin"
        ) {
            withAnimation { pins.setPinned(!isPinned, guide) }
            try? modelContext.saveIfNeeded()
        }
    }

    private func guide(for summary: GuideSummary) -> SharedGuide? {
        guides.first { $0.objectID == summary.id }
    }
}

/// One guide in the list: a small map of its places, its name and counts, and
/// the weather there. Every guide gets the same row — the first one used to be
/// a large card purely because it was the newest, which read as featured for
/// no reason. Pinned guides sort to the top and carry a pin instead.
struct GuideCard: View {
    let guide: SharedGuide
    let summary: GuideSummary
    let points: [GeoPoint]

    @Environment(\.explorePersistentContainer) private var container
    private var sharingLabel: String? {
        guard let container else { return nil }
        return SharingStatusResolver.badgeStatus(for: guide, in: container).guideBadgeLabel
    }

    var body: some View {
        HStack(spacing: 12) {
            GuideMapThumbnail(region: summary.region, points: points)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if summary.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(ExploreTrackerModule.accent.color)
                            .accessibilityLabel("Pinned")
                    }
                    Text(summary.name)
                        .font(.headline)
                        .lineLimit(2)
                    if let sharingLabel {
                        Label(sharingLabel, systemImage: "person.2.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                }
                Text(summary.detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            GuideWeatherChip(point: summary.region?.center, compact: true)
                .fixedSize()
        }
        .padding(.vertical, 2)
    }
}

/// A still picture of where a guide's places are. The map takes no touches —
/// in a list row it would swallow the tap meant to open the guide.
struct GuideMapThumbnail: View {
    let region: GuideRegion?
    let points: [GeoPoint]

    var body: some View {
        if let region {
            Map(position: .constant(.region(region.coordinateRegion)), interactionModes: []) {
                ForEach(points, id: \.self) { point in
                    Annotation("", coordinate: point.coordinate) {
                        Circle()
                            .fill(ExploreTrackerModule.accent.color)
                            .stroke(.white, lineWidth: 1.5)
                            .frame(width: 8, height: 8)
                    }
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            ZStack {
                Rectangle().fill(.fill.tertiary)
                Image(systemName: "map")
                    .foregroundStyle(.secondary)
            }
            .accessibilityHidden(true)
        }
    }
}

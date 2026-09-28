import Core
import CoreData
import MapKit
import SwiftUI

/// Trips on the Mac: each trip a card with its destination's map, in a grid —
/// what's under way first, then what's coming, then what's done. The phone's
/// list, across a desktop window, was one thin line of text per trip in an
/// otherwise empty page.
struct MacTripsGrid: View {
    let groups: TripGroups
    let archivedCount: Int
    let now: Date
    let open: (SharedTrip) -> Void
    let canEdit: (SharedTrip) -> Bool
    let archive: (SharedTrip) -> Void
    let delete: (SharedTrip) -> Void
    let showArchived: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 18, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("In Progress", groups.inProgress)
                section("Upcoming", groups.upcoming)
                section("Finished", groups.finished)
                if archivedCount > 0 {
                    Button("Archived Trips (\(archivedCount))", systemImage: "archivebox", action: showArchived)
                        .buttonStyle(.bordered)
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ trips: [SharedTrip]) -> some View {
        if !trips.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title)
                    .font(.title3.weight(.semibold))
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(trips) { trip in
                        Button { open(trip) } label: {
                            MacTripCard(trip: trip, now: now)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Open", systemImage: "arrow.up.forward.app") { open(trip) }
                            if canEdit(trip) {
                                Divider()
                                Button("Archive", systemImage: "archivebox") { archive(trip) }
                                Button("Delete…", systemImage: "trash", role: .destructive) { delete(trip) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct MacTripCard: View {
    @ObservedObject var trip: SharedTrip
    let now: Date

    @Environment(\.tripPersistentContainer) private var container
    @State private var isHovered = false

    private var accent: Color { TripTrackerModule.accent.color }

    var body: some View {
        let dates = trip.dates
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: 130)
                .clipped()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(trip.title.isEmpty ? "Untitled trip" : trip.title)
                        .font(.headline)
                        .lineLimit(1)
                    if let label = container.flatMap({ SharingStatusResolver.badgeStatus(for: trip, in: $0).tripBadgeLabel }) {
                        Image(systemName: "person.2.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(label)
                    }
                }
                Text([trip.destination, ItineraryFormat.dateRange(dates)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(status(dates))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isUnderWay(dates) ? accent : .secondary)
                    .padding(.top, 2)
            }
            .padding(14)
        }
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isUnderWay(dates) ? accent.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: isUnderWay(dates) ? 2 : 1)
        }
        .shadow(color: .black.opacity(isHovered ? 0.25 : 0.1), radius: isHovered ? 12 : 4, y: isHovered ? 6 : 2)
        .scaleEffect(isHovered ? 1.01 : 1)
        .animation(.snappy(duration: 0.18), value: isHovered)
        .onHover { isHovered = $0 }
        .contentShape(.rect(cornerRadius: 16))
    }

    @ViewBuilder
    private var header: some View {
        if let latitude = trip.latitude, let longitude = trip.longitude {
            Map(initialPosition: .region(MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)
            )), interactionModes: [])
            .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
            .allowsHitTesting(false)
        } else {
            LinearGradient(colors: [accent.opacity(0.85), accent.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    Image(systemName: "suitcase.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white.opacity(0.9))
                }
        }
    }

    private func isUnderWay(_ dates: TripDates) -> Bool {
        let day = dates.offset(of: now)
        return day >= 0 && day < dates.dayCount
    }

    /// "Day 3 of 9", "Starts in 44 days", "Starts tomorrow", "Finished".
    private func status(_ dates: TripDates) -> String {
        let day = dates.offset(of: now)
        if day >= dates.dayCount { return "Finished" }
        if day >= 0 { return "Day \(day + 1) of \(dates.dayCount)" }
        let until = dates.daysUntilStart(asOf: now)
        return until == 1 ? "Starts tomorrow" : "Starts in \(until) days"
    }
}

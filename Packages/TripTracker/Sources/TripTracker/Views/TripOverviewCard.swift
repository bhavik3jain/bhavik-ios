import Core
import CoreData
import SwiftUI

public extension TripTrackerModule {
    /// The Mac Overview's Trips card, two columns wide: today's plan of the
    /// trip under way beside the ideas within reach of it, or else the trips
    /// coming up.
    ///
    /// `open` names the trip to open and on which face — nil opens the list.
    /// The nearby tile opens straight onto Nearby; the rest of the card onto
    /// Plan.
    @MainActor
    static func overviewCard(
        trips: [SharedTrip],
        asOf now: Date = .now,
        open: @escaping (_ trip: NSManagedObjectID?, _ section: TripSection) -> Void
    ) -> some View {
        TripOverviewCard(groups: TripGroups(trips, asOf: now), now: now, open: open)
    }
}

struct TripOverviewCard: View {
    let groups: TripGroups
    let now: Date
    let open: (NSManagedObjectID?, TripSection) -> Void

    private var current: SharedTrip? { groups.inProgress.first }

    /// "Rome & Amalfi · Day 3 of 9", or the next trip's countdown.
    private var detail: String {
        if let current {
            return [current.title, TripOverview.dayOfTrip(current.dates, asOf: now) ?? ""]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        if let next = groups.upcoming.first {
            return "\(next.title) \(TripOverview.countdown(days: next.dates.daysUntilStart(asOf: now)))"
        }
        return ""
    }

    var body: some View {
        OverviewCard(
            accent: TripTrackerModule.accent,
            icon: TripTrackerModule.symbolName,
            detail: detail,
            open: { open(current?.objectID ?? groups.upcoming.first?.objectID, .plan) }
        ) {
            if let current {
                HStack(alignment: .top, spacing: 18) {
                    today(current)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    NearbyTile(trip: current, now: now) { open(current.objectID, .nearby) }
                        .frame(width: 230)
                }
            } else if !groups.upcoming.isEmpty {
                upcoming
            } else {
                OverviewValue("No trips coming up")
            }
        }
    }

    // MARK: - A trip under way

    private func today(_ trip: SharedTrip) -> some View {
        let plan = DayPlan(trip: trip, dayIndex: trip.dates.offset(of: now))
        let next = plan.upNext(asOf: now)
        return VStack(alignment: .leading, spacing: 7) {
            caption("Today · \(now.formatted(.dateTime.weekday(.abbreviated).day().month(.wide)))")
            if plan.isEmpty {
                Text("Nothing planned for today.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            // Timed stops only: they make the day's shape. Whatever has no
            // time goes under "Up next" when it is what's next, and otherwise
            // waits on the Plan itself — the card has four lines, not a day.
            ForEach(plan.timed.prefix(4)) { entry in
                row(entry, in: plan, isNext: entry.id == next?.id)
            }
            if let next, plan.start(of: next) == nil {
                caption("Up next").padding(.top, 4)
                row(next, in: plan, isNext: true)
            }
        }
    }

    private func row(_ entry: DayPlan.Entry, in plan: DayPlan, isNext: Bool) -> some View {
        HStack(spacing: 8) {
            Text(plan.start(of: entry).map(ItineraryFormat.time) ?? "Anytime")
                .font(.system(size: 12, weight: isNext ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isNext ? .primary : .secondary)
                .frame(width: 52, alignment: .leading)
                .lineLimit(1)
            Image(systemName: entry.isDone ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(entry.isDone ? AnyShapeStyle(TripTrackerModule.accent.color) : AnyShapeStyle(.tertiary))
            Text(entry.title)
                .font(.system(size: 13, weight: isNext ? .semibold : .regular))
                .foregroundStyle(entry.isDone ? .secondary : .primary)
                .strikethrough(entry.isDone)
                .lineLimit(1)
        }
    }

    // MARK: - Nothing under way

    private var upcoming: some View {
        VStack(alignment: .leading, spacing: 10) {
            caption("Coming up")
            ForEach(groups.upcoming.prefix(4)) { trip in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(trip.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text([trip.destination, ItineraryFormat.dateRange(trip.dates)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(TripOverview.countdown(days: trip.dates.daysUntilStart(asOf: now)))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TripTrackerModule.accent.color)
                }
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(.secondary)
    }
}

/// The ideas within reach of today's stops — measured from the day's plan,
/// since the Overview never asks where the person is: only Nearby itself may
/// raise the location prompt, and only once there's something to rank.
private struct NearbyTile: View {
    let trip: SharedTrip
    let now: Date
    let open: () -> Void

    var body: some View {
        let accent = TripTrackerModule.accent.color
        let ideas = trip.ideas
        let today = trip.dates.offset(of: now)
        let nearby = NearbyIdeas.centroid(ofDay: today, in: trip).map { NearbyIdeas(ideas: ideas, from: $0) }
        let shortWalk = nearby?.groups.first { $0.bucket == .shortWalk }?.suggestions ?? []

        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Nearby ideas", systemImage: "location.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(accent)
                if ideas.isEmpty {
                    Text("No ideas saved for this trip yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if nearby == nil {
                    Text("Nothing on today's plan has a place to measure from.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text(shortWalk.isEmpty ? "None within a short walk" : "\(shortWalk.count) within a short walk")
                        .font(.system(size: 13, weight: .semibold))
                    ForEach(shortWalk.prefix(2)) { suggestion in
                        Text("\(suggestion.item.title), \(suggestion.estimate.walkingMinutes) min")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !ideas.isEmpty {
                    Text("See all \(counted(ideas.count, "idea")) →")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accent)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

import Core
import SwiftUI

public extension TripTrackerModule {
    /// What long-pressing Trips on the home screen shows: the trip under way with
    /// what's next today, or else the next trip and how far off it is.
    @MainActor
    static func homePeek(trips: [SharedTrip]) -> some View {
        TripHomePeek(groups: TripGroups(trips), now: .now)
    }
}

struct TripHomePeek: View {
    let groups: TripGroups
    let now: Date

    private var subtitle: String {
        if let current = groups.inProgress.first {
            return TripOverview.dayOfTrip(current.dates, asOf: now) ?? ""
        }
        if let next = groups.upcoming.first {
            return "Next trip \(TripOverview.countdown(days: next.dates.daysUntilStart(asOf: now)))"
        }
        return ""
    }

    var body: some View {
        ModulePeekCard(accent: TripTrackerModule.accent, icon: "suitcase.rolling.fill", subtitle: subtitle) {
            if let current = groups.inProgress.first {
                inProgress(current)
            } else if !groups.upcoming.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups.upcoming.prefix(3)) { trip in
                        PeekRow(
                            trip.title,
                            detail: [trip.destination, ItineraryFormat.dateRange(trip.dates)]
                                .filter { !$0.isEmpty }
                                .joined(separator: " · "),
                            value: TripOverview.countdown(days: trip.dates.daysUntilStart(asOf: now)),
                            tint: TripTrackerModule.accent.color
                        )
                    }
                }
            } else {
                PeekEmpty("No trips coming up.")
            }
        }
    }

    private func inProgress(_ trip: SharedTrip) -> some View {
        let dates = trip.dates
        let plan = DayPlan(trip: trip, dayIndex: dates.offset(of: now))
        return VStack(alignment: .leading, spacing: 12) {
            PeekRow(
                trip.title,
                detail: trip.destination,
                value: TripOverview.dayOfTrip(dates, asOf: now) ?? "",
                tint: TripTrackerModule.accent.color
            )
            if let next = plan.upNext(asOf: now) {
                PeekRow(
                    next.title,
                    detail: "Up next" + (plan.start(of: next).map { " · \(ItineraryFormat.time($0))" } ?? " · anytime today")
                )
            } else if plan.itemCount > 0 {
                PeekEmpty("Everything done for today.")
            } else {
                PeekEmpty("Nothing planned for today.")
            }
            if plan.itemCount > 0 {
                PeekEmpty("\(plan.doneCount) of \(counted(plan.itemCount, "thing")) done today")
            }
        }
    }
}

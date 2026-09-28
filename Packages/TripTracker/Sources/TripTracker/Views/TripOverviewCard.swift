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
        // How many are planned: the countdown itself is the headline now,
        // and saying "Dubai in 44 days" up here repeated it word for word.
        if groups.upcoming.count > 1 {
            return "\(counted(groups.upcoming.count, "trip")) planned"
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
                // A share of the card rather than a fixed 230pt: near the
                // window's minimum width the fixed tile left today's plan
                // about 100pt, and its stop titles truncated to nothing.
                GeometryReader { proxy in
                    HStack(alignment: .top, spacing: 18) {
                        today(current)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        NearbyTile(trip: current, now: now) { open(current.objectID, .nearby) }
                            .frame(width: proxy.size.width * 0.38)
                    }
                }
            } else if !groups.upcoming.isEmpty {
                upcoming
            } else {
                OverviewEmptyState("No trips coming up", message: "Plan the next one in Trips.")
            }
        }
    }

    // MARK: - A trip under way

    private func today(_ trip: SharedTrip) -> some View {
        let plan = DayPlan(trip: trip, dayIndex: trip.dates.offset(of: now))
        let next = plan.upNext(asOf: now)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top) {
                caption("Today · \(now.formatted(.dateTime.weekday(.abbreviated).day().month(.wide)))")
                Spacer(minLength: 8)
                TodayWeather(trip: trip, now: now)
            }
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

    /// The next trip as the card's headline — a countdown, like every other
    /// card's one figure — and up to two more after it. It used to list the
    /// next four under a "Coming up" caption with no figure at all, so Trips
    /// was the one card on the Overview with nothing to read at a glance.
    private var upcoming: some View {
        let next = groups.upcoming[0]
        let headline = TripOverview.countdownHeadline(days: next.dates.daysUntilStart(asOf: now))
        return VStack(alignment: .leading, spacing: 4) {
            OverviewValue(headline.value, unit: headline.unit)
            OverviewCaption([next.title, ItineraryFormat.dateRange(next.dates)].filter { !$0.isEmpty }.joined(separator: " · "))
            Spacer(minLength: 8)
            // Two, not three: with nothing under way the Trips row is the
            // same height as every other (see `OverviewGrid`), and more ran
            // past the card's foot.
            let later = groups.upcoming.dropFirst().prefix(2)
            HStack(alignment: .bottom, spacing: 28) {
                progress(of: next)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !later.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        caption("Later")
                        ForEach(later) { trip in
                            row(trip)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// "5 of 7 days planned", a bar, and the stops, ideas and flights under
    /// it — how ready the next trip is. See `TripOverview.planProgress`.
    private func progress(of trip: SharedTrip) -> some View {
        let plan = TripOverview.planProgress(
            dayIndices: (trip.items ?? []).map(\.dayIndex),
            flightCount: trip.flights?.count ?? 0,
            dayCount: trip.dates.dayCount
        )
        let accent = TripTrackerModule.accent.color
        return VStack(alignment: .leading, spacing: 7) {
            caption("Plan")
            Text("\(plan.daysPlanned) of \(counted(plan.dayCount, "day")) planned")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(accent.opacity(0.18))
                    Capsule().fill(accent)
                        .frame(width: proxy.size.width * plan.fractionPlanned)
                }
            }
            .frame(height: 6)
            .accessibilityHidden(true)
            Text(
                [
                    counted(plan.stops, "stop"),
                    counted(plan.ideas, "idea"),
                    plan.flights > 0 ? counted(plan.flights, "flight") : "",
                ]
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            )
            .font(.system(size: 12))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func row(_ trip: SharedTrip) -> some View {
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
                .monospacedDigit()
                .foregroundStyle(TripTrackerModule.accent.color)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(.secondary)
    }
}

/// "83° / 64° · Rome" beside today's caption, with Apple's attribution under
/// it as WeatherKit requires. Nothing at all when there's no forecast:
/// the live provider throws until the capability is on for the app ID, and
/// the card has to be complete without it — see `TripWeatherLoader`.
private struct TodayWeather: View {
    let trip: SharedTrip
    let now: Date

    @State private var weather: [DayWeather] = []

    var body: some View {
        let dates = trip.dates
        let today = TripForecast.byDay(weather, dates: dates, asOf: now)[safe: dates.offset(of: now)] ?? nil
        Group {
            if let today {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 5) {
                        Image(systemName: today.symbolName)
                            .symbolRenderingMode(.multicolor)
                        Text([
                            "\(WeatherFormat.temperature(today.highCelsius)) / \(WeatherFormat.temperature(today.lowCelsius))",
                            trip.destination,
                        ].filter { !$0.isEmpty }.joined(separator: " · "))
                        .monospacedDigit()
                        .lineLimit(1)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    WeatherAttributionView()
                }
            }
        }
        .loadsWeather(for: trip, into: $weather)
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

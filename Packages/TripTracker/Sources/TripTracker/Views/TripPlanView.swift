import Core
import CoreData
import SwiftUI

/// A trip's days: a strip to pick one, and that day's timeline.
struct TripPlanView: View {
    let trip: SharedTrip
    @Binding var selectedDay: Int
    let weather: [DayWeather]
    let present: (TripSheet) -> Void

    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.tripPersistentContainer) private var container

    // A read-only shared participant can't mark an item done or delete it —
    // same gate `ItemEditorView`'s own "Mark as Done"/"Delete" section already
    // applies, so tapping or swiping this row can't do the same mutation from
    // a side door.
    private var canEdit: Bool {
        guard let container else { return true }
        return SharingStatusResolver.canEdit(trip, in: container)
    }

    var body: some View {
        // Once a minute, so the NOW line and "up next" keep moving while the
        // screen sits open.
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
        // Mid-trip is exactly when a partner adds to today, and waiting on the
        // next automatic import was minutes.
        .refreshesFromCloud()
    }

    private func content(now: Date) -> some View {
        let dates = trip.dates
        let day = min(max(selectedDay, 0), dates.dayCount - 1)
        let plan = DayPlan(trip: trip, dayIndex: day)
        let forecast = TripForecast.byDay(weather, dates: dates, asOf: now)
        let upNext = plan.upNext(asOf: now)
        let nowLine = plan.nowLineIndex(asOf: now)
        let showsWeather = forecast.contains { $0 != nil }

        return List {
            Section {
                DayStrip(dates: dates, forecast: forecast, selectedDay: $selectedDay, now: now)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            Section {
                if plan.isEmpty {
                    Button {
                        present(.newItem(day: day))
                    } label: {
                        Label("Plan something for this day", systemImage: "plus.circle")
                    }
                }
                ForEach(Array(plan.timed.enumerated()), id: \.element.id) { index, entry in
                    if nowLine == index {
                        NowLine()
                    }
                    row(for: entry, in: plan, isUpNext: entry.id == upNext?.id)
                }
                if let nowLine, nowLine == plan.timed.count, !plan.timed.isEmpty {
                    NowLine()
                }
            } header: {
                DayHeader(dates: dates, day: day, weather: forecast[safe: day] ?? nil, now: now)
            }

            if !plan.untimed.isEmpty {
                Section(plan.isToday(asOf: now) ? "Anytime today" : "Anytime") {
                    ForEach(plan.untimed) { entry in
                        row(for: entry, in: plan, isUpNext: entry.id == upNext?.id)
                    }
                }
            }

            if let flight = TripOverview.nextFlight(in: trip, asOf: now) {
                Section {
                    Button {
                        present(.flight(flight))
                    } label: {
                        NextFlightCard(flight: flight, dates: dates, now: now)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(TripTrackerModule.accent.color.opacity(0.12))
                }
            }

            if showsWeather {
                Section {
                } footer: {
                    WeatherAttributionView()
                }
            }
        }
    }

    @ViewBuilder
    private func row(for entry: DayPlan.Entry, in plan: DayPlan, isUpNext: Bool) -> some View {
        switch entry {
        case .item(let item):
            TimelineRow(entry: entry, plan: plan, isUpNext: isUpNext, toggle: canEdit ? {
                withAnimation { item.toggleDone() }
                try? modelContext.saveIfNeeded()
            } : nil) {
                present(.item(item))
            }
            .swipeActions(edge: .leading) {
                if canEdit {
                    Button {
                        withAnimation { item.toggleDone() }
                        try? modelContext.saveIfNeeded()
                    } label: {
                        Label(item.isDone ? "Not done" : "Done", systemImage: item.isDone ? "arrow.uturn.backward" : "checkmark")
                    }
                    .tint(.green)
                }
            }
            .swipeActions(edge: .trailing) {
                if canEdit {
                    Button(role: .destructive) {
                        modelContext.delete(item)
                        try? modelContext.saveIfNeeded()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        case .flight(let flight):
            TimelineRow(entry: entry, plan: plan, isUpNext: isUpNext, toggle: nil) {
                present(.flight(flight))
            }
        }
    }
}

// MARK: - Day strip

/// One chip per day: weekday, date, and the day's weather — a dash until the day
/// is within the forecast.
struct DayStrip: View {
    let dates: TripDates
    let forecast: [DayWeather?]
    @Binding var selectedDay: Int
    let now: Date

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(0..<dates.dayCount, id: \.self) { index in
                        chip(index)
                            .id(index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(selectedDay, anchor: .center) }
            .onChange(of: selectedDay) { _, day in
                withAnimation { proxy.scrollTo(day, anchor: .center) }
            }
        }
    }

    private func chip(_ index: Int) -> some View {
        let date = dates.date(forDay: index)
        let isSelected = index == selectedDay
        let isPast = dates.offset(of: now) > index
        let weather = forecast[safe: index] ?? nil
        let foreground: AnyShapeStyle = isSelected ? AnyShapeStyle(.white) : (isPast ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))

        return Button {
            selectedDay = index
        } label: {
            VStack(spacing: 3) {
                Text(date, format: .dateTime.weekday(.narrow))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                Text(date, format: .dateTime.day())
                    .font(.body)
                    .fontWeight(isSelected ? .bold : .semibold)
                    .monospacedDigit()
                Group {
                    if let weather {
                        Image(systemName: weather.symbolName)
                            .symbolRenderingMode(isSelected ? .monochrome : .multicolor)
                    } else {
                        Image(systemName: "minus")
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption)
                .frame(height: 14)
                Text(weather.map { WeatherFormat.temperature($0.highCelsius) } ?? " ")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .monospacedDigit()
            }
            .foregroundStyle(foreground)
            .frame(width: 42, height: 78)
            .background(
                isSelected
                    ? AnyShapeStyle(TripTrackerModule.accent.color)
                    : (isPast ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.background)),
                in: RoundedRectangle(cornerRadius: 12)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(index: index, date: date, weather: weather))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accessibilityLabel(index: Int, date: Date, weather: DayWeather?) -> String {
        var parts = ["Day \(index + 1)", date.formatted(.dateTime.weekday(.wide).month(.wide).day())]
        if let weather {
            parts.append("\(weather.summary), high \(WeatherFormat.temperature(weather.highCelsius))")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Day header

struct DayHeader: View {
    let dates: TripDates
    let day: Int
    let weather: DayWeather?
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            if dates.offset(of: now) == day {
                Text("TODAY")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(TripTrackerModule.accent.color, in: Capsule())
            } else {
                Text("DAY \(day + 1)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(TripTrackerModule.accent.color)
            }
            Text(dates.date(forDay: day), format: .dateTime.weekday(.abbreviated).day().month(.wide))
            Spacer()
            if let weather {
                Image(systemName: weather.symbolName)
                    .symbolRenderingMode(.multicolor)
                HStack(spacing: 0) {
                    Text(WeatherFormat.temperature(weather.highCelsius))
                        .foregroundStyle(.primary)
                    Text(" / \(WeatherFormat.temperature(weather.lowCelsius))")
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
        }
        .font(.footnote)
        .fontWeight(.semibold)
        .textCase(nil)
    }
}

// MARK: - Rows

struct TimelineRow: View {
    let entry: DayPlan.Entry
    let plan: DayPlan
    let isUpNext: Bool
    /// Nil for a flight: there is nothing to tick off.
    let toggle: (() -> Void)?
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                if let start = plan.start(of: entry) {
                    Text(ItineraryFormat.time(start))
                        .font(.subheadline)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else {
                    Text("—")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                if case .item(let item) = entry, item.durationMinutes > 0 {
                    Text(ItineraryFormat.duration(minutes: item.durationMinutes))
                        .font(.caption2)
                }
            }
            .foregroundStyle(entry.isDone ? .secondary : .primary)
            .frame(width: TimelineMetrics.timeColumnWidth, alignment: .trailing)

            statusDot
                .padding(.top, 3)

            Button(action: open) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.title)
                                .fontWeight(.semibold)
                                .strikethrough(entry.isDone)
                                .foregroundStyle(entry.isDone ? .secondary : .primary)
                            if isUpNext {
                                Text("UP NEXT")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(TripTrackerModule.accent.color)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(TripTrackerModule.accent.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 6)
                    Image(systemName: symbolName)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusDot: some View {
        let accent = TripTrackerModule.accent.color
        if let toggle {
            Button(action: toggle) {
                Group {
                    if entry.isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    } else if plan.start(of: entry) == nil {
                        Image(systemName: "circle")
                            .foregroundStyle(accent)
                    } else {
                        Image(systemName: "circle.fill")
                            .foregroundStyle(accent)
                    }
                }
                .font(.subheadline)
                .frame(width: 22, height: 22)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.isDone ? "Mark not done" : "Mark done")
        } else {
            Image(systemName: "airplane.circle.fill")
                .font(.subheadline)
                .foregroundStyle(accent)
                .frame(width: 22, height: 22)
        }
    }

    private var subtitle: String {
        switch entry {
        case .item(let item):
            let parts = [item.detail, item.address].filter { !$0.isEmpty }
            if parts.isEmpty, item.startTime == nil { return "No set time" }
            return parts.joined(separator: " · ")
        case .flight(let flight):
            var parts: [String] = []
            if let arrives = flight.arrivesAt { parts.append("Arrives \(ItineraryFormat.time(arrives))") }
            if !flight.seat.isEmpty { parts.append("Seat \(flight.seat)") }
            if !flight.confirmationCode.isEmpty { parts.append(flight.confirmationCode) }
            return parts.joined(separator: " · ")
        }
    }

    private var symbolName: String {
        switch entry {
        case .item(let item): item.kind.symbolName
        case .flight: "airplane"
        }
    }
}

/// Shared by the entry rows and the NOW line so the two stay aligned.
enum TimelineMetrics {
    /// Wide enough for a 12-hour "12:30 PM". At 50pt, 12-hour locales wrapped
    /// the meridiem onto a second line — "9:30 A" over "M".
    static let timeColumnWidth: CGFloat = 66
}

struct NowLine: View {
    var body: some View {
        HStack(spacing: 6) {
            Text("NOW")
                .font(.caption2)
                .fontWeight(.bold)
                .frame(width: TimelineMetrics.timeColumnWidth, alignment: .trailing)
            Circle()
                .frame(width: 7, height: 7)
            Capsule()
                .frame(height: 2)
        }
        .foregroundStyle(TripTrackerModule.accent.color)
        .listRowSeparator(.hidden)
        .accessibilityLabel("Now")
    }
}

struct NextFlightCard: View {
    let flight: SharedFlight
    let dates: TripDates
    let now: Date

    var body: some View {
        let accent = TripTrackerModule.accent.color
        let day = flight.departsAt ?? dates.date(forDay: flight.dayIndex)
        let daysAway = max(0, dates.calendar.dateComponents([.day], from: dates.calendar.startOfDay(for: now), to: dates.calendar.startOfDay(for: day)).day ?? 0)

        HStack(spacing: 12) {
            Image(systemName: "airplane")
                .font(.title3)
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT FLIGHT · DAY \(flight.dayIndex + 1)")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(accent)
                Text(flight.headline)
                    .font(.headline)
                Text(ItineraryFormat.flightWhen(flight, dates: dates))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 0) {
                switch daysAway {
                case 0:
                    Text("today")
                        .font(.subheadline)
                        .fontWeight(.bold)
                case 1:
                    Text("tomorrow")
                        .font(.subheadline)
                        .fontWeight(.bold)
                default:
                    Text("in")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(counted(daysAway, "day"))
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(accent)
        }
        .contentShape(.rect)
    }
}

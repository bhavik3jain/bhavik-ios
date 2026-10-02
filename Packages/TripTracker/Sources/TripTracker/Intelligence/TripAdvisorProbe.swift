#if DEBUG
import Core
import CoreData
import Foundation

/// `-TripAdvisorProbe YES` (Debug): the whole engine — `PlanCheck`, the
/// `TripBrief` the model reads, a streamed review, a "Suggest Places" run and
/// the one-tap Idea — on a made-up Rome trip in an in-memory store, printed as
/// it goes. The only way to watch the real model and Apple Maps answer without
/// the UI, and without going near real trips: the app opens no real store for
/// this launch (see `BhavikApp.init`).
///
/// The same function runs in the tests against `StubTripAdvisor` and
/// `StubPlaceSearcher`, so the probe itself can't rot.
public enum TripAdvisorProbe {
    public static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "TripAdvisorProbe")
    }

    /// Anything in here turning up in the brief or a prompt is a leak.
    static let secrets = ["PROBE-DOOR-4417", "PROBE-CONF-ZX9", "PROBE-SEAT-14C", "PROBE-NOTE-QQ", "PROBE-ADDRESS-QQ"]

    /// Four days in Rome from tomorrow, with a problem of every kind the check
    /// knows: an overlap and a walk longer than its gap on a packed Day 1, a
    /// bike ride under Day 2's rain with a saved idea a short walk from it,
    /// nothing at all on Day 3, and the flight home on Day 4 — plus a booking
    /// and that flight carrying secrets that must never reach the model.
    @MainActor
    public static func makeSampleTrip(in context: NSManagedObjectContext, asOf now: Date = .now) -> (trip: SharedTrip, weather: [DayWeather?]) {
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let date = calendar.date(byAdding: .day, value: day, to: start) ?? start
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
        }

        let trip = SharedTrip(
            context: context,
            title: "Rome long weekend",
            destination: "Rome, Italy",
            startDate: start,
            endDate: calendar.date(byAdding: .day, value: 3, to: start) ?? start
        )
        trip.latitude = 41.8986
        trip.longitude = 12.4769
        trip.notes = "PROBE-NOTE-QQ"

        let stops: [(String, ItemKind, Int, Date?, Int, Double, Double)] = [
            ("Vatican Museums", .sight, 0, at(0, 9), 180, 41.9065, 12.4536),
            ("Colosseum", .sight, 0, at(0, 12, 30), 120, 41.8902, 12.4922),
            ("Borghese Gallery", .sight, 0, at(0, 14), 120, 41.9142, 12.4921),
            ("Pantheon", .sight, 0, at(0, 16, 30), 45, 41.8986, 12.4769),
            ("Trevi Fountain", .sight, 0, at(0, 17, 30), 30, 41.9009, 12.4833),
            ("Dinner at Roscioli", .food, 0, at(0, 20), 90, 41.8940, 12.4731),
            ("Appian Way bike ride", .activity, 1, at(1, 10), 240, 41.8580, 12.5160),
            ("Trastevere food walk", .food, SharedItineraryItem.unassignedDayIndex, nil, 0, 41.8897, 12.4695),
            ("Capitoline Museums", .sight, SharedItineraryItem.unassignedDayIndex, nil, 0, 41.8930, 12.4828),
            ("Catacombs of San Callisto", .sight, SharedItineraryItem.unassignedDayIndex, nil, 0, 41.8586, 12.5106),
        ]
        for (order, stop) in stops.enumerated() {
            let item = SharedItineraryItem(context: context, title: stop.0, kind: stop.1, dayIndex: stop.2, startTime: stop.3, sortOrder: order)
            item.durationMinutes = stop.4
            item.latitude = stop.5
            item.longitude = stop.6
            item.address = "PROBE-ADDRESS-QQ"
            item.detail = "PROBE-NOTE-QQ"
            item.trip = trip
        }

        let booking = SharedBooking(context: context, title: "Hotel near Piazza Navona", kind: .lodging, code: "PROBE-CONF-ZX9")
        booking.secureNote = "PROBE-DOOR-4417"
        booking.trip = trip
        let flight = SharedFlight(context: context, airlineCode: "AZ", number: "611", originCode: "FCO", destinationCode: "JFK", dayIndex: 3)
        flight.confirmationCode = "PROBE-CONF-ZX9"
        flight.seat = "PROBE-SEAT-14C"
        flight.departsAt = at(3, 18)
        flight.arrivesAt = at(3, 21, 30)
        flight.trip = trip

        let weather: [DayWeather?] = [
            DayWeather(date: at(0, 0), highCelsius: 22, lowCelsius: 13, symbolName: "sun.max", summary: "Sunny"),
            DayWeather(date: at(1, 0), highCelsius: 18, lowCelsius: 12, symbolName: "cloud.rain", summary: "Rain"),
            nil,
            nil,
        ]
        return (trip, weather)
    }

    /// Runs everything once and returns the report; `log` hears each line as
    /// it's written, so a slow model shows progress.
    ///
    /// - Parameter modelDescription: what the app knows about the model —
    ///   read there, not here, so a test with the stub never asks the system.
    @MainActor
    public static func run(
        context: NSManagedObjectContext,
        advisor: any TripAdvising,
        searcher: any PlaceSearching,
        modelDescription: String = "",
        asOf now: Date = .now,
        locale: Locale = Locale(identifier: "en_US"),
        log: (String) -> Void = { _ in }
    ) async -> String {
        var report: [String] = []
        func say(_ line: String) {
            report.append(line)
            log(line)
        }
        let clock = ContinuousClock()

        say("TripAdvisorProbe: advisor \(type(of: advisor)), availability \(advisor.availability)")
        if !modelDescription.isEmpty { say("TripAdvisorProbe: model \(modelDescription)") }

        let (trip, weather) = makeSampleTrip(in: context, asOf: now)
        let check = PlanCheck(trip: trip, weather: weather, asOf: now, locale: locale)
        say("")
        say("== PlanCheck: \(check.findings.count) findings ==")
        for finding in check.findings {
            say("- Day \(finding.dayIndex + 1) [\(finding.kind.rawValue)] \(finding.message)")
            for fix in finding.fixes { say("    fix: \(fix.title)") }
        }

        let brief = TripBrief(trip: trip, check: check, weather: weather, locale: locale)
        let prompt = brief.prompt(maxTokens: TripBrief.promptBudget(contextSize: 4_096))
        let leaked = secrets.filter(prompt.contains)
        say("")
        say("== TripBrief: \(brief.facts.count) facts, ~\(TripBrief.estimatedTokens(prompt)) tokens (estimate) ==")
        say(prompt)
        say("secrets in the brief: \(leaked.isEmpty ? "none" : leaked.joined(separator: ", "))")
        if #available(iOS 26.0, macOS 26.0, *), advisor is FoundationModelsTripAdvisor {
            say("what the model is sent: \(await FoundationModelsTripAdvisor.fittedPromptReport(for: brief))")
        }

        say("")
        say("== Review (streamed) ==")
        advisor.prewarm()
        let started = clock.now
        var firstVerdict: Duration?
        var snapshots = 0
        var last: TripReviewDraft?
        do {
            for try await draft in advisor.review(brief) {
                snapshots += 1
                if firstVerdict == nil, !(draft.verdict ?? "").isEmpty { firstVerdict = clock.now - started }
                last = draft
            }
            say("first verdict text after \(firstVerdict.map(Self.seconds) ?? "-"), complete after \(Self.seconds(clock.now - started)), \(snapshots) snapshots")
        } catch {
            say("review failed after \(Self.seconds(clock.now - started)): \(error) — the sheet would show PlanCheck's own text")
        }
        let review = PlanReview(check: check, brief: brief, draft: last)
        say("verdict: \(review.verdict ?? "(none)")")
        for entry in review.entries {
            say("- [\(entry.isWrittenByModel ? "model" : "check")] Day \(entry.finding.dayIndex + 1) \(entry.finding.kind.rawValue): \(entry.message)")
        }

        say("")
        say("== Suggest places around Day 2 (rain) ==")
        guard let request = SuggestionRequest(trip: trip, day: 1, weather: weather, locale: locale) else {
            say("no request: nowhere to search around")
            return report.joined(separator: "\n")
        }
        say("queries: \(request.queries.joined(separator: ", ")) within \(Int(request.radiusMetres)) m of \(request.center.latitude), \(request.center.longitude)")
        say("context: \(request.context)")
        let leakedContext = secrets.filter(request.context.contains)
        say("secrets in the context: \(leakedContext.isEmpty ? "none" : leakedContext.joined(separator: ", "))")
        let searchStarted = clock.now
        let outcome = await PlaceSuggester.suggest(for: request, searcher: searcher, advisor: advisor)
        say("\(outcome.suggestions.count) suggestions from \(outcome.candidateCount) candidates in \(Self.seconds(clock.now - searchStarted))")
        for section in outcome.sections {
            say("-- \(section.group.title): \(section.suggestions.count) of \(section.candidateCount), \(section.usedModel ? "picked by the model" : "nearest, no model")")
            for suggestion in section.suggestions {
                let distance = suggestion.metres.map { "\(Int($0)) m" } ?? "?"
                say("- \(suggestion.place.name) [\(suggestion.place.category ?? "no category"), \(distance)] \(suggestion.place.address)")
                if suggestion.isModelPick { say("    why: \(suggestion.why)") }
            }
        }

        say("")
        say("== A typed request, looking at Day 1 ==")
        let asked = "coffee near where I'll be in the afternoon"
        if let ask = SuggestionAsk(text: asked, trip: trip, openDay: 0) {
            say("request: \(asked)")
            let leakedAsk = secrets.filter(ask.prompt.contains)
            say("secrets in the prompt: \(leakedAsk.isEmpty ? "none" : leakedAsk.joined(separator: ", "))")
            do {
                let reading = try await advisor.readAsk(ask)
                say("read as: day \(reading.day), stops \(reading.stops), searches \(reading.searches)")
                if let resolved = ask.resolve(reading, trip: trip, weather: weather, locale: locale) {
                    say(resolved.summary)
                    let askOutcome = await PlaceSuggester.suggest(for: resolved.request, searcher: searcher, advisor: advisor)
                    for suggestion in askOutcome.suggestions {
                        let distance = suggestion.metres.map { "\(Int($0)) m" } ?? "?"
                        say("- \(suggestion.place.name) [\(suggestion.place.category ?? "no category"), \(distance)]")
                        if suggestion.isModelPick { say("    why: \(suggestion.why)") }
                    }
                } else {
                    say("nothing usable in that reading — the sheet would show the usual lists")
                }
            } catch {
                say("reading failed: \(error) — the sheet would show the usual lists")
            }
        }

        if let first = outcome.suggestions.first {
            let idea = SharedItineraryItem.add(first, to: trip, in: context)
            let ideaOrders = trip.ideas.filter { $0 !== idea }.map(\.sortOrder)
            say("")
            say("== Add to Ideas (in memory) ==")
            say("\(idea.title): dayIndex \(idea.dayIndex), sortOrder \(idea.sortOrder) (other ideas \(ideaOrders.sorted())), kind \(idea.kind.displayName), detail \"\(idea.detail)\"")
        }
        context.rollback()
        return report.joined(separator: "\n")
    }

    static func seconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.1f s", value)
    }
}
#endif

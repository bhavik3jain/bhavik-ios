import Core
import CoreData
import Foundation
import Testing
@testable import TripTracker

/// `-TripAdvisorProbe YES` is how the real model gets checked on a Mac; this
/// runs the same code against the stubs so it can't quietly stop working.
@MainActor
@Test func theProbeRunsEveryStepOnItsMadeUpTrip() async throws {
    let context = try makeContext()
    let report = await TripAdvisorProbe.run(
        context: context,
        advisor: StubTripAdvisor(),
        searcher: StubPlaceSearcher()
    )

    // A problem of every kind it was built to show.
    for kind in ["overlap", "tightTransfer", "overloaded", "weatherClash", "emptyDay", "ideaNearby"] {
        #expect(report.contains("[\(kind)]"), "no \(kind) finding")
    }
    #expect(report.contains("secrets in the brief: none"))
    #expect(report.contains("secrets in the context: none"))
    #expect(report.contains("verdict: Stub review:"))
    #expect(report.contains("[model]"))
    #expect(report.contains("picked by the model"))
    #expect(report.contains("dayIndex -1"))
    // Everything it made is thrown away again.
    #expect(try context.count(for: SharedTrip.fetchRequest()) == 0)
}

@MainActor
@Test func theProbeSaysWhenTheModelIsntThere() async throws {
    let context = try makeContext()
    let report = await TripAdvisorProbe.run(
        context: context,
        advisor: UnavailableTripAdvisor(availability: .notEnabled),
        searcher: StubPlaceSearcher()
    )

    #expect(report.contains("availability notEnabled"))
    #expect(report.contains("review failed"))
    #expect(report.contains("verdict: (none)"))
    #expect(!report.contains("[model]"))
    #expect(report.contains("nearest, no model"))
}

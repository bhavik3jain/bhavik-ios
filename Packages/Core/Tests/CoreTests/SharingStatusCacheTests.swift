import CloudKit
import Foundation
import Testing
@testable import Core

// The badge cache's rules. The lookup itself needs CloudKit and isn't run here.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Test func aBadgeIsLookedUpWhenItNeverWasAndAgainOnceStale() {
    #expect(SharingStatusCache.needsLookup(checkedAt: nil, isInFlight: false, asOf: t0))
    #expect(!SharingStatusCache.needsLookup(checkedAt: t0, isInFlight: false, asOf: t0 + 5), "Fresh: shown as is")
    #expect(SharingStatusCache.needsLookup(checkedAt: t0, isInFlight: false, asOf: t0 + SharingStatusCache.maxAge))
}

@Test func aLookupAlreadyRunningIsNeverStartedTwice() {
    // A view body asks on every redraw; without this each redraw while the
    // lookup ran would queue another behind it.
    #expect(!SharingStatusCache.needsLookup(checkedAt: nil, isInFlight: true, asOf: t0))
    #expect(!SharingStatusCache.needsLookup(checkedAt: t0, isInFlight: true, asOf: t0 + 3_600))
}

@Test func noShareReadsAsNotShared() {
    #expect(SharingStatusResolver.status(of: nil) == .notShared)
}

import Foundation
import Testing
@testable import ParcelTracker

// MARK: - Offline mapping

@Test func fedExScanCodesMapToStatuses() {
    #expect(FedExClient.status(from: "DL") == .delivered)
    #expect(FedExClient.status(from: "OD") == .outForDelivery)
    #expect(FedExClient.status(from: "DE") == .exception)
    #expect(FedExClient.status(from: "IT") == .inTransit)
    #expect(FedExClient.status(from: "dl") == .delivered, "Codes should be case insensitive")
    #expect(FedExClient.status(from: nil) == .unknown)
}

@Test func unknownScanCodesReadAsInTransitRatherThanUnknown() {
    // FedEx has more codes than are worth enumerating; a movement scan we
    // don't recognise still means the parcel is moving.
    #expect(FedExClient.status(from: "ZZ") == .inTransit)
    #expect(FedExClient.status(from: "") == .unknown)
}

@Test func fedExTimestampsParseWithAndWithoutAnOffset() {
    #expect(ISO8601Date.parse("2026-05-19T07:36:00+02:00") != nil)
    #expect(ISO8601Date.parse("2026-04-17T00:00:00+00:00") != nil)
    #expect(ISO8601Date.parse("2026-04-17T00:00:00") != nil)
    #expect(ISO8601Date.parse("2026-04-17") != nil)
    #expect(ISO8601Date.parse("not a date") == nil)
}

@Test func scanEventsCarryTheirLocationAndStatus() throws {
    let payload = ScanEvent(
        date: "2026-05-19T07:36:00+02:00",
        eventType: "OD",
        eventDescription: "On FedEx vehicle for delivery",
        derivedStatusCode: "IT",
        derivedStatus: "In transit",
        scanLocation: .init(city: "MAXEVILLE", stateOrProvinceCode: "54")
    )
    let event = try #require(FedExClient.event(payload))
    #expect(event.detail == "On FedEx vehicle for delivery")
    #expect(event.location == "MAXEVILLE, 54")
    #expect(event.status == .inTransit, "derivedStatusCode wins over the raw eventType")
}

@Test func scanEventsWithoutAUsableDateAreDropped() {
    let payload = ScanEvent(
        date: nil, eventType: "DL", eventDescription: "Delivered",
        derivedStatusCode: "DL", derivedStatus: nil, scanLocation: nil
    )
    #expect(FedExClient.event(payload) == nil, "An event with no timestamp can't be placed on a timeline")
}

// MARK: - Routing

@Test func routerRefusesCarriersItCannotTrack() async {
    let router = CarrierRouter(clients: [])
    await #expect(throws: CarrierError.notSupported(.usps)) {
        try await router.track("9400111206206406260787", carrier: .usps)
    }
}

@Test func routerReportsMissingCredentialsForTrackableCarriers() async {
    let router = CarrierRouter(clients: [])
    await #expect(throws: CarrierError.missingCredentials(.fedex)) {
        try await router.track("111111111111", carrier: .fedex)
    }
}

@Test func clientWithoutCredentialsFailsBeforeReachingTheNetwork() async {
    let client = FedExClient(apiKey: "", apiSecret: "")
    await #expect(throws: CarrierError.missingCredentials(.fedex)) {
        try await client.track("111111111111")
    }
}

// MARK: - Live

/// FedEx credentials, or nil to skip. Supply FEDEX_API_KEY and FEDEX_API_SECRET,
/// or FEDEX_KEY_FILE pointing at a file holding "key:secret".
///
/// xcodebuild does not forward environment variables into the simulator, so
/// these are set on the test runner in Xcode's scheme editor.
private var liveCredentials: (key: String, secret: String)? {
    let environment = ProcessInfo.processInfo.environment
    if let key = environment["FEDEX_API_KEY"], let secret = environment["FEDEX_API_SECRET"],
       !key.isEmpty, !secret.isEmpty {
        return (key, secret)
    }
    guard let path = environment["FEDEX_KEY_FILE"],
          let contents = try? String(contentsOfFile: path, encoding: .utf8)
    else { return nil }
    let parts = contents.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
    guard parts.count == 2 else { return nil }
    return (String(parts[0]), String(parts[1]))
}

@Test(.enabled(if: liveCredentials != nil, "Set FEDEX_KEY_FILE to run live FedEx tests"))
func liveFedExReadsADeliveredParcel() async throws {
    let credentials = liveCredentials!
    let client = FedExClient(apiKey: credentials.key, apiSecret: credentials.secret)

    // FedEx publishes this number as a documentation sample.
    let result = try await client.track("111111111111")
    #expect(result.status == .delivered)
    #expect(!result.events.isEmpty, "A delivered parcel should carry scan history")

    // FedEx stamps the delivery and the out-for-delivery scan to the same
    // minute, so the carrier's ordering has to settle which came last.
    #expect(result.events.chronological.last?.status == .delivered)
    #expect(result.events.contains { !$0.location.isEmpty }, "Scans should carry locations")
}

@Test(.enabled(if: liveCredentials != nil, "Set FEDEX_KEY_FILE to run live FedEx tests"))
func liveFedExRejectsBadCredentials() async {
    let client = FedExClient(apiKey: "not-a-real-key", apiSecret: "not-a-real-secret")
    await #expect(throws: CarrierError.unauthorized) {
        try await client.track("111111111111")
    }
}

@Test(.enabled(if: liveCredentials != nil, "Set FEDEX_KEY_FILE to run live FedEx tests"))
func liveFedExReportsAnUnknownNumberAsNotFound() async throws {
    let credentials = liveCredentials!
    let client = FedExClient(apiKey: credentials.key, apiSecret: credentials.secret)

    // Correct shape, but not a real parcel.
    await #expect(throws: CarrierError.self) {
        try await client.track("999999999993")
    }
}

// MARK: - Event ordering

@Test func carrierOrderingDecidesBetweenScansSharingATimestamp() {
    // Taken from FedEx's own response for tracking number 111111111111: the
    // delivery and the out-for-delivery scan are stamped to the same minute,
    // and FedEx lists newest first.
    let sameMoment = Date(timeIntervalSince1970: 1_779_000_000)
    let events = [
        TrackingEvent(occurredAt: sameMoment, detail: "Delivered", location: "", status: .delivered, sequence: 0),
        TrackingEvent(occurredAt: sameMoment, detail: "On vehicle", location: "", status: .inTransit, sequence: 1),
        TrackingEvent(occurredAt: sameMoment.addingTimeInterval(-86_400), detail: "Dropped off", location: "", status: .inTransit, sequence: 2)
    ]

    let ordered = events.chronological
    #expect(ordered.first?.detail == "Dropped off")
    #expect(ordered.last?.status == .delivered, "Sorting by date alone would leave 'On vehicle' last")
}

@Test func chronologicalOrderingIsStillDateFirst() {
    let old = TrackingEvent(occurredAt: .distantPast, detail: "old", location: "", status: .pending, sequence: 0)
    let new = TrackingEvent(occurredAt: .distantFuture, detail: "new", location: "", status: .delivered, sequence: 99)
    #expect([new, old].chronological.map(\.detail) == ["old", "new"])
}

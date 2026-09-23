import Foundation
import Testing
@testable import Core

private let known = ["trips", "explore", "gym", "tv", "parcels", "fuel"]

// MARK: - Default

@Test func theDefaultLayoutShowsEveryTrackerInItsGivenOrder() {
    let layout = TrackerLayout.default(for: known)
    #expect(layout.order == known)
    #expect(layout.visible == known)
    #expect(layout.hidden.isEmpty)
}

// MARK: - Resolving

@Test func resolvingDropsTrackersThatNoLongerExist() {
    let stored = TrackerLayout(order: ["gym", "retired", "trips"], hidden: ["retired", "trips"])
    let layout = stored.resolved(against: ["trips", "gym"])
    #expect(layout.order == ["gym", "trips"])
    #expect(layout.hidden == ["trips"], "A hidden ID for a dropped tracker shouldn't linger")
}

@Test func resolvingAppendsNewTrackersAtTheEndVisible() {
    // Written by a build that predates Explore and Fuel.
    let stored = TrackerLayout(order: ["tv", "trips", "gym", "parcels"], hidden: ["gym"])
    let layout = stored.resolved(against: known)
    #expect(layout.order == ["tv", "trips", "gym", "parcels", "explore", "fuel"])
    #expect(layout.visible == ["tv", "trips", "parcels", "explore", "fuel"])
}

@Test func resolvingDedupesTheStoredOrder() {
    let stored = TrackerLayout(order: ["gym", "tv", "gym"])
    #expect(stored.resolved(against: ["tv", "gym"]).order == ["gym", "tv"])
}

@Test func resolvingNeverLeavesEveryTrackerHidden() {
    // The only visible tracker was one this build no longer has.
    let stored = TrackerLayout(order: ["retired", "tv", "gym"], hidden: ["tv", "gym"])
    let layout = stored.resolved(against: ["tv", "gym"])
    #expect(layout.visible == ["tv"])
}

@Test func resolvingAnEmptyLayoutGivesTheDefault() {
    #expect(TrackerLayout(order: []).resolved(against: known) == .default(for: known))
}

// MARK: - Moving

@Test func movingDownUsesOnMoveOffsets() {
    var layout = TrackerLayout.default(for: known)
    // SwiftUI reports dragging "trips" below "gym" as toOffset 3: an offset
    // into the list before the move.
    layout.move(fromOffsets: [0], toOffset: 3)
    #expect(layout.order == ["explore", "gym", "trips", "tv", "parcels", "fuel"])
}

@Test func movingUp() {
    var layout = TrackerLayout.default(for: known)
    layout.move(fromOffsets: [5], toOffset: 1)
    #expect(layout.order == ["trips", "fuel", "explore", "gym", "tv", "parcels"])
}

@Test func movingToTheEnd() {
    var layout = TrackerLayout.default(for: known)
    layout.move(fromOffsets: [1], toOffset: known.count)
    #expect(layout.order == ["trips", "gym", "tv", "parcels", "fuel", "explore"])
}

@Test func movingSeveralAtOnceKeepsTheirRelativeOrder() {
    var layout = TrackerLayout.default(for: known)
    layout.move(fromOffsets: [0, 2], toOffset: 5)
    #expect(layout.order == ["explore", "tv", "parcels", "trips", "gym", "fuel"])
}

@Test func movingOntoItselfChangesNothing() {
    var layout = TrackerLayout.default(for: known)
    layout.move(fromOffsets: [2], toOffset: 2)
    layout.move(fromOffsets: [2], toOffset: 3)
    #expect(layout.order == known)
}

@Test func movingOutOfRangeOffsetsIsIgnored() {
    var layout = TrackerLayout.default(for: known)
    layout.move(fromOffsets: [42], toOffset: 0)
    #expect(layout.order == known)
}

@Test func movingAHiddenTrackerKeepsItHidden() {
    var layout = TrackerLayout.default(for: known)
    layout.setHidden(true, for: "gym")
    layout.move(fromOffsets: [2], toOffset: 0)
    #expect(layout.order.first == "gym")
    #expect(layout.isHidden("gym"))
    #expect(layout.visible.first == "trips")
}

// MARK: - Hiding

@Test func hidingAndShowingATracker() {
    var layout = TrackerLayout.default(for: known)
    layout.setHidden(true, for: "tv")
    #expect(layout.isHidden("tv"))
    #expect(layout.visible == ["trips", "explore", "gym", "parcels", "fuel"])
    #expect(layout.order == known, "Hiding keeps the tracker's place in the order")

    layout.setHidden(false, for: "tv")
    #expect(!layout.isHidden("tv"))
    #expect(layout.visible == known)
}

@Test func hidingAnUnknownTrackerIsIgnored() {
    var layout = TrackerLayout.default(for: known)
    layout.setHidden(true, for: "retired")
    #expect(layout.hidden.isEmpty)
}

@Test func theLastVisibleTrackerCantBeHidden() {
    var layout = TrackerLayout.default(for: ["trips", "gym"])
    #expect(layout.canHide("trips"))
    layout.setHidden(true, for: "trips")

    #expect(!layout.canHide("gym"))
    layout.setHidden(true, for: "gym")
    #expect(layout.visible == ["gym"])
    #expect(!layout.canHide("trips"), "Already hidden")
}

// MARK: - Codable

@Test func aLayoutSurvivesAJSONRoundTrip() throws {
    var layout = TrackerLayout.default(for: known)
    layout.move(fromOffsets: [4], toOffset: 0)
    layout.setHidden(true, for: "gym")
    layout.setHidden(true, for: "fuel")

    let data = try JSONEncoder().encode(layout)
    let decoded = try JSONDecoder().decode(TrackerLayout.self, from: data)
    #expect(decoded == layout)
}

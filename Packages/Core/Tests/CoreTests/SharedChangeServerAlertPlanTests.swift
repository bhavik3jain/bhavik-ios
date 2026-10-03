import CloudKit
import Foundation
import Testing
@testable import Core

// MARK: - IDs

private let tripZone = "com.apple.coredata.cloudkit.share.7A1C2D3E-0000-4000-8000-00000000A001"
private let carZone = "com.apple.coredata.cloudkit.share.7A1C2D3E-0000-4000-8000-00000000B002"

@Test func zoneIDsRoundTripThroughParse() {
    let id = SharedChangeServerAlertID.zone(moduleID: "trips", zoneName: tripZone)
    #expect(id.hasPrefix(SharedChangeServerAlertID.prefix))
    #expect(SharedChangeServerAlertID.parse(id) == .zone(moduleID: "trips", zoneName: tripZone), "The zone name's own dots survive")
    #expect(SharedChangeServerAlertID.parse(SharedChangeServerAlertID.shared) == .shared)
}

@Test func foreignSubscriptionIDsAreNotOurs() {
    #expect(SharedChangeServerAlertID.parse("com.apple.coredata.cloudkit.private.subscription") == nil)
    #expect(SharedChangeServerAlertID.parse("com.apple.coredata.cloudkit.shared.subscription") == nil)
    #expect(SharedChangeServerAlertID.parse("multitrack.alert.zone.trips") == nil, "No zone name")
    #expect(SharedChangeServerAlertID.parse("multitrack.alert.zone..zone") == nil, "No module")
}

@Test func alertSubscriptionsNeverCarryACollapseID() throws {
    // CloudKit refuses a subscription with one: "cannot add collapseId to
    // this subscription type". With it, no iCloud alert was ever saved.
    let participant = try #require(SharedChangeServerAlerts.subscription(for: SharedChangeServerAlertPlan.participantAlert))
    #expect(participant is CKDatabaseSubscription)
    #expect(participant.notificationInfo?.collapseIDKey == nil)
    #expect(participant.notificationInfo?.alertBody == SharedChangeServerAlertText.participantBody)

    let zone = SharedChangeServerAlert(
        id: SharedChangeServerAlertID.zone(moduleID: "finance", zoneName: tripZone),
        database: .owned,
        zoneName: tripZone,
        zoneOwnerName: "__defaultOwner__",
        title: SharedChangeServerAlertText.title,
        body: SharedChangeServerAlertText.ownerBody(rootTitle: "Household"),
        category: SharedChangeServerAlertText.category
    )
    let owned = try #require(SharedChangeServerAlerts.subscription(for: zone))
    #expect(owned is CKRecordZoneSubscription)
    #expect(owned.notificationInfo?.collapseIDKey == nil)
    #expect(owned.notificationInfo?.shouldSendContentAvailable == false, "Visible alert only")
}

@Test func aPassThatWasRefusedSaysWhy() {
    let plan = SharedChangeServerAlertPlan(save: [SharedChangeServerAlertPlan.participantAlert, SharedChangeServerAlertPlan.participantAlert])
    #expect(SharedChangeServerAlerts.passSummary(plan: plan, mode: .reconcile, failures: []) == "Saved 2, deleted 0 (set up)")
    let refused = SharedChangeServerAlerts.passSummary(plan: plan, mode: .reconcile, failures: ["cannot add collapseId to this subscription type"])
    #expect(refused == "1 of 2 changes made (set up). iCloud refused 1: cannot add collapseId to this subscription type")
    #expect(SharedChangeServerAlerts.passSummary(plan: SharedChangeServerAlertPlan(), mode: .maintain, failures: []).hasPrefix("Up to date"))
}

@Test func aTappedAlertOpensItsTracker() {
    let zone = SharedChangeServerAlertID.zone(moduleID: "fuel", zoneName: carZone)
    #expect(SharedChangeServerAlertID.moduleToOpen(subscriptionID: zone, participatingModuleIDs: []) == "fuel")
    #expect(SharedChangeServerAlertID.moduleToOpen(subscriptionID: SharedChangeServerAlertID.shared, participatingModuleIDs: ["points"]) == "points")
    #expect(SharedChangeServerAlertID.moduleToOpen(subscriptionID: SharedChangeServerAlertID.shared, participatingModuleIDs: ["points", "trips"]) == nil,
            "Can't tell which of two trackers changed")
    #expect(SharedChangeServerAlertID.moduleToOpen(subscriptionID: nil, participatingModuleIDs: ["trips"]) == nil)
}

// MARK: - Text

@Test func theOwnersAlertNamesTheRoot() {
    #expect(SharedChangeServerAlertText.ownerBody(rootTitle: "Rome & Amalfi") == "Rome & Amalfi was updated")
    #expect(SharedChangeServerAlertText.ownerBody(rootTitle: "a trip") == "A trip was updated", "A describer's fallback starts a sentence")
    #expect(SharedChangeServerAlertText.ownerBody(rootTitle: "  ") == "Something you share was updated")
    #expect(SharedChangeServerAlertText.ownerBody(rootTitle: "iPhone photos") == "iPhone photos was updated", "A real name is left alone")
}

@Test func aVeryLongNameIsShortened() {
    let body = SharedChangeServerAlertText.ownerBody(rootTitle: String(repeating: "x", count: 500))
    #expect(body.count == SharedChangeServerAlertText.maximumTitleLength + " was updated".count)
}

// MARK: - Plan

private func zone(_ module: String, _ name: String, _ title: String, others: Bool = true) -> SharedZoneAlertSource {
    SharedZoneAlertSource(
        moduleID: module,
        moduleName: module.capitalized,
        zoneName: name,
        zoneOwnerName: "__defaultOwner__",
        rootTitle: title,
        hasOthers: others
    )
}

private let rome = zone("trips", tripZone, "Rome & Amalfi")
private let car = zone("fuel", carZone, "My X3")

@Test func reconcileCreatesOneAlertPerSharedZoneAndOneForTheSharedDatabase() {
    let inputs = SharedChangeServerAlertInputs(ownedZones: [rome, car], participatingModuleIDs: ["points"])
    let plan = SharedChangeServerAlertPlan.make(mode: .reconcile, inputs: inputs, existing: [])
    #expect(plan.delete.isEmpty)
    #expect(plan.save.map(\.id) == [
        SharedChangeServerAlertID.zone(moduleID: "fuel", zoneName: carZone),
        SharedChangeServerAlertID.zone(moduleID: "trips", zoneName: tripZone),
        SharedChangeServerAlertID.shared,
    ])
    let trip = plan.save[1]
    #expect(trip.database == .owned)
    #expect(trip.zoneName == tripZone)
    #expect(trip.title == "Multitrack")
    #expect(trip.subtitle == "Trips")
    #expect(trip.body == "Rome & Amalfi was updated")
    #expect(trip.category == SharedChangeServerAlertText.category)
    let participant = plan.save[2]
    #expect(participant.database == .participating)
    #expect(participant.zoneName == nil)
    #expect(participant.body == "Something shared with you was updated")
}

@Test func aShareWithNobodyElseGetsNoAlert() {
    let alone = zone("trips", tripZone, "Solo", others: false)
    let plan = SharedChangeServerAlertPlan.make(mode: .reconcile, inputs: .init(ownedZones: [alone]), existing: [])
    #expect(plan.isEmpty, "It could only ever alert about the user's own edits")
}

@Test func anUnchangedServerNeedsNothing() {
    let inputs = SharedChangeServerAlertInputs(ownedZones: [rome], participatingModuleIDs: ["trips"])
    let existing = SharedChangeServerAlertPlan.candidates(for: inputs)
    #expect(SharedChangeServerAlertPlan.make(mode: .reconcile, inputs: inputs, existing: existing).isEmpty)
    #expect(SharedChangeServerAlertPlan.make(mode: .maintain, inputs: inputs, existing: existing).isEmpty)
}

@Test func aRenameRewordsTheExistingSubscription() {
    let before = SharedChangeServerAlertPlan.candidates(for: .init(ownedZones: [rome]))
    let renamed = zone("trips", tripZone, "Rome, Amalfi & Capri")
    for mode in [SharedChangeServerAlertPlan.Mode.reconcile, .maintain] {
        let plan = SharedChangeServerAlertPlan.make(mode: mode, inputs: .init(ownedZones: [renamed]), existing: before)
        #expect(plan.save.map(\.body) == ["Rome, Amalfi & Capri was updated"])
        #expect(plan.save.map(\.id) == before.map(\.id), "Saved over the same ID")
        #expect(plan.delete.isEmpty)
    }
}

@Test func aShareThatIsGoneLosesItsAlert() {
    let existing = SharedChangeServerAlertPlan.candidates(for: .init(ownedZones: [rome, car], participatingModuleIDs: ["explore"]))
    for mode in [SharedChangeServerAlertPlan.Mode.reconcile, .maintain] {
        let plan = SharedChangeServerAlertPlan.make(mode: mode, inputs: .init(ownedZones: [car]), existing: existing)
        #expect(plan.save.isEmpty)
        #expect(Set(plan.delete.map(\.id)) == [
            SharedChangeServerAlertID.zone(moduleID: "trips", zoneName: tripZone),
            SharedChangeServerAlertID.shared,
        ], "No longer sharing the trip, and no longer in anyone else's share")
    }
}

@Test func maintainNeverCreates() {
    let inputs = SharedChangeServerAlertInputs(ownedZones: [rome], participatingModuleIDs: ["trips"])
    #expect(SharedChangeServerAlertPlan.make(mode: .maintain, inputs: inputs, existing: []).isEmpty,
            "The switch is off on this device; another device decides")
}

@Test func aMutedTrackerLosesItsAlertOnlyWhenReconciling() {
    let everything = SharedChangeServerAlertInputs(ownedZones: [rome, car])
    let existing = SharedChangeServerAlertPlan.candidates(for: everything)
    var muted = everything
    muted.mutedModuleIDs = ["trips"]

    let reconcile = SharedChangeServerAlertPlan.make(mode: .reconcile, inputs: muted, existing: existing)
    #expect(reconcile.delete.map(\.id) == [SharedChangeServerAlertID.zone(moduleID: "trips", zoneName: tripZone)])
    #expect(reconcile.save.isEmpty)
    #expect(SharedChangeServerAlertPlan.make(mode: .maintain, inputs: muted, existing: existing).isEmpty)
}

@Test func theParticipantsAlertStaysWhileAnyOfItsTrackersIsWanted() {
    let inputs = SharedChangeServerAlertInputs(participatingModuleIDs: ["points", "finance"], mutedModuleIDs: ["finance"])
    #expect(SharedChangeServerAlertPlan.make(mode: .reconcile, inputs: inputs, existing: []).save.map(\.id) == [SharedChangeServerAlertID.shared])

    var allMuted = inputs
    allMuted.mutedModuleIDs = ["points", "finance"]
    let existing = SharedChangeServerAlertPlan.candidates(for: inputs)
    #expect(SharedChangeServerAlertPlan.make(mode: .reconcile, inputs: allMuted, existing: existing).delete.map(\.id) == [SharedChangeServerAlertID.shared])
}

@Test func removeAllDeletesOnlyOurs() {
    let ours = SharedChangeServerAlertPlan.candidates(for: .init(ownedZones: [rome], participatingModuleIDs: ["trips"]))
    let coreData = SharedChangeServerAlert(
        id: "com.apple.coredata.cloudkit.private.subscription",
        database: .owned,
        title: nil,
        body: nil,
        category: nil
    )
    let plan = SharedChangeServerAlertPlan.make(mode: .removeAll, inputs: .init(ownedZones: [rome]), existing: ours + [coreData])
    #expect(plan.save.isEmpty)
    #expect(plan.delete == ours)

    let reconcile = SharedChangeServerAlertPlan.make(mode: .reconcile, inputs: .init(), existing: [coreData])
    #expect(reconcile.isEmpty, "Core Data's own silent subscription is never touched")
}

// MARK: - Own edits

private func event(_ root: String, _ alertID: String?, _ author: SharedChangeAuthor) -> SharedChangeEvent {
    SharedChangeEvent(
        moduleID: "trips",
        rootKey: root,
        rootTitle: root,
        objectKey: UUID().uuidString,
        kind: .updated,
        action: "changed something",
        author: author,
        serverAlertID: alertID
    )
}

@Test func onlyAlertsAboutTheUsersOwnEditsAreCleanedUp() {
    let romeAlert = SharedChangeServerAlertID.zone(moduleID: "trips", zoneName: tripZone)
    let carAlert = SharedChangeServerAlertID.zone(moduleID: "fuel", zoneName: carZone)
    let events = [
        event("rome", romeAlert, .currentUser),
        event("rome", romeAlert, .currentUser),
        event("car", carAlert, .currentUser),
        event("car", carAlert, .named("Saloni")),
        event("guide", SharedChangeServerAlertID.shared, .currentUser),
        event("loose", nil, .currentUser),
    ]
    #expect(SharedChangeServerAlertCleanup.ownEditAlertIDs(in: events) == [romeAlert],
            "Saloni touched the car too; the shared database's alert may be about another share")
}

@Test func coalescedNoticesCarryTheirServerAlert() {
    var coalescer = SharedChangeCoalescer(quietPeriod: 1, maximumDelay: 10)
    let start = Date(timeIntervalSince1970: 0)
    let alert = SharedChangeServerAlertID.zone(moduleID: "trips", zoneName: tripZone)
    coalescer.add(event("rome", alert, .named("Saloni")), at: start)
    coalescer.add(event("rome", nil, .named("Saloni")), at: start)
    #expect(coalescer.due(asOf: start.addingTimeInterval(2)).map(\.serverAlertID) == [alert])
}

@Test func permissionIsAskedForOnlyWhenSomethingIsSharedAndItWasNeverAsked() {
    let participating = SharedChangeServerAlertInputs(participatingModuleIDs: ["fuel"])
    #expect(participating.shouldAskForPermission(switchOn: true, neverAsked: true))
    #expect(!participating.shouldAskForPermission(switchOn: false, neverAsked: true))
    #expect(!participating.shouldAskForPermission(switchOn: true, neverAsked: false))
    // The owner of a shared car is asked too, not only whoever accepted it.
    #expect(SharedChangeServerAlertInputs(ownedZones: [car]).shouldAskForPermission(switchOn: true, neverAsked: true))
    #expect(!SharedChangeServerAlertInputs().shouldAskForPermission(switchOn: true, neverAsked: true))
}

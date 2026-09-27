import CloudKit
import Foundation
import Testing
@testable import Core

// MARK: - SharedChangeFilter

private let import_ = SharedChangeFilter.cloudKitImportAuthor
private let entities: Set<String> = ["SharedTrip", "SharedItineraryItem"]

private func change(_ key: String, _ kind: SharedChangeKind, _ entity: String = "SharedItineraryItem", _ properties: Set<String> = []) -> HistoryChangeRecord {
    HistoryChangeRecord(objectKey: key, entityName: entity, kind: kind, updatedProperties: properties)
}

@Test func onlyCloudKitImportsCount() {
    let transactions = [
        HistoryTransactionRecord(author: SharedChangeFilter.appAuthor, changes: [change("a", .inserted)]),
        HistoryTransactionRecord(author: nil, changes: [change("b", .inserted)]),
        HistoryTransactionRecord(author: "NSCloudKitMirroringDelegate.export", changes: [change("c", .updated)]),
        HistoryTransactionRecord(author: "NSCloudKitMirroringDelegate.reset", changes: [change("d", .updated)]),
        HistoryTransactionRecord(author: import_, changes: [change("e", .inserted)]),
    ]
    #expect(SharedChangeFilter.relevantChanges(in: transactions, entityNames: entities).map(\.objectKey) == ["e"])
}

@Test func deletionsAreDroppedAndTakeEarlierChangesWithThem() {
    let transactions = [
        HistoryTransactionRecord(author: import_, changes: [change("a", .inserted), change("b", .updated)]),
        HistoryTransactionRecord(author: import_, changes: [change("a", .deleted), change("c", .deleted)]),
    ]
    #expect(SharedChangeFilter.relevantChanges(in: transactions, entityNames: entities).map(\.objectKey) == ["b"])
}

@Test func anInsertFollowedByAnUpdateStaysAnInsert() {
    let transactions = [
        HistoryTransactionRecord(author: import_, changes: [change("a", .updated, "SharedItineraryItem", ["title"])]),
        HistoryTransactionRecord(author: import_, changes: [change("b", .inserted), change("a", .updated, "SharedItineraryItem", ["isDone"])]),
        HistoryTransactionRecord(author: import_, changes: [change("b", .updated, "SharedItineraryItem", ["dayIndex"])]),
    ]
    let relevant = SharedChangeFilter.relevantChanges(in: transactions, entityNames: entities)
    #expect(relevant.map(\.objectKey) == ["a", "b"], "First-changed order")
    #expect(relevant[0].kind == .updated)
    #expect(relevant[0].updatedProperties == ["title", "isDone"])
    #expect(relevant[1].kind == .inserted)
}

@Test func theMirroringDelegatesOwnTablesAreIgnored() {
    let transactions = [
        HistoryTransactionRecord(author: import_, changes: [change("m", .inserted, "NSCKRecordMetadata"), change("t", .updated, "SharedTrip")]),
    ]
    #expect(SharedChangeFilter.relevantChanges(in: transactions, entityNames: entities).map(\.objectKey) == ["t"])
}

// MARK: - SharedChangeAuthorResolver

private let participants = [
    ShareParticipantRecord(userRecordName: "_owner", displayName: "Bhavik", isCurrentUser: true),
    ShareParticipantRecord(userRecordName: "_saloni", displayName: "Saloni", isCurrentUser: false),
    ShareParticipantRecord(userRecordName: "_pending", displayName: nil, isCurrentUser: false),
]

@Test func aParticipantIsNamed() {
    #expect(SharedChangeAuthorResolver.author(lastModifiedBy: "_saloni", participants: participants) == .named("Saloni"))
}

@Test func thisAccountsOwnEditsAreRecognised() {
    #expect(SharedChangeAuthorResolver.author(lastModifiedBy: "_owner", participants: participants) == .currentUser)
    #expect(SharedChangeAuthorResolver.author(lastModifiedBy: CKCurrentUserDefaultName, participants: participants) == .currentUser,
            "CloudKit's placeholder for the account reading the record")
}

@Test func anUnknownOrNamelessAuthorIsSomeone() {
    #expect(SharedChangeAuthorResolver.author(lastModifiedBy: nil, participants: participants) == .someone)
    #expect(SharedChangeAuthorResolver.author(lastModifiedBy: "_stranger", participants: participants) == .someone)
    #expect(SharedChangeAuthorResolver.author(lastModifiedBy: "_pending", participants: participants) == .someone)
    #expect(SharedChangeAuthorResolver.author(lastModifiedBy: "_saloni", participants: []) == .someone)
}

@Test func aGivenNameIsPreferred() {
    var components = PersonNameComponents()
    components.givenName = "Saloni"
    components.familyName = "Shah"
    #expect(SharedChangeAuthorResolver.displayName(components) == "Saloni")
    #expect(SharedChangeAuthorResolver.displayName(nil) == nil)
    #expect(SharedChangeAuthorResolver.displayName(PersonNameComponents()) == nil)
}

// MARK: - SharedRootArrivals

private func event(
    _ object: String,
    root: String = "trip",
    _ kind: SharedChangeKind = .inserted,
    _ action: String? = nil,
    by author: SharedChangeAuthor = .named("Saloni"),
    title: String = "Rome & Amalfi"
) -> SharedChangeEvent {
    SharedChangeEvent(
        moduleID: "trips",
        rootKey: root,
        rootTitle: title,
        objectKey: object,
        kind: kind,
        action: action ?? "added \(object)",
        author: author
    )
}

@Test func thisAccountsOwnEditsAreNeverAdmitted() {
    var arrivals = SharedRootArrivals()
    let admitted = arrivals.admit([event("a", by: .currentUser), event("b", by: .someone)])
    #expect(admitted.map(\.objectKey) == ["b"])
}

@Test func anAcceptedShareIsQuietWhileItDownloads() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    var arrivals = SharedRootArrivals(quietWindow: 600)

    // The root and some children arrive together, more children after.
    #expect(arrivals.admit([event("item1"), event("trip"), event("place", root: "guide")], asOf: start).map(\.objectKey) == ["place"])
    #expect(arrivals.admit([event("item2")], asOf: start.addingTimeInterval(120)).isEmpty)
    // Once the window has passed, a real edit is news again.
    #expect(arrivals.admit([event("item3")], asOf: start.addingTimeInterval(601)).map(\.objectKey) == ["item3"])
}

@Test func anUpdateToARootIsNotAnArrival() {
    var arrivals = SharedRootArrivals()
    #expect(arrivals.admit([event("trip", .updated, "changed the dates")]).count == 1)
}

// MARK: - SharedChangeCoalescer

@Test func oneChangeIsDescribedInFull() throws {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    var coalescer = SharedChangeCoalescer(quietPeriod: 4, maximumDelay: 20)
    coalescer.add(event("gelato", .inserted, "added Gelato at Giolitti to Day 3"), at: start)

    #expect(coalescer.due(asOf: start.addingTimeInterval(3)).isEmpty, "Still in the quiet period")
    let notices = coalescer.due(asOf: start.addingTimeInterval(4))
    #expect(notices == [SharedChangeNotice(moduleID: "trips", rootKey: "trip", title: "Rome & Amalfi", body: "Saloni added Gelato at Giolitti to Day 3")])
    #expect(coalescer.isEmpty)
}

@Test func aBurstBecomesOneNotificationPerRoot() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    var coalescer = SharedChangeCoalescer(quietPeriod: 4, maximumDelay: 20)
    for (offset, name) in ["a", "b", "c", "d"].enumerated() {
        coalescer.add(event(name), at: start.addingTimeInterval(Double(offset)))
    }
    coalescer.add(event("x3", root: "car", title: "My X3"), at: start)

    #expect(coalescer.nextDeadline == start.addingTimeInterval(4))
    let first = coalescer.due(asOf: start.addingTimeInterval(4))
    #expect(first.map(\.title) == ["My X3"], "The trip's burst is still going")
    let second = coalescer.due(asOf: start.addingTimeInterval(7))
    #expect(second.map(\.body) == ["Saloni made 4 changes to Rome & Amalfi"])
}

@Test func theSameObjectTwiceIsOneChangeAndKeepsItsInsert() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    var coalescer = SharedChangeCoalescer()
    coalescer.add(event("gelato", .inserted, "added Gelato to Day 3"), at: start)
    coalescer.add(event("gelato", .updated, "changed Gelato"), at: start)
    #expect(coalescer.due(asOf: start, force: true).map(\.body) == ["Saloni added Gelato to Day 3"])

    coalescer.add(event("pasta", .updated, "changed Pasta"), at: start)
    coalescer.add(event("pasta", .updated, "moved Pasta to Day 2"), at: start)
    #expect(coalescer.due(asOf: start, force: true).map(\.body) == ["Saloni moved Pasta to Day 2"], "The latest update wins")
}

@Test func aLongBurstIsCutOffAtTheMaximumDelay() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    var coalescer = SharedChangeCoalescer(quietPeriod: 4, maximumDelay: 20)
    for second in stride(from: 0, through: 19, by: 3) {
        coalescer.add(event("item\(second)"), at: start.addingTimeInterval(Double(second)))
    }
    #expect(coalescer.due(asOf: start.addingTimeInterval(19.5)).isEmpty)
    #expect(coalescer.due(asOf: start.addingTimeInterval(20)).count == 1)
}

@Test func peopleAreNamedTogetherAndSomeoneOnlyWhenNobodyCanBe() {
    #expect(SharedChangeCoalescer.subject(for: [.named("Saloni"), .someone, .named("Alex")]) == "Saloni and Alex")
    #expect(SharedChangeCoalescer.subject(for: [.someone]) == "Someone")
    #expect(SharedChangeCoalescer.subject(for: []) == "Someone")
}

@Test func aRenameMidBurstTitlesTheNotificationByTheNewName() {
    var coalescer = SharedChangeCoalescer()
    coalescer.add(event("a", title: "Rome"))
    coalescer.add(event("b", title: "Rome & Amalfi"))
    #expect(coalescer.due(force: true).map(\.title) == ["Rome & Amalfi"])
}

@Test func oneIdentifierPerRoot() {
    let notice = SharedChangeNotice(moduleID: "fuel", rootKey: "x-coredata://store/SharedVehicle/p1", title: "My X3", body: "")
    #expect(notice.identifier == "shared-change.fuel.x-coredata://store/SharedVehicle/p1")
}

// MARK: - Settings

@Test func notificationsAreOnUntilTurnedOff() throws {
    let defaults = try #require(UserDefaults(suiteName: "SharedChangeSettingsTests-\(UUID().uuidString)"))
    #expect(SharedChangeNotifications.isEnabled(moduleID: "trips", defaults: defaults))

    defaults.set(false, forKey: SharedChangeNotifications.moduleEnabledKey("finance"))
    #expect(!SharedChangeNotifications.isEnabled(moduleID: "finance", defaults: defaults))
    #expect(SharedChangeNotifications.isEnabled(moduleID: "trips", defaults: defaults))

    defaults.set(false, forKey: SharedChangeNotifications.enabledKey)
    #expect(!SharedChangeNotifications.isEnabled(moduleID: "trips", defaults: defaults))
}

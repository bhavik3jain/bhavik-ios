import Foundation
import Testing
@testable import TripTracker

private let saloni = PersonKey.participant(recordName: "_saloni")
private let raj = PersonKey.participant(recordName: "_raj")

private func share(me: PersonKey?, _ participants: [ShareParticipantSnapshot]) -> TripShareState {
    .shared(ShareSnapshot(participants: participants, currentUserKey: me))
}

private let ownerAndSaloni: [ShareParticipantSnapshot] = [
    .init(key: saloni, name: "Saloni", status: .accepted),
    .init(key: .owner, name: "Bhavik", status: .accepted),
    .init(key: nil, name: "dev@example.com", status: .pending),
]

@Test func aTripInMyOwnStoreIsMineAsOwnerSharedOrNot() {
    #expect(TripPeople.currentUserKey(.notShared, isInSharedStore: false) == .owner)
    #expect(TripPeople.currentUserKey(share(me: .owner, ownerAndSaloni), isInSharedStore: false) == .owner)
}

@Test func onAPartnersDeviceTheyAreTheirOwnKeyAndNeverAGuess() {
    #expect(TripPeople.currentUserKey(share(me: saloni, ownerAndSaloni), isInSharedStore: true) == saloni)
    #expect(TripPeople.currentUserKey(.unknown, isInSharedStore: true) == nil)
}

@Test func theRosterListsTheOwnerFirstThenPendingThenManual() {
    let alex = PersonKey("manual:ALEX")
    let people = TripPeople(
        share: share(me: saloni, ownerAndSaloni),
        rows: [PersonRecord(key: alex, name: "Alex", kind: .manual)],
        me: saloni
    )
    #expect(people.roster.map(\.label) == ["Bhavik", "You", "dev@example.com", "Alex"])
    #expect(people.roster.map(\.source) == [.iCloud, .iCloud, .pending, .manual])
    let pending = people.roster[2]
    #expect(pending.key == nil)
    #expect(!pending.canBeSplitWith)
    #expect(!pending.canSettle)
    #expect(people.splittable.compactMap(\.key) == [.owner, saloni, alex])
}

@Test func duplicateSnapshotRowsFoldToTheNewestName() {
    let rows = [
        PersonRecord(key: saloni, name: "Sal", kind: .participant, updatedAt: Date(timeIntervalSince1970: 100)),
        PersonRecord(key: saloni, name: "Saloni", kind: .participant, updatedAt: Date(timeIntervalSince1970: 200)),
        PersonRecord(key: saloni, name: "S.", kind: .participant, updatedAt: Date(timeIntervalSince1970: 50)),
    ]
    let people = TripPeople(share: .unknown, rows: rows, me: nil)
    #expect(people.name(for: saloni) == "Saloni")
    #expect(people.roster.filter { $0.key == saloni }.count == 1)
    #expect(people.roster.first { $0.key == saloni }?.source == .iCloud, "Not looked up yet is not left")
}

@Test func someoneGoneFromTheShareIsListedAsLeftAndKeepsTheirName() throws {
    let people = TripPeople(
        share: share(me: .owner, [.init(key: .owner, name: "Bhavik", status: .accepted, isCurrentUser: true)]),
        rows: [PersonRecord(key: raj, name: "Raj", kind: .participant)],
        me: .owner
    )
    let left = try #require(people.roster.first { $0.key == raj })
    #expect(left.source == .left)
    #expect(!left.canBeSplitWith)
    #expect(left.canSettle)
    #expect(people.label(for: .owner) == "You")
}

@Test func aLinkedManualPersonCountsAsTheParticipant() {
    let alex = PersonKey("manual:ALEX")
    let people = TripPeople(
        share: share(me: .owner, ownerAndSaloni),
        rows: [PersonRecord(key: alex, name: "Sal (no app)", kind: .manual, mergedInto: saloni)],
        me: .owner
    )
    #expect(people.resolve(alex) == saloni)
    #expect(people.name(for: alex) == "Saloni")
    #expect(!people.roster.contains { $0.key == alex })
    // The editor lists an old expense's Alex beside the real Saloni.
    #expect(people.listLabel(for: alex) == "Sal (no app) (counts as Saloni)")
    #expect(people.listLabel(for: saloni) == "Saloni")
}

@Test func aMergeCycleIsCaught() {
    let x = PersonKey("manual:X"), y = PersonKey("manual:Y")
    let people = TripPeople(
        share: .notShared,
        rows: [
            PersonRecord(key: x, name: "X", kind: .manual, mergedInto: y),
            PersonRecord(key: y, name: "Y", kind: .manual, mergedInto: x),
        ],
        me: .owner
    )
    #expect(people.resolve(x) == x)
    #expect(people.resolve(y) == y)
    #expect(people.roster.compactMap(\.key) == [.owner, x, y])
}

@Test func aHiddenPersonIsLeftOutOfPickersButKeptInTheLedger() {
    let alex = PersonKey("manual:ALEX")
    let people = TripPeople(share: .notShared, rows: [PersonRecord(key: alex, name: "Alex", kind: .manual, isHidden: true)], me: .owner)
    #expect(people.roster.contains { $0.key == alex && $0.isHidden })
    #expect(!people.splittable.contains { $0.key == alex })

    let dinner = ExpenseRecord(id: "1", title: "Dinner", amountMinor: 1_000, currencyCode: "EUR", payer: .owner, split: .equal([.owner, alex]), date: .now)
    #expect(TripLedger(expenses: [dinner], people: people).balance(of: alex, in: "EUR") == -500)
}

@Test func snapshotRowsAreWrittenForNewOrRenamedShareKeysOnly() {
    let snapshot = ShareSnapshot(participants: ownerAndSaloni, currentUserKey: .owner)
    let alex = PersonKey("manual:ALEX")
    let rows = [PersonRecord(key: .owner, name: "Bhavik", kind: .participant), PersonRecord(key: alex, name: "Alex", kind: .manual)]
    #expect(TripPeople.participantRowChanges(for: [.owner, saloni, alex], share: snapshot, rows: rows) == [
        .init(key: saloni, name: "Saloni", isNew: true),
    ])
    let renamed = [PersonRecord(key: saloni, name: "Sal", kind: .participant)]
    #expect(TripPeople.participantRowChanges(for: [saloni], share: snapshot, rows: renamed) == [
        .init(key: saloni, name: "Saloni", isNew: false),
    ])
    #expect(TripPeople.participantRowChanges(for: [saloni], share: nil, rows: []).isEmpty)
}

@MainActor
@Test func recordingParticipantsWritesRowsOnceIntoTheTrip() throws {
    let context = try makeContext()
    let trip = makeRome(in: context)
    let snapshot = ShareSnapshot(participants: ownerAndSaloni, currentUserKey: .owner)
    let dinner = SharedTripExpense(context: context, title: "Dinner", amountMinor: 8_400, currencyCode: "EUR", payer: .owner, split: .equal([.owner, saloni]))
    dinner.trip = trip
    #expect(trip.recordParticipants(of: dinner, share: snapshot) == 2)
    try context.save()
    #expect(trip.recordParticipants(of: dinner, share: snapshot) == 0)
    #expect(Set(trip.personRecords.map(\.key)) == [.owner, saloni])
}

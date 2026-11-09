import Foundation
import Testing
@testable import TripTracker

private let saloni = PersonKey.participant(recordName: "_saloni")
private let alex = PersonKey("manual:ALEX")
private let us = Locale(identifier: "en_US")

private let people = TripPeople(
    share: .shared(ShareSnapshot(participants: [
        .init(key: .owner, name: "Bhavik", status: .accepted, isCurrentUser: true),
        .init(key: saloni, name: "Saloni", status: .accepted),
        .init(key: nil, name: "dev@example.com", status: .pending),
    ], currentUserKey: .owner)),
    rows: [PersonRecord(key: alex, name: "Alex", kind: .manual)],
    me: .owner
)
private let words = SplitWording(people: people, locale: us)

@Test func myBalanceReadsAsOwedOweOrSquare() {
    #expect(words.myBalance(3_800, code: "EUR") == "You're owed €38.00")
    #expect(words.myBalance(-1_200, code: "EUR") == "You owe €12.00")
    #expect(words.myBalance(0, code: "EUR") == "You're square")
    #expect(words.balance(-1_200, code: "JPY", isMe: false) == "owes ¥1,200")
}

@Test func transfersSayYouWhereItIsMe() {
    #expect(words.transfer(.init(from: .owner, to: saloni, amountMinor: 3_800, currencyCode: "EUR")) == "You pay Saloni €38.00")
    #expect(words.transfer(.init(from: saloni, to: .owner, amountMinor: 3_800, currencyCode: "EUR")) == "Saloni pays you €38.00")
    #expect(words.transfer(.init(from: alex, to: saloni, amountMinor: 1_000, currencyCode: "EUR")) == "Alex pays Saloni €10.00")
}

@Test func theSubtitleCountsPeopleButNotPendingInvitees() {
    let ledger = TripLedger(expenses: [
        ExpenseRecord(id: "1", title: "Dinner", amountMinor: 111_640, currencyCode: "EUR", payer: .owner, split: .equal([.owner, saloni]), date: .now),
    ], people: people)
    #expect(words.subtitle(ledger: ledger) == "€1,116.40 · 3 people")
}

@Test func involvementWordsTheRowFigure() {
    #expect(words.involvement(.lent(11_820), code: "EUR") == "you lent €118.20")
    #expect(words.involvement(.borrowed(5_910), code: "EUR") == "you borrowed €59.10")
    #expect(words.involvement(.notInvolved, code: "EUR") == nil)
}

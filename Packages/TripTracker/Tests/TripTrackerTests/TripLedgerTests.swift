import Foundation
import Testing
@testable import TripTracker

private let me = PersonKey.owner
private let saloni = PersonKey.participant(recordName: "_saloni")
private let alex = PersonKey("manual:ALEX")

private func expense(
    _ id: String,
    _ amount: Int64,
    _ currency: String = "EUR",
    paidBy payer: PersonKey,
    _ split: ExpenseSplit,
    kind: ExpenseKind = .expense,
    on date: Date = day(6, 8)
) -> ExpenseRecord {
    ExpenseRecord(id: id, title: id, amountMinor: amount, currencyCode: currency, payer: payer, kind: kind, split: split, date: date)
}

@Test func balancesSumToZero() {
    let ledger = TripLedger(expenses: [
        expense("Dinner", 10_000, paidBy: me, .equal([me, saloni, alex])),
        expense("Taxi", 3_000, paidBy: saloni, .equal([me, saloni])),
    ])
    let eur = ledger.balances["EUR"] ?? [:]
    #expect(eur.values.reduce(0, +) == 0)
    #expect(eur[me] == Int64(10_000 - 3_333 - 1_500))
    #expect(eur[saloni] == Int64(3_000 - 3_334 - 1_500))
    #expect(eur[alex] == -3_333)
    #expect(ledger.totals["EUR"] == 13_000)
    #expect(ledger.paid["EUR"]?[me] == 10_000)
    #expect(ledger.shares["EUR"]?[saloni] == Int64(3_334 + 1_500))
}

@Test func paymentsSettleBalancesButNeverCountTowardTheTotal() {
    let ledger = TripLedger(expenses: [
        expense("Dinner", 8_000, paidBy: me, .equal([me, saloni])),
        expense("Paid back", 4_000, paidBy: saloni, .payment(to: me, amountMinor: 4_000), kind: .payment),
    ])
    #expect(ledger.totals["EUR"] == 8_000)
    #expect(ledger.isSettled)
    #expect(ledger.transfers.isEmpty)
}

@Test func aLinkedManualPersonIsResolved() {
    let people = TripPeople(
        share: .unknown,
        rows: [PersonRecord(key: alex, name: "Sal", kind: .manual, mergedInto: saloni)],
        me: me
    )
    let ledger = TripLedger(expenses: [
        expense("Museum", 3_000, paidBy: me, .equal([me, alex])),
        expense("Lunch", 2_000, paidBy: me, .equal([me, saloni])),
    ], people: people)
    #expect(ledger.balance(of: saloni, in: "EUR") == -2_500)
    #expect(ledger.balance(of: alex, in: "EUR") == -2_500)
    #expect(ledger.balances["EUR"]?[alex] == nil)
}

@Test func someoneWhoLeftKeepsTheirBalance() {
    let raj = PersonKey.participant(recordName: "_raj")
    let people = TripPeople(
        share: .shared(ShareSnapshot(participants: [.init(key: .owner, name: "Bhavik", status: .accepted)], currentUserKey: me)),
        rows: [PersonRecord(key: raj, name: "Raj", kind: .participant)],
        me: me
    )
    let ledger = TripLedger(expenses: [expense("Boat", 6_000, paidBy: me, .equal([me, raj]))], people: people)
    #expect(ledger.balance(of: raj, in: "EUR") == -3_000)
    #expect(ledger.transfers == [.init(from: raj, to: me, amountMinor: 3_000, currencyCode: "EUR")])
}

@Test func twoCurrenciesAreKeptApart() {
    let ledger = TripLedger(expenses: [
        expense("Dinner", 6_000, "EUR", paidBy: me, .equal([me, saloni])),
        expense("Ramen", 3_000, "JPY", paidBy: saloni, .equal([me, saloni])),
    ])
    #expect(ledger.currencies == ["EUR", "JPY"])
    #expect(ledger.balances(of: me) == ["EUR": 3_000, "JPY": -1_500])
    #expect(ledger.totals == ["EUR": 6_000, "JPY": 3_000])
}

@Test func involvementSaysWhoLentAndWhoBorrowed() {
    let dinner = expense("Dinner", 9_000, paidBy: me, .equal([me, saloni, alex]))
    let ledger = TripLedger(expenses: [dinner])
    #expect(ledger.involvement(of: me, in: dinner) == .lent(6_000))
    #expect(ledger.involvement(of: saloni, in: dinner) == .borrowed(3_000))
    #expect(ledger.involvement(of: PersonKey("manual:NOBODY"), in: dinner) == .notInvolved)
    let payment = expense("Paid", 3_000, paidBy: saloni, .payment(to: me, amountMinor: 3_000), kind: .payment)
    #expect(ledger.involvement(of: saloni, in: payment) == .paid(3_000))
    #expect(ledger.involvement(of: me, in: payment) == .received(3_000))
    #expect(ledger.involvement(of: alex, in: payment) == .notInvolved)
}

@Test func mentionedKeysCoverPayersAndSplits() {
    let keys = TripLedger.mentionedKeys(in: [expense("Dinner", 1_000, paidBy: saloni, .equal([me, alex]))])
    #expect(keys == [me, saloni, alex])
}

@Test func dayGroupsRunLatestFirstWithBeforeAndAfter() {
    let dates = TripDates(start: day(6, 6), end: day(6, 14))
    let groups = TripLedger.dayGroups([
        expense("Flights", 50_000, paidBy: me, .equal([me]), on: day(5, 1)),
        expense("Breakfast", 1_000, paidBy: me, .equal([me]), on: day(6, 7, 9)),
        expense("Dinner", 4_000, paidBy: me, .equal([me]), on: day(6, 7, 21)),
        expense("Gelato", 500, paidBy: me, .equal([me]), on: day(6, 6)),
        expense("Souvenir", 2_000, paidBy: me, .equal([me]), on: day(6, 20)),
    ], dates: dates)
    #expect(groups.map(\.placement) == [.after, .day(1), .day(0), .before])
    #expect(groups[1].expenses.map(\.title) == ["Dinner", "Breakfast"])
    #expect(groups[0].title() == "After the trip")
    #expect(groups[3].title() == "Before the trip")
    #expect(groups[1].title(locale: Locale(identifier: "en_US")).hasPrefix("Day 2 · "))
}

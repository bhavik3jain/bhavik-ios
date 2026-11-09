import Foundation
import Testing
@testable import TripTracker

private let a = PersonKey("ck:a")
private let b = PersonKey("ck:b")
private let c = PersonKey("ck:c")
private let d = PersonKey("ck:d")

@Test func alreadySquareNeedsNothing() {
    #expect(SettleUp.transfers([a: 0, b: 0], currencyCode: "EUR").isEmpty)
    #expect(SettleUp.transfers(balances: [:]).isEmpty)
}

@Test func everyonePaysTheOneCreditor() {
    let transfers = SettleUp.transfers([a: 6_000, b: -3_000, c: -3_000], currencyCode: "EUR")
    #expect(transfers == [
        .init(from: b, to: a, amountMinor: 3_000, currencyCode: "EUR"),
        .init(from: c, to: a, amountMinor: 3_000, currencyCode: "EUR"),
    ])
}

@Test func manyToManyTakesAtMostNMinusOne() {
    let balances: [PersonKey: Int64] = [a: 5_000, b: 2_000, c: -4_500, d: -2_500]
    let transfers = SettleUp.transfers(balances, currencyCode: "EUR")
    #expect(transfers.count <= 3)
    var after = balances
    for transfer in transfers {
        after[transfer.from, default: 0] += transfer.amountMinor
        after[transfer.to, default: 0] -= transfer.amountMinor
    }
    #expect(after.values.allSatisfy { $0 == 0 })
    #expect(transfers.first == .init(from: c, to: a, amountMinor: 4_500, currencyCode: "EUR"))
}

@Test func currenciesAreSettledApart() {
    let transfers = SettleUp.transfers(balances: [
        "JPY": [a: -1_000, b: 1_000],
        "EUR": [a: 500, b: -500],
    ])
    #expect(transfers == [
        .init(from: b, to: a, amountMinor: 500, currencyCode: "EUR"),
        .init(from: a, to: b, amountMinor: 1_000, currencyCode: "JPY"),
    ])
}

@Test func theSameForAnyInputOrder() {
    let pairs: [(PersonKey, Int64)] = [(a, 1_000), (b, 1_000), (c, -1_000), (d, -1_000)]
    let expected = SettleUp.transfers(Dictionary(uniqueKeysWithValues: pairs), currencyCode: "EUR")
    for _ in 0..<20 {
        let shuffled = Dictionary(uniqueKeysWithValues: pairs.shuffled())
        #expect(SettleUp.transfers(shuffled, currencyCode: "EUR") == expected)
    }
    #expect(expected == [
        .init(from: c, to: a, amountMinor: 1_000, currencyCode: "EUR"),
        .init(from: d, to: b, amountMinor: 1_000, currencyCode: "EUR"),
    ])
}

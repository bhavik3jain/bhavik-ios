import Foundation
import Testing
@testable import TripTracker

private let ana = PersonKey.owner
private let ben = PersonKey.participant(recordName: "_ben")
private let cy = PersonKey("manual:CY")

@Test func aHundredSplitThreeWaysGivesTheExtraCentToTheFirstKey() {
    let split = ExpenseSplit.equal([ben, cy, ana])
    let amounts = split.allocate(total: 10_000)
    // Equal fractions: the tie goes by ascending raw key — "ck:_ben" first.
    #expect(amounts == [ben: 3_334, cy: 3_333, ana: 3_333])
    #expect(amounts.values.reduce(0, +) == 10_000)
    // Listed order changes nothing.
    #expect(ExpenseSplit.equal([ana, cy, ben]).allocate(total: 10_000) == amounts)
}

@Test func sharesWeighByCount() {
    let split = ExpenseSplit(mode: .shares, entries: [.init(key: ana, value: 2), .init(key: ben, value: 1)])
    #expect(split.allocate(total: 1_000) == [ana: 667, ben: 333])
    #expect(split.isValid(total: 1_000))
}

@Test func percentIsBasisPointsAndMustMakeAHundred() {
    let split = ExpenseSplit(mode: .percent, entries: [.init(key: ana, value: 7_000), .init(key: ben, value: 3_000)])
    #expect(split.allocate(total: 2_345) == [ana: 1_641, ben: 704], "Both are half a cent over; the tie goes to the lower key")
    #expect(split.remaining(total: 2_345) == 0)

    let short = ExpenseSplit(mode: .percent, entries: [.init(key: ana, value: 6_000), .init(key: ben, value: 3_000)])
    #expect(short.remaining(total: 2_345) == 1_000)
    #expect(!short.isValid(total: 2_345))
    #expect(!short.readsAsStored(total: 2_345))
    // Unsaveable as typed, it still sums exactly — as an equal split.
    #expect(short.allocate(total: 2_345).values.reduce(0, +) == 2_345)
}

@Test func exactAmountsAreTakenAsTypedAndMustSum() {
    let split = ExpenseSplit(mode: .exact, entries: [.init(key: ana, value: 1_500), .init(key: ben, value: 500)])
    #expect(split.allocate(total: 2_000) == [ana: 1_500, ben: 500])
    #expect(split.remaining(total: 2_500) == 500)
    #expect(!split.isValid(total: 2_500))
    #expect(split.allocate(total: 2_500) == [ana: 1_250, ben: 1_250], "An exact split that doesn't sum reads as equal")
}

@Test func yenHaveNoCentsToSpare() {
    let split = ExpenseSplit.equal([ana, ben, cy])
    let amounts = split.allocate(total: 1_000)
    #expect(amounts.values.reduce(0, +) == 1_000)
    #expect(Set(amounts.values) == [334, 333])
}

@Test func zeroAndEmptySplits() {
    #expect(ExpenseSplit.equal([ana, ben]).allocate(total: 0) == [ana: 0, ben: 0])
    #expect(ExpenseSplit.equal([]).allocate(total: 500).isEmpty)
    #expect(!ExpenseSplit.equal([]).isValid(total: 500))
}

@Test func aZeroShareGetsNothingAndNoStrayCent() {
    let split = ExpenseSplit(mode: .shares, entries: [.init(key: ana, value: 0), .init(key: ben, value: 1), .init(key: cy, value: 1)])
    #expect(split.allocate(total: 101) == [ana: 0, ben: 51, cy: 50])
}

@Test func theEncodingRoundTrips() {
    let split = ExpenseSplit(mode: .shares, entries: [.init(key: ana, value: 2), .init(key: ben, value: 1)])
    #expect(split.encoded == #"[{"k":"owner","v":2},{"k":"ck:_ben","v":1}]"#)
    #expect(ExpenseSplit.decode(split.encoded, mode: .shares) == split)
}

@Test func garbageDecodesAsAnEqualSplitOverWhatCouldBeRead() {
    let bad = ExpenseSplit.decode("not json", mode: .exact)
    #expect(bad.entries.isEmpty)
    #expect(bad.isFallback)

    let partial = ExpenseSplit.decode(#"[{"k":"owner","v":700},{"v":3},{"k":"ck:_ben","v":"x"},{"k":"manual:CY","v":300}]"#, mode: .exact)
    #expect(partial.mode == .equal)
    #expect(partial.keys == [ana, cy])
    #expect(partial.isFallback)
    #expect(!partial.readsAsStored(total: 1_000))

    #expect(ExpenseSplit.decode("", mode: .equal).isFallback == false)
    #expect(ExpenseSplit.decode(#"[{"k":"owner"}]"#, mode: .equal).keys == [ana])
}

@Test func aKeyListedTwiceCountsOnce() {
    let split = ExpenseSplit.decode(#"[{"k":"owner","v":1},{"k":"owner","v":1},{"k":"ck:_ben","v":1}]"#, mode: .equal)
    #expect(split.keys == [ana, ben])
}

@Test func aPaymentGivesTheWholeAmountToThePersonPaid() {
    let split = ExpenseSplit.payment(to: ben, amountMinor: 4_000)
    #expect(split.allocate(total: 4_000) == [ben: 4_000])
}

@Test func hugeTotalsDoNotOverflow() {
    let split = ExpenseSplit(mode: .percent, entries: [.init(key: ana, value: 3_333), .init(key: ben, value: 6_667)])
    let total: Int64 = 900_000_000_000_000
    #expect(split.allocate(total: total).values.reduce(0, +) == total)
}

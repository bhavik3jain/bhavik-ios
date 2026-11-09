import Foundation
import Testing
@testable import TripTracker

private let me = PersonKey.owner
private let saloni = PersonKey.participant(recordName: "_saloni")
private let alex = PersonKey("manual:ALEX")
private let us = Locale(identifier: "en_US")
private let de = Locale(identifier: "de_DE")
private let when = Date(timeIntervalSince1970: 1_800_000_000)

private func draft(_ amount: String = "100") -> ExpenseEditorState {
    var state = ExpenseEditorState(currencyCode: "EUR", payer: me, people: [me, saloni, alex], date: when)
    state.amountText = amount
    return state
}

@Test func anEqualSplitCanSaveOnceThereIsAnAmount() {
    #expect(!draft("").canSave(locale: us))
    #expect(!draft("0").canSave(locale: us))
    #expect(draft("100").canSave(locale: us))
    #expect(draft("100").preview(locale: us).map(\.value) == [3_333, 3_334, 3_333])
    // The odd cent goes by ascending key: "ck:_saloni" sorts first.
    #expect(draft().remainingText(locale: us) == nil)
}

@Test func noPayerOrNobodyInTheSplitCannotSave() {
    var state = draft()
    state.payer = nil
    #expect(!state.canSave(locale: us))
    state = draft()
    state.included = []
    #expect(!state.canSave(locale: us))
}

@Test func amountsStartEvenAndSaveOnlyWhenTheyAddUp() {
    var state = draft()
    state.setMode(.exact, locale: us)
    #expect(state.texts[me] == "33.33")
    #expect(state.texts[saloni] == "33.34")
    #expect(state.canSave(locale: us))
    #expect(state.remainingText(locale: us) == "€0.00 left to assign")

    state.texts[alex] = "30"
    #expect(!state.canSave(locale: us))
    #expect(state.remainingText(locale: us) == "€3.33 left to assign")
    state.texts[alex] = "40"
    #expect(state.remainingText(locale: us) == "€6.67 over")
    state.texts[alex] = "abc"
    #expect(!state.canSave(locale: us))
}

@Test func percentagesMustMakeAHundred() {
    var state = draft()
    state.setMode(.percent, locale: us)
    #expect(state.texts[me] == "33.33")
    #expect(state.canSave(locale: us))
    state.texts[me] = "50"
    #expect(!state.canSave(locale: us))
    #expect(state.remainingText(locale: us) == "16.67% over")
    state.texts = [me: "50", saloni: "25", alex: "25"]
    #expect(state.canSave(locale: us))
    #expect(state.preview(locale: us).map(\.value) == [5_000, 2_500, 2_500])
}

@Test func aCommaDecimalLocaleReadsItsOwnFigures() {
    var state = draft("100,50")
    state.setMode(.percent, locale: de)
    state.texts = [me: "50,5", saloni: "49,5", alex: ""]
    #expect(state.amountMinor(locale: de) == 10_050)
    #expect(state.canSave(locale: de))
}

@Test func sharesWeightTheSplit() {
    var state = draft("90")
    state.setMode(.shares, locale: us)
    state.weights[me] = 2
    #expect(state.preview(locale: us).map(\.value) == [4_500, 2_250, 2_250])
    #expect(state.canSave(locale: us))
}

@Test func togglingKeepsTheRosterOrder() {
    var state = draft()
    state.toggle(saloni, order: [me, saloni, alex])
    #expect(state.included == [me, alex])
    state.toggle(saloni, order: [me, saloni, alex])
    #expect(state.included == [me, saloni, alex])
}

@Test func anExistingExpenseOpensAsStored() {
    let record = ExpenseRecord(
        id: "1", title: "Dinner", amountMinor: 9_000, currencyCode: "EUR", payer: saloni,
        split: ExpenseSplit(mode: .exact, entries: [.init(key: me, value: 6_000), .init(key: saloni, value: 3_000)]),
        date: when
    )
    let state = ExpenseEditorState(record: record, note: "", locale: us)
    #expect(state.mode == .exact)
    #expect(state.amountText == "90")
    #expect(state.texts[me] == "60")
    #expect(state.canSave(locale: us))
    #expect(state.split(locale: us) == record.split)
}

@Test func aSplitThatNeedsALookOpensAsTheEqualSplitItCountsAs() {
    let broken = ExpenseSplit(mode: .exact, entries: [.init(key: me, value: 1), .init(key: saloni, value: 1)])
    let record = ExpenseRecord(id: "1", title: "Taxi", amountMinor: 5_000, currencyCode: "EUR", payer: me, split: broken, date: when)
    let state = ExpenseEditorState(record: record, note: "", locale: us)
    #expect(state.mode == .equal)
    #expect(state.included == [me, saloni])
}

@Test func anUntitledExpenseIsNamedForItsCategory() {
    var state = draft()
    state.category = .transport
    #expect(state.resolvedTitle == "Getting around")
    state.title = "  Taxi "
    #expect(state.resolvedTitle == "Taxi")
}

@Test func aPaymentNeedsTwoPeopleAndAnAmount() {
    #expect(PaymentDraft(from: saloni, to: me, amountMinor: 4_000, currencyCode: "EUR", date: when, locale: us).canSave(locale: us))
    #expect(!PaymentDraft(from: me, to: me, amountMinor: 4_000, currencyCode: "EUR", date: when, locale: us).canSave(locale: us))
    #expect(!PaymentDraft(from: saloni, to: nil, amountMinor: 4_000, currencyCode: "EUR", date: when, locale: us).canSave(locale: us))
    #expect(!PaymentDraft(from: saloni, to: me, amountMinor: 0, currencyCode: "EUR", date: when, locale: us).canSave(locale: us))
}

@Test func aNewExpenseIsDatedTodayDuringTheTripElseItsFirstDay() {
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: when)
    let end = calendar.date(byAdding: .day, value: 4, to: start)!
    let dates = TripDates(start: start, end: end)
    let during = calendar.date(byAdding: .hour, value: 30, to: start)!
    #expect(ExpenseEditorState.defaultDate(for: dates, asOf: during) == during)
    let before = calendar.date(byAdding: .day, value: -10, to: start)!
    #expect(ExpenseEditorState.defaultDate(for: dates, asOf: before) == dates.date(forDay: 0))
}

// Prefilled fields used to be written POSIX, which a comma-decimal locale
// reads back ten or a hundred times over.
@Test func prefilledFiguresReadBackInACommaDecimalLocale() {
    let record = ExpenseRecord(
        id: "1", title: "Dinner", amountMinor: 23_640, currencyCode: "EUR", payer: saloni,
        split: .equal([me, saloni]), date: when
    )
    let opened = ExpenseEditorState(record: record, note: "", locale: de)
    #expect(opened.amountText == "236,4")
    #expect(opened.amountMinor(locale: de) == 23_640)

    var exact = opened
    exact.setMode(.exact, locale: de)
    #expect(exact.canSave(locale: de))

    var percent = draft("100,50")
    percent.setMode(.percent, locale: de)
    #expect(percent.texts[me] == "33,33" || percent.texts[me] == "33,34")
    #expect(percent.canSave(locale: de))

    let payment = PaymentDraft(from: saloni, to: me, amountMinor: 3_850, currencyCode: "EUR", date: when, locale: de)
    #expect(payment.amountMinor(locale: de) == 3_850)
}

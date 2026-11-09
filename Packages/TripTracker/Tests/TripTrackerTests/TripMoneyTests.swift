import Foundation
import Testing
@testable import TripTracker

@Test func currencyExponents() {
    #expect(TripMoney.fractionDigits(for: "EUR") == 2)
    #expect(TripMoney.fractionDigits(for: "JPY") == 0)
    #expect(TripMoney.fractionDigits(for: "KWD") == 3)
}

@Test func formatsFromMinorUnits() {
    let us = Locale(identifier: "en_US")
    #expect(TripMoney.format(23_640, code: "EUR", locale: us) == "€236.40")
    #expect(TripMoney.format(4_800, code: "JPY", locale: us) == "¥4,800")
    #expect(TripMoney.format(4_000, code: "USD", locale: us) == "$40.00")
}

@Test func parsesACommaDecimalLocale() {
    let german = Locale(identifier: "de_DE")
    #expect(TripMoney.parse("€1.234,56", code: "EUR", locale: german) == 123_456)
    #expect(TripMoney.parse("12,5", code: "EUR", locale: german) == 1_250)
}

@Test func parsesTypedAmounts() {
    let us = Locale(identifier: "en_US")
    #expect(TripMoney.parse("$1,234.56", code: "USD", locale: us) == 123_456)
    #expect(TripMoney.parse("40", code: "EUR", locale: us) == 4_000)
    #expect(TripMoney.parse("0.105", code: "EUR", locale: us) == 11, "Extra decimals round half up")
    #expect(TripMoney.parse("4800", code: "JPY", locale: us) == 4_800)
    #expect(TripMoney.parse("4800.6", code: "JPY", locale: us) == 4_801)
    #expect(TripMoney.parse("-20", code: "USD", locale: us) == -2_000)
    #expect(TripMoney.parse("(20)", code: "USD", locale: us) == -2_000)
    #expect(TripMoney.parse("", code: "USD", locale: us) == nil)
    #expect(TripMoney.parse("abc", code: "USD", locale: us) == nil)
    #expect(TripMoney.parse("1.2.3", code: "USD", locale: us) == nil)
}

@Test func editableReadsBackThroughParse() {
    let us = Locale(identifier: "en_US")
    #expect(TripMoney.editable(0, code: "EUR", locale: us) == "")
    #expect(TripMoney.editable(123_456, code: "EUR", locale: us) == "1234.56")
    #expect(TripMoney.editable(1_250, code: "EUR", locale: us) == "12.5")
    #expect(TripMoney.editable(4_800, code: "JPY", locale: us) == "4800")
    #expect(TripMoney.parse(TripMoney.editable(123_456, code: "EUR", locale: us), code: "EUR", locale: us) == 123_456)
}

/// A POSIX "12.5" prefilled on a German phone read back as 125: the parser
/// takes "." for grouping there.
@Test func editableReadsBackInACommaDecimalLocale() {
    let german = Locale(identifier: "de_DE")
    #expect(TripMoney.editable(1_250, code: "EUR", locale: german) == "12,5")
    #expect(TripMoney.editable(123_456, code: "EUR", locale: german) == "1234,56")
    for minor: Int64 in [1_250, 23_640, 3_333, 123_456] {
        #expect(TripMoney.parse(TripMoney.editable(minor, code: "EUR", locale: german), code: "EUR", locale: german) == minor)
    }
}

@Test func codesFallBackFromExpenseToTripToLocale() {
    let us = Locale(identifier: "en_US")
    #expect(TripMoney.resolvedCode("jpy", tripCode: "EUR", locale: us) == "JPY")
    #expect(TripMoney.resolvedCode("", tripCode: "EUR", locale: us) == "EUR")
    #expect(TripMoney.resolvedCode("", tripCode: "", locale: us) == "USD")
}

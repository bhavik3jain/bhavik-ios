import Foundation
import Testing
@testable import Core

// MARK: - Counting

@Test func countsReadAsSentences() {
    #expect(counted(1, "parcel") == "1 parcel")
    #expect(counted(3, "parcel") == "3 parcels")
    #expect(counted(0, "parcel") == "0 parcels")
}

@Test func irregularPluralsCanBeSpelledOut() {
    #expect(counted(1, "entry", plural: "entries") == "1 entry")
    #expect(counted(4, "entry", plural: "entries") == "4 entries")
}

@Test func countsNeverLeaveMarkupOnScreen() {
    // The bug this replaced: inflection markup only resolves when the literal
    // reaches Text directly, so a summary built as a String showed it raw.
    let summary = "\(counted(3, "parcel")) on the way"
    #expect(!summary.contains("inflect"))
    #expect(summary == "3 parcels on the way")
}

// MARK: - Appearance

@Test func appearanceMapsToAColorScheme() {
    #expect(Appearance.system.colorScheme == nil, "System follows the device")
    #expect(Appearance.light.colorScheme == .light)
    #expect(Appearance.dark.colorScheme == .dark)
}

@Test func anUnsetOrUnknownPreferenceFollowsTheDevice() {
    #expect(Appearance.stored("") == .system, "A fresh install has no stored value")
    #expect(Appearance.stored("sepia") == .system)
    #expect(Appearance.stored("dark") == .dark)
}

@Test func everyAppearanceIsOfferable() {
    #expect(Appearance.allCases.count == 3)
    #expect(Appearance.allCases.allSatisfy { !$0.displayName.isEmpty })
}

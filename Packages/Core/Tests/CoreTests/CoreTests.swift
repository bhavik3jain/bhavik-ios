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

// MARK: - Sync status

import CloudKit

@Test func accountStatusMapsToSomethingSayable() {
    #expect(CloudSyncState(.available) == .syncing)
    #expect(CloudSyncState(.noAccount) == .signedOut)
    #expect(CloudSyncState(.restricted) == .restricted)
    #expect(CloudSyncState(.temporarilyUnavailable) == .temporarilyUnavailable)
    #expect(CloudSyncState(.couldNotDetermine) == .undetermined)
}

@Test func onlyAWorkingAccountCountsAsHealthy() {
    #expect(CloudSyncState.syncing.isHealthy)
    for state in [CloudSyncState.checking, .signedOut, .restricted, .temporarilyUnavailable, .undetermined] {
        #expect(!state.isHealthy, "\(state) must not read as syncing")
    }
}

@Test func everySyncStateExplainsItself() {
    let states: [CloudSyncState] = [.checking, .syncing, .signedOut, .restricted, .temporarilyUnavailable, .undetermined]
    for state in states {
        #expect(!state.summary.isEmpty)
        #expect(!state.explanation.isEmpty)
        #expect(!state.symbolName.isEmpty)
    }
}

@Test func aTroubledAccountSaysTheDataIsStillHere() {
    // The reader's first worry on seeing "Signed out" is whether they lost
    // anything, so the local copy is mentioned before anything else.
    #expect(CloudSyncState.signedOut.explanation.contains("still saved"))
    #expect(CloudSyncState.restricted.explanation.contains("still saved"))
}

// MARK: - CSVParser

@Test func parsesUnixLineEndings() {
    let rows = CSVParser.rows(from: "a,b\n1,2\n3,4")
    #expect(rows == [["a", "b"], ["1", "2"], ["3", "4"]])
}

@Test func parsesWindowsLineEndings() {
    // Swift folds CRLF into one Character, so a parser matching only "\n" and
    // "\r" separately never ends a row and returns the whole file as a single
    // enormous field. Real exports are CRLF, and this went unnoticed
    // because every fixture here was written with Unix endings.
    let rows = CSVParser.rows(from: "a,b\r\n1,2\r\n3,4")
    #expect(rows == [["a", "b"], ["1", "2"], ["3", "4"]])
}

@Test func parsesLoneCarriageReturns() {
    let rows = CSVParser.rows(from: "a,b\r1,2")
    #expect(rows == [["a", "b"], ["1", "2"]])
}

@Test func keepsCommasInsideQuotedFields() {
    let rows = CSVParser.rows(from: "\"a\",\"37,057\",\"$6,405.36\"")
    #expect(rows == [["a", "37,057", "$6,405.36"]])
}

@Test func stripsAByteOrderMarkFromTheFirstHeader() {
    let rows = CSVParser.rows(from: "\u{FEFF}type,title\r\nshow,Thing")
    #expect(rows.first?.first == "type")
}

import Foundation
import Testing
@testable import Core

// MARK: - Activity log

private func entry(_ outcome: SharedChangeLogEntry.Outcome, _ detail: String = "Household", module: String = "finance", at date: Date) -> SharedChangeLogEntry {
    SharedChangeLogEntry(date: date, moduleID: module, outcome: outcome, detail: detail)
}

private let start = Date(timeIntervalSince1970: 1_800_000_000)

@Test func repeatsFoldIntoOneEntryButNotificationsNeverDo() {
    var log: [SharedChangeLogEntry] = []
    log = SharedChangeActivityLog.merging(entry(.notShared, "Old trip", module: "trips", at: start), into: log)
    log = SharedChangeActivityLog.merging(entry(.notShared, "Old trip", module: "trips", at: start + 60), into: log)
    #expect(log.count == 1)
    #expect(log[0].count == 2)
    #expect(log[0].date == start + 60, "Dated by the latest")

    log = SharedChangeActivityLog.merging(entry(.posted, at: start + 120), into: log)
    log = SharedChangeActivityLog.merging(entry(.posted, at: start + 180), into: log)
    #expect(log.count == 3, "Each notification is its own line")

    log = SharedChangeActivityLog.merging(entry(.ownEdit, at: start + 200), into: log)
    log = SharedChangeActivityLog.merging(entry(.ownEdit, at: start + 200 + 16 * 60), into: log)
    #expect(log.count == 5, "Too long after the last to fold in")
    #expect(log.first?.outcome == .ownEdit, "Newest first")
}

@Test func theLogKeepsOnlyTheNewest() {
    var log: [SharedChangeLogEntry] = []
    for index in 0..<(SharedChangeActivityLog.capacity + 10) {
        log = SharedChangeActivityLog.merging(entry(.posted, "\(index)", at: start + Double(index)), into: log)
    }
    #expect(log.count == SharedChangeActivityLog.capacity)
    #expect(log.first?.detail == "\(SharedChangeActivityLog.capacity + 9)")
}

@Test func theLogSurvivesAndClears() throws {
    let defaults = try #require(UserDefaults(suiteName: "SharedChangeActivityLogTests-\(UUID().uuidString)"))
    SharedChangeActivityLog.record(entry(.posted, "Bhavik added a transaction", at: start), defaults: defaults)
    #expect(SharedChangeActivityLog.entries(defaults: defaults).map(\.summary) == ["Notified: Bhavik added a transaction"])
    SharedChangeActivityLog.clear(defaults: defaults)
    #expect(SharedChangeActivityLog.entries(defaults: defaults).isEmpty)
}

// MARK: - Health check

private func ids(_ facts: SharedChangeHealthFacts) -> [String] {
    SharedChangeHealth.problems(facts).map(\.id)
}

@Test func everythingSetUpHasNoProblems() {
    let facts = SharedChangeHealthFacts(
        permission: .allowed,
        participatingModuleIDs: ["finance"],
        serverAlertIDs: [SharedChangeServerAlertID.shared]
    )
    #expect(ids(facts).isEmpty)
}

@Test func refusedPermissionComesFirstAndBlocks() throws {
    let facts = SharedChangeHealthFacts(permission: .denied, switchOn: false, participatingModuleIDs: ["finance"])
    let problems = SharedChangeHealth.problems(facts)
    #expect(problems.map(\.id) == ["denied", "switchOff"])
    let first = try #require(problems.first)
    #expect(first.isBlocking)
    #expect(first.fix == .openSystemSettings)
}

@Test func aMissingParticipantAlertIsFound() {
    let facts = SharedChangeHealthFacts(permission: .allowed, participatingModuleIDs: ["finance"], serverAlertIDs: [])
    #expect(ids(facts) == ["serverAlerts"])

    let muted = SharedChangeHealthFacts(permission: .allowed, mutedModuleIDs: ["finance"], participatingModuleIDs: ["finance"], serverAlertIDs: [])
    #expect(ids(muted) == ["muted.finance"], "No alert is wanted for a tracker that's switched off")
}

@Test func anOwnersMissingZoneAlertIsFound() {
    let facts = SharedChangeHealthFacts(
        permission: .allowed,
        owningModuleIDs: ["finance", "trips"],
        serverAlertIDs: [SharedChangeServerAlertID.zone(moduleID: "trips", zoneName: "z1")],
        expectedOwnedAlertCount: 2
    )
    #expect(ids(facts) == ["serverAlerts"])
}

@Test func alertsArentJudgedWithoutPermissionOrWhenUnreadable() {
    // Without permission the device may not create them; that's the problem to fix first.
    #expect(ids(SharedChangeHealthFacts(permission: .notAsked, participatingModuleIDs: ["finance"], serverAlertIDs: [])) == ["notAsked"])
    let offline = SharedChangeHealthFacts(permission: .allowed, participatingModuleIDs: ["finance"], serverError: "The Internet connection appears to be offline.")
    #expect(ids(offline) == ["serverUnknown"])
}

@Test func sharingNothingIsSaidPlainly() {
    #expect(ids(SharedChangeHealthFacts(permission: .allowed)) == ["nothingShared"])
}

@Test func quietDeliveryAndHiddenBannersAreWarnings() {
    let quiet = SharedChangeHealth.problems(SharedChangeHealthFacts(permission: .quiet, participatingModuleIDs: ["fuel"], serverAlertIDs: [SharedChangeServerAlertID.shared]))
    #expect(quiet.map(\.id) == ["quiet"])
    #expect(quiet.allSatisfy { !$0.isBlocking })
    #expect(ids(SharedChangeHealthFacts(permission: .allowed, showsAlerts: false, participatingModuleIDs: ["fuel"], serverAlertIDs: [SharedChangeServerAlertID.shared])) == ["noAlerts"])
}

// MARK: - Why "Someone"

private let people = [
    ShareParticipantRecord(userRecordName: "_owner", displayName: "Bhavik", isCurrentUser: false),
    ShareParticipantRecord(userRecordName: "_partner", displayName: nil, isCurrentUser: true),
    ShareParticipantRecord(userRecordName: "_nameless", displayName: nil, isCurrentUser: false),
]

@Test func aNamedAuthorHasNoReason() {
    #expect(SharedChangeAuthorResolver.unnamedReason(lastModifiedBy: "_owner", participants: people, hasShare: true) == nil)
    #expect(SharedChangeAuthorResolver.unnamedReason(lastModifiedBy: "_partner", participants: people, hasShare: true) == nil, "Your own edit isn't 'Someone'")
}

@Test func eachWayOfEndingUpWithSomeoneSaysWhich() throws {
    let noRecord = try #require(SharedChangeAuthorResolver.unnamedReason(lastModifiedBy: nil, participants: people, hasShare: true))
    #expect(noRecord.contains("no record"))
    let noShare = try #require(SharedChangeAuthorResolver.unnamedReason(lastModifiedBy: "_owner", participants: [], hasShare: false))
    #expect(noShare.contains("no copy of the share"))
    let stranger = try #require(SharedChangeAuthorResolver.unnamedReason(lastModifiedBy: "_stranger1234", participants: people, hasShare: true))
    #expect(stranger.contains("isn't among the share's 3 known people"))
    #expect(stranger.contains("_strange…"), "Only a prefix of the ID")
    let nameless = try #require(SharedChangeAuthorResolver.unnamedReason(lastModifiedBy: "_nameless", participants: people, hasShare: true))
    #expect(nameless.contains("no name"))
}

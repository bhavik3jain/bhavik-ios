import Core
import CoreData
import Foundation
import Testing
@testable import FinanceTracker

// The report viewer's rules — stepping, Month / Year, whose figures, file
// names, and when the page and its review model are rebuilt. The views
// themselves are untested by policy; these are the value types under them.

private let nov2025 = YearMonth(year: 2025, month: 11)
private let dec2025 = YearMonth(year: 2025, month: 12)
private let jan2026 = YearMonth(year: 2026, month: 1)
private let feb2026 = YearMonth(year: 2026, month: 2)
private let mar2026 = YearMonth(year: 2026, month: 3)
private let apr2026 = YearMonth(year: 2026, month: 4)

/// February is missing, and April is open — so the default is March.
private let navigator = ReportScopeNavigator(periods: [apr2026, nov2025, dec2025, jan2026, mar2026], defaultMonth: mar2026)

// MARK: - Stepping

@Test func theStepperSkipsAGapAndStopsAtEitherEnd() {
    #expect(navigator.previous(of: .month(mar2026)) == .month(jan2026))
    #expect(navigator.next(of: .month(jan2026)) == .month(mar2026))
    #expect(navigator.next(of: .month(mar2026)) == .month(apr2026), "The open month can be looked at too")
    #expect(navigator.next(of: .month(apr2026)) == nil)
    #expect(navigator.previous(of: .month(nov2025)) == nil)
}

@Test func aYearStepsToTheNextYearWithMonths() {
    #expect(navigator.years == [2025, 2026])
    #expect(navigator.previous(of: .year(2026)) == .year(2025))
    #expect(navigator.next(of: .year(2025)) == .year(2026))
    #expect(navigator.next(of: .year(2026)) == nil)
}

@Test func switchingToAYearAndBackLandsOnTheReportedMonth() {
    #expect(navigator.switching(.month(jan2026), toYear: true) == .year(2026))
    #expect(navigator.switching(.year(2026), toYear: false) == .month(mar2026), "The reported month, not the open April")
    #expect(navigator.switching(.year(2025), toYear: false) == .month(dec2025), "A past year opens on its last month")
    #expect(navigator.switching(.month(jan2026), toYear: false) == .month(jan2026))
}

@Test func aScopeWithNoMonthFallsBackToTheReportedMonth() {
    #expect(navigator.resolved(.month(jan2026)) == .month(jan2026))
    #expect(navigator.resolved(.month(feb2026)) == .month(mar2026), "A month deleted while its report was open")
    #expect(navigator.resolved(.year(2024)) == .month(mar2026))
    #expect(navigator.resolved(nil) == .month(mar2026), "A window restored with no value")
    #expect(ReportScopeNavigator(periods: [], defaultMonth: nil).resolved(.month(mar2026)) == nil)
    #expect(ReportScopeNavigator(periods: [jan2026], defaultMonth: nil).defaultScope == .month(jan2026))
}

// MARK: - Whose

@Test func whoseFallsBackToEveryoneForANameNoOwnerHas() {
    let owners = ["Bhavik", "Saloni", "Joint"]
    #expect(ReportOwnerChoice.preferred.ownerName(preferred: "Saloni", available: owners) == "Saloni")
    #expect(ReportOwnerChoice.preferred.ownerName(preferred: nil, available: owners) == nil)
    #expect(ReportOwnerChoice.preferred.ownerName(preferred: "Sam", available: owners) == nil, "A renamed owner reads as Everyone")
    #expect(ReportOwnerChoice.everyone.ownerName(preferred: "Saloni", available: owners) == nil)
    #expect(ReportOwnerChoice.named("Joint").ownerName(preferred: "Saloni", available: owners) == "Joint")
    #expect(ReportOwnerChoice(ownerName: nil) == .everyone)
    #expect(ReportOwnerChoice(nil as OwnerFilter?) == .preferred)
    #expect(ReportOwnerChoice(OwnerFilter.all) == .everyone)
}

@Test @MainActor func whoseResolvesToTheOwnersFilter() throws {
    let household = ReportDataFixture.household()
    let saloni = try #require(ReportDataFixture.owner("Saloni", in: household))
    let owners = household.sortedOwners
    #expect(ReportOwnerChoice.named("Saloni").filter(preferred: nil, owners: owners) == .owner(saloni))
    #expect(ReportOwnerChoice.preferred.filter(preferred: "Nobody", owners: owners) == .all)
    #expect(ReportOwnerChoice(OwnerFilter.owner(saloni)) == .named("Saloni"))
}

// MARK: - Names

@Test func filesAreNamedForTheScopeAndPerson() {
    let september = YearMonth(year: 2026, month: 9)
    #expect(ReportNaming.documentName(for: .month(september), ownerName: nil) == "\(september.title) Report")
    #expect(ReportNaming.documentName(for: .month(september), ownerName: "Saloni") == "\(september.title) Report (Saloni)")
    #expect(ReportNaming.documentName(for: .year(2026), ownerName: nil) == "2026 Year in Review")
    #expect(ReportNaming.documentName(for: .year(2026), ownerName: " ") == "2026 Year in Review")
    #expect(ReportNaming.shortTitle(for: .month(september)) == "\(september.monthName) report")
    #expect(ReportNaming.deviceName(for: .sidebar) == "this Mac")
    #expect(ReportNaming.deviceName(for: .tabs) == "this iPhone")
}

// MARK: - The page

@MainActor
private func seededHousehold() throws -> SharedFinanceHousehold {
    let household = ReportDataFixture.emptyHousehold()
    let context = try #require(household.managedObjectContext)
    FinanceDebugSeed.run(context: context, container: nil, asOf: ReportDataFixture.now)
    return try #require(try context.fetch(SharedFinanceHousehold.fetchRequest()).first { !$0.isEmpty })
}

@MainActor
private func report(_ household: SharedFinanceHousehold, asOf now: Date = ReportDataFixture.now) throws -> FinanceReportData {
    let scope = try #require(FinanceReportData.defaultScope(for: household, live: nil))
    return try #require(FinanceReportData.build(scope: scope, household: household, live: nil, deviceName: "this iPhone", asOf: now))
}

@Test @MainActor func thePageShowsAtOnceWithThePlainReviewAndWithoutOneWhenLeftOut() throws {
    let data = try report(try seededHousehold())
    let session = ReportSession()
    #expect(session.html(options: .init()) == nil)

    session.show(data)
    let model = try #require(session.model)
    #expect(session.pageReview(includeReview: true) == model.plainReview, "Never held back for the model")
    #expect(session.pageReview(includeReview: false) == nil)

    let html = try #require(session.html(options: .init()))
    #expect(html.contains("id=\"networth\""))
    #expect(html.contains("id=\"brief\""))
    #expect(session.html(options: .init()) == html)
    let without = try #require(session.html(options: .init(includeTables: true, includeReview: false)))
    #expect(!without.contains("id=\"brief\""))
    #expect(!session.sections(options: .init(includeTables: true, includeReview: false)).contains { $0.id == "brief" })
    #expect(session.sections(options: .init()).first?.id == "brief")
}

@Test @MainActor func theReviewModelSurvivesARebuildThatTellsItTheSameFacts() throws {
    let household = try seededHousehold()
    let session = ReportSession()
    session.show(try report(household))
    let model = try #require(session.model)

    // Built a minute later: a different value, the same facts.
    let later = try report(household, asOf: ReportDataFixture.now.addingTimeInterval(60))
    #expect(later != session.data)
    session.show(later)
    #expect(session.data == later)
    #expect(session.model === model)

    // A scope with other facts gets a model of its own.
    let year = try #require(FinanceReportData.build(scope: .year(2026), household: household, live: nil, deviceName: "this iPhone", asOf: ReportDataFixture.now))
    session.show(year)
    #expect(session.model !== model)
    #expect(session.model?.scope == .year(2026))

    session.show(nil)
    #expect(session.model == nil)
    #expect(session.html(options: .init()) == nil)
}

@Test @MainActor func withTheModelOffThePageKeepsTheChecksWording() async throws {
    let session = ReportSession()
    session.show(try report(try seededHousehold()))
    await session.startReview(advisor: StubFinanceAdvisor(), enabled: false)
    let model = try #require(session.model)
    #expect(model.state == .plain(model.plainReview))
    #expect(session.pageReview(includeReview: true) == model.plainReview)
    #expect(session.pageReview(includeReview: true)?.isWrittenByModel == false)
}

@Test @MainActor func theShareFileIsThePageUnderTheReportsName() throws {
    let session = ReportSession()
    session.show(try report(try seededHousehold()))
    let html = try #require(session.html(options: .init()))
    session.prepareShareFile(html: html, name: "September 2026 Report")
    let file = try #require(session.shareFile)
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    #expect(file.lastPathComponent == "September 2026 Report.html")
    #expect(try String(contentsOf: file, encoding: .utf8) == html)

    // The same page isn't written again.
    session.prepareShareFile(html: html, name: "September 2026 Report")
    #expect(session.shareFile == file)
}

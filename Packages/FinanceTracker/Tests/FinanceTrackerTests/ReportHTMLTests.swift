import Foundation
import Testing
@testable import FinanceTracker

// The report page is a pure function of `FinanceReportData`, so these build
// real reports from the same fixtures as ReportDataTests and read the HTML.

@MainActor
private func seededReport(_ scope: ReportScope? = nil) throws -> FinanceReportData {
    let household = ReportDataFixture.emptyHousehold()
    let context = try #require(household.managedObjectContext)
    FinanceDebugSeed.run(context: context, container: nil, asOf: ReportDataFixture.now)
    let seeded = try #require(try context.fetch(SharedFinanceHousehold.fetchRequest()).first { !$0.isEmpty })
    let resolved = try #require(scope ?? FinanceReportData.defaultScope(for: seeded, live: nil))
    return try #require(ReportDataFixture.report(resolved, seeded))
}

private let sampleBrief = FinanceReportHTML.ReviewBlock(
    headline: "A steady September.",
    wentWell: ["Groceries came in under budget."],
    watch: ["Food went over."],
    tryNext: ["Update the HSA."],
    isModelWritten: true
)

// MARK: - Sections

@Test @MainActor func everySectionTheViewerListsIsOnThePage() throws {
    let data = try seededReport()
    let withBrief = FinanceReportHTML.render(data, brief: sampleBrief)
    let listed = FinanceReportHTML.sections(for: data, brief: sampleBrief)
    #expect(listed.map(\.id) == data.sections.map(\.id))
    for id in ["brief", "networth", "figures", "mix", "moved", "trend", "accounts", "metals", "spending", "cards", "fixing"] {
        #expect(listed.contains { $0.id == id }, "The seed fills \(id)")
    }
    for section in listed {
        #expect(withBrief.contains("id=\"\(section.id)\""), "No #\(section.id) on the page")
    }

    let withoutBrief = FinanceReportHTML.render(data, brief: nil)
    let listedWithout = FinanceReportHTML.sections(for: data, brief: nil)
    #expect(!listedWithout.contains { $0.id == "brief" }, "Jump to Section can't offer a brief the page doesn't have")
    for section in listedWithout {
        #expect(withoutBrief.contains("id=\"\(section.id)\""), "No #\(section.id) on the page")
    }
    #expect(withBrief.hasPrefix("<!doctype html>"))
    #expect(withBrief.contains("<title>\(data.header.title) report</title>"))
}

@Test @MainActor func thePageCarriesTheReportsOwnFigures() throws {
    let data = try seededReport()
    let html = FinanceReportHTML.render(data, brief: nil)
    #expect(html.contains(data.hero.netWorthText))
    #expect(html.contains(FinanceReportHTML.escape(data.hero.deltaLine)))
    for kpi in data.kpis {
        #expect(html.contains(FinanceReportHTML.escape(kpi.valueText)))
    }
    for finding in data.worthFixing {
        #expect(html.contains(FinanceReportHTML.escape(finding.title)), "Worth fixing lists \(finding.id)")
    }
    for line in data.moved {
        #expect(html.contains(FinanceReportHTML.escape(line.impactText)))
    }
    for merchant in data.spending.topMerchants {
        #expect(html.contains(FinanceReportHTML.escape(merchant.name)))
    }
}

// MARK: - Escaping

@Test @MainActor func everyNameFromTheHouseholdIsEscaped() throws {
    let fixture = ReportDataFixture.standard()
    fixture.checking.name = "<script>alert(\"x\")</script> & Co"
    ReportDataFixture.charge(
        fixture.household, ReportDataFixture.september, day: 20, 120,
        "<img src=x onerror=alert(1)>", "Food & Drink", on: fixture.travelCard
    )
    try fixture.household.managedObjectContext?.save()
    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), fixture.household))
    let brief = FinanceReportHTML.ReviewBlock(
        headline: "Net worth <b>rose</b> & held",
        wentWell: ["\"Quoted\" & <i>styled</i>"],
        watch: [],
        tryNext: [],
        isModelWritten: false
    )
    let html = FinanceReportHTML.render(data, brief: brief)

    #expect(!html.contains("<script"), "A typed name must never become markup")
    #expect(!html.contains("<img"))
    #expect(!html.contains("<b>rose"))
    #expect(!html.contains("<i>styled"))
    #expect(html.contains("&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt; &amp; Co"))
    #expect(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
    #expect(html.contains("Food &amp; Drink"))
    #expect(html.contains("Net worth &lt;b&gt;rose&lt;/b&gt; &amp; held"))
    #expect(html.contains("&quot;Quoted&quot; &amp; &lt;i&gt;styled&lt;/i&gt;"))
}

@Test func escapingCoversContentAndAttributes() {
    #expect(FinanceReportHTML.escape("a<b>&\"c'") == "a&lt;b&gt;&amp;&quot;c&#39;")
    #expect(FinanceReportHTML.escape("Saloni’s café") == "Saloni’s café")
}

// MARK: - The review

@Test @MainActor func theBriefIsLeftOutWhenThereIsNoneOrItIsTurnedOff() throws {
    let data = try seededReport()
    let none = FinanceReportHTML.render(data, brief: nil)
    #expect(!none.contains("id=\"brief\""))
    #expect(!none.contains("The month in brief"))

    let turnedOff = FinanceReportHTML.render(data, brief: sampleBrief, options: .init(includeReview: false))
    #expect(!turnedOff.contains("id=\"brief\""))
    #expect(!turnedOff.contains(sampleBrief.headline))
    #expect(!FinanceReportHTML.sections(for: data, brief: sampleBrief, options: .init(includeReview: false)).contains { $0.id == "brief" })

    let empty = FinanceReportHTML.ReviewBlock(headline: " ", wentWell: [], watch: [], tryNext: [], isModelWritten: true)
    #expect(!FinanceReportHTML.render(data, brief: empty).contains("id=\"brief\""), "An empty review is no brief")

    let shown = FinanceReportHTML.render(data, brief: sampleBrief)
    #expect(shown.contains("The month in brief"))
    #expect(shown.contains(sampleBrief.headline))
    #expect(shown.contains("Went well") && shown.contains("To watch"))
    #expect(shown.contains("Try in \(data.period.next.monthName)"))
    #expect(shown.contains("by Apple Intelligence"))
    #expect(shown.contains("Figures in the brief were checked"))

    var plain = sampleBrief
    plain.isModelWritten = false
    let plainPage = FinanceReportHTML.render(data, brief: plain)
    #expect(!plainPage.contains("Apple Intelligence from the figures"), "Swift's own wording never claims the model wrote it")
    #expect(plainPage.contains("the app’s own checks"))
    #expect(plainPage.contains("card brief plain"))
}

// MARK: - Budgets

/// A category at `SharedFinanceBudget.noLimit` is a no-budget chip; builds
/// from before the sentinel read it as a -$1 budget, always over.
@Test @MainActor func noBudgetIsAChipNeverAMinusOneDollarBudget() throws {
    let fixture = ReportDataFixture.standard()
    let data = try #require(ReportDataFixture.report(.month(ReportDataFixture.september), fixture.household))
    let html = FinanceReportHTML.render(data, brief: nil)
    #expect(html.contains("No budget · $120 in 2 categories"))
    #expect(html.contains("<span class=\"chip\" title=\"Kept with “No budget”\">Clothes $80</span>"))
    #expect(html.contains(">Car $40</span>"))
    #expect(html.contains("$350 of $300 · $50 over"))
    let minusOne = try NSRegularExpression(pattern: "[-−]\\$1(?![0-9,.])")
    #expect(minusOne.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) == nil, "Never a -$1 budget")
    #expect(!html.contains(">Clothes</span><span"), "Clothes is not a budget line")
}

// MARK: - Year in review

@Test @MainActor func aYearInReviewRendersItsOwnSections() throws {
    let data = try seededReport(.year(2026))
    let html = FinanceReportHTML.render(data, brief: sampleBrief)
    #expect(html.contains("<h1>2026 in review</h1>"))
    #expect(html.contains("The year in brief"))
    #expect(html.contains("Try in 2027"))
    #expect(html.contains("Budgets, month by month"))
    #expect(html.contains("By category"))
    #expect(html.contains("class=\"cols-chart\""))
    #expect(html.contains("This year"))
    for section in FinanceReportHTML.sections(for: data, brief: sampleBrief) {
        #expect(html.contains("id=\"\(section.id)\""), "No #\(section.id) on the year page")
    }
    let year = try #require(data.year)
    for row in year.months {
        #expect(html.contains(FinanceReportHTML.escape(row.label)))
    }
    #expect(!html.contains("vs 3-month average"), "A year has no three-month average")
}

// MARK: - Self-contained

@Test @MainActor func thePageLoadsNothingAndTablesFollowTheOption() throws {
    let data = try seededReport()
    let html = FinanceReportHTML.render(data, brief: sampleBrief)
    #expect(!html.contains("http://") && !html.contains("https://"), "No network requests, no links out")
    #expect(!html.contains("<script"))
    #expect(!html.contains(" src="))
    #expect(!html.contains("url("))
    #expect(html.contains("Content-Security-Policy"))
    #expect(html.contains("prefers-color-scheme:dark"))
    #expect(html.contains("print-color-adjust:exact"), "Bars vanish from a PDF without it")
    #expect(html.contains("<details>"))

    let noTables = FinanceReportHTML.render(data, brief: sampleBrief, options: .init(includeTables: false))
    #expect(!noTables.contains("<details>"))
    #expect(noTables.contains("Top merchants"), "The merchant table is part of the page, not a table view")
}

// MARK: - Helpers

@Test func axisTicksAreRoundAndCoverEveryValue() {
    let ticks = FinanceReportHTML.niceTicks([331_240, 352_000, 387_675])
    #expect(ticks.first! <= 331_240 && ticks.last! >= 387_675)
    #expect(ticks == ticks.sorted())
    let steps = Set(zip(ticks.dropFirst(), ticks).map { $0 - $1 })
    #expect(steps.count == 1, "Evenly spaced")
    #expect(steps.first == 20_000)

    let flat = FinanceReportHTML.niceTicks([5_000, 5_000])
    #expect(flat.first! < 5_000 && flat.last! > 5_000, "A flat line sits mid-chart")
    #expect(FinanceReportHTML.niceTicks([]) == [0, 1])
}

@Test func cssPercentagesAlwaysUseAPoint() {
    #expect(FinanceReportHTML.percent(0.125) == "12.50%")
    #expect(FinanceReportHTML.percent(1.4) == "100.00%")
    #expect(FinanceReportHTML.percent(-0.2) == "0.00%")
    #expect(FinanceReportHTML.percent(.nan) == "0%")
}

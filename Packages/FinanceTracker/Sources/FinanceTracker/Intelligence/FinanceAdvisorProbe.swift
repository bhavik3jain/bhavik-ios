#if DEBUG
import Core
import CoreData
import Foundation

/// `-FinanceAdvisorProbe YES` (Debug): the whole report engine — the seeded
/// household's report data, `MonthCheck`, the `ReportBrief` the model reads,
/// a streamed review checked by `ReportReview`, an "Ask" answer checked by
/// `AskReply`, then the same for the year in review — printed as it goes, with
/// both HTML reports written to the caches directory and their paths printed.
///
/// Like `-TripAdvisorProbe`, it's the way to watch the real model answer
/// without the UI and without going near real figures: the app opens only
/// in-memory stores for this launch (see `BhavikApp.init`), and the probe
/// fills the Finance one with `FinanceDebugSeed`. `-FinanceAdvisorStub YES`
/// swaps in `StubFinanceAdvisor`; `-FinanceAdvisorProbeQuit YES` quits after.
///
/// The same `run` is exercised by the tests against the stub, so the probe
/// itself can't rot.
public enum FinanceAdvisorProbe {
    public static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "FinanceAdvisorProbe")
    }

    static var quitsWhenDone: Bool {
        UserDefaults.standard.bool(forKey: "FinanceAdvisorProbeQuit")
    }

    /// What the app shell calls once the in-memory Finance container exists:
    /// picks the advisor (the stub with `-FinanceAdvisorStub YES`), runs, and
    /// prints every line to stdout unbuffered.
    @MainActor
    public static func start(context: NSManagedObjectContext, container: NSPersistentCloudKitContainer?) {
        let advisor: any FinanceAdvising = StubFinanceAdvisor.isRequested ? StubFinanceAdvisor() : FinanceAdvisors.makeDefault()
        let model: String
        if #available(iOS 26.0, macOS 26.0, *) {
            model = FoundationModelsFinanceAdvisor.modelDescription
        } else {
            model = "no Foundation Models on this system"
        }
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FinanceAdvisorProbe", isDirectory: true)
        Task { @MainActor in
            _ = await run(context: context, container: container, advisor: advisor, modelDescription: model, htmlDirectory: directory) { line in
                print(line)
                fflush(stdout)
            }
            print("FinanceAdvisorProbe: done")
            fflush(stdout)
            if quitsWhenDone { exit(0) }
        }
    }

    /// Seeds (a no-op if the store already has a household with data), runs
    /// everything once and returns the report; `log` hears each line as it's
    /// written, so a slow model shows progress.
    ///
    /// - Parameters:
    ///   - modelDescription: what the app knows about the model — read there,
    ///     not here, so a test with the stub never asks the system.
    ///   - htmlDirectory: where the reports are written; nil writes none.
    @MainActor
    public static func run(
        context: NSManagedObjectContext,
        container: NSPersistentCloudKitContainer?,
        advisor: any FinanceAdvising,
        modelDescription: String = "",
        htmlDirectory: URL? = nil,
        asOf now: Date = .now,
        log: (String) -> Void = { _ in }
    ) async -> String {
        var report: [String] = []
        func say(_ line: String) {
            report.append(line)
            log(line)
        }

        say("FinanceAdvisorProbe: advisor \(type(of: advisor)), availability \(advisor.availability)")
        if !modelDescription.isEmpty { say("FinanceAdvisorProbe: model \(modelDescription)") }

        FinanceDebugSeed.run(context: context, container: container, asOf: now)
        let household = FinanceHouseholdResolver.forWriting(in: context, container: container)
        guard let scope = FinanceReportData.defaultScope(for: household, live: nil),
              let data = FinanceReportData.build(scope: scope, household: household, live: nil, deviceName: "Probe", asOf: now)
        else {
            say("no report: the household has no months")
            return report.joined(separator: "\n")
        }

        await probe(data, advisor: advisor, htmlDirectory: htmlDirectory, say: say)

        if let year = FinanceReportData.reportYears(in: household.sortedMonths).first,
           let yearData = FinanceReportData.build(scope: .year(year), household: household, live: nil, deviceName: "Probe", asOf: now) {
            say("")
            await probe(yearData, advisor: advisor, htmlDirectory: htmlDirectory, say: say)
        }
        return report.joined(separator: "\n")
    }

    @MainActor
    private static func probe(_ data: FinanceReportData, advisor: any FinanceAdvising, htmlDirectory: URL?, say: (String) -> Void) async {
        let clock = ContinuousClock()
        say("######## \(data.header.title) · \(data.header.ownerLabel) ########")
        say(data.header.coverageNote)

        say("")
        say("== Check: \(data.findings.count) findings (\(data.toneCounts.label)) ==")
        for finding in data.findings.sorted(by: { $0.weight > $1.weight }) {
            say("- [\(finding.tone.rawValue)\(finding.isWorthFixing ? ", worth fixing" : "")] \(finding.plainText)")
            if let fix = finding.fix { say("    fix: \(fix.title)") }
        }

        let brief = ReportBrief(data: data)
        let prompt = brief.prompt(maxTokens: ReportBrief.promptBudget(contextSize: 4_096))
        say("")
        say("== ReportBrief: \(brief.facts.count) facts, ~\(ReportBrief.estimatedTokens(prompt)) tokens (estimate) ==")
        say(prompt)
        if #available(iOS 26.0, macOS 26.0, *), advisor is FoundationModelsFinanceAdvisor {
            say("what the model is sent: \(await FoundationModelsFinanceAdvisor.fittedPromptReport(for: brief))")
        }

        say("")
        say("== Review (streamed) ==")
        advisor.prewarm()
        let started = clock.now
        var firstHeadline: Duration?
        var snapshots = 0
        var last: ReportReviewDraft?
        do {
            for try await draft in advisor.review(brief) {
                snapshots += 1
                if firstHeadline == nil, !(draft.headline ?? "").isEmpty { firstHeadline = clock.now - started }
                last = draft
            }
            say("first headline text after \(firstHeadline.map(seconds) ?? "-"), complete after \(seconds(clock.now - started)), \(snapshots) snapshots")
        } catch {
            say("review failed after \(seconds(clock.now - started)): \(error) — the sheet would show the check's own words")
        }
        if let last {
            say("model's headline: \(last.headline ?? "(none)")")
            for note in last.notes {
                let fact = brief.fact(numbered: note.fact)
                let verdict = fact.map { ReportReview.isFaithful(note.message, to: $0, in: brief) ? "kept" : "dropped" } ?? "no such fact"
                say("  note on \(note.fact) [\(verdict)]: \(note.message)")
            }
        }
        var final = last
        final?.isComplete = true
        let review = ReportReview(findings: data.findings, scope: data.scope, brief: brief, draft: final)
        say("")
        say("headline [\(review.isHeadlineWrittenByModel ? "model" : "check")]: \(review.headline)")
        for group in review.groups {
            say("-- \(review.title(for: group))")
            for item in review.items(in: group) {
                say("- [\(item.isWrittenByModel ? "model" : "check")] \(item.text)\(item.fix.map { "  → \($0.title)" } ?? "")")
            }
        }

        let questions = AskReply.suggestedQuestions(for: data)
        say("")
        say("== Ask about \(data.scope.shortTitle) ==")
        say("suggested: \(questions.joined(separator: " | "))")
        for question in questions.prefix(2) + ["Should we sell the gold?"] {
            var answer = ""
            let askStarted = clock.now
            do {
                for try await text in advisor.answer(question: question, brief: brief) { answer = text }
            } catch {
                say("answer failed: \(error)")
            }
            let reply = AskReply(question: question, answer: answer, brief: brief, isComplete: true)
            say("Q: \(question)")
            if !answer.isEmpty, !reply.isWrittenByModel { say("   model said (rejected): \(answer)") }
            say("A [\(reply.isWrittenByModel ? "model" : "fallback"), \(seconds(clock.now - askStarted))]: \(reply.text)")
        }

        if let htmlDirectory {
            let html = FinanceReportHTML.render(data, review: review)
            let url = htmlDirectory.appendingPathComponent("\(data.scope.title) Report.html")
            do {
                try FileManager.default.createDirectory(at: htmlDirectory, withIntermediateDirectories: true)
                try html.write(to: url, atomically: true, encoding: .utf8)
                say("")
                say("HTML report (\(html.utf8.count) bytes): \(url.path)")
            } catch {
                say("couldn't write the HTML report: \(error)")
            }
        }
    }

    static func seconds(_ duration: Duration) -> String {
        let components = duration.components
        let value = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.1f s", value)
    }
}
#endif

import Core
import CoreData
import SwiftUI

/// The last step of finishing a month, shown once Close has saved it:
/// "September is finished", what was saved with it, its report to open or
/// share, and — with Apple Intelligence on and Settings' "Review when
/// finishing a month" — the review, written while this screen is up.
///
/// The figures are the household's (Everyone): finishing a month is a
/// household event. The report it opens follows Settings' "Whose by default".
struct MonthFinishedView: View {
    @ObservedObject var month: SharedFinanceMonth

    @Environment(\.dismiss) private var dismiss
    @Environment(\.moduleLayout) private var layout
    @Environment(\.financeAdvisor) private var advisor
    @Environment(\.financeAdvisorEnabled) private var advisorEnabled
    @Environment(\.financeReportPreferences) private var preferences
    var data = FinanceFetches()

    @State private var session = ReportSession()
    @State private var builtAt = Date.now
    @State private var reportRequest: FinanceReportWindowValue?
    @State private var showsReview = false

    /// The model writes the review here only when it can and the person
    /// asked for it on finishing.
    private var writesReview: Bool {
        preferences.reviewOnFinish && advisor.availability(isEnabled: advisorEnabled) == .available
    }

    var body: some View {
        let snapshot = data.snapshot
        let report: FinanceReportData? = month.period.flatMap { period in
            snapshot.household.flatMap { household in
                FinanceReportData.build(
                    scope: .month(period),
                    household: household,
                    filter: .all,
                    live: snapshot.live,
                    deviceName: ReportNaming.deviceName(for: layout),
                    asOf: builtAt
                )
            }
        }
        SheetStack {
            MonthFinishedContent(
                month: month,
                session: session,
                progress: snapshot.progress(of: month),
                deviceName: ReportNaming.deviceName(for: layout),
                builtAt: builtAt,
                showsReviewRow: writesReview,
                openReport: openReport,
                openReview: { showsReview = true }
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onChange(of: report, initial: true) { _, report in
            session.show(report)
        }
        .task(id: ReviewStart(model: session.modelID, isWanted: writesReview, enabled: advisorEnabled)) {
            guard writesReview else { return }
            await session.startReview(advisor: advisor, enabled: advisorEnabled)
        }
        .presentsReport($reportRequest)
        .sheet(isPresented: $showsReview) {
            // The model this screen started, so the review isn't written twice.
            if let model = session.model {
                ReviewSheet(model: model)
                    // No switching the module's tab from here: "Open Gold &
                    // Silver" dismissed only the review and switched Finance
                    // to Holdings underneath this screen, which stayed on top,
                    // so the fix seemed to do nothing. Unavailable, it opens
                    // Holdings in a sheet over the review instead.
                    .environment(\.openFinanceSection, OpenFinanceSectionAction(nil))
            }
        }
    }

    private func openReport() {
        guard let period = month.period else { return }
        reportRequest = FinanceReportWindowValue(scope: .month(period), ownerName: preferences.defaultOwnerName)
    }
}

private struct MonthFinishedContent: View {
    @ObservedObject var month: SharedFinanceMonth
    let session: ReportSession
    let progress: MonthProgress
    let deviceName: String
    let builtAt: Date
    let showsReviewRow: Bool
    let openReport: () -> Void
    let openReview: () -> Void

    @Environment(\.financeReportPreferences) private var preferences

    private var accent: Color { FinanceTrackerModule.accent.color }

    var body: some View {
        let report = session.data
        // The shared file carries the page as it is now, review and all, with
        // table views only if Settings' "Table views in shared reports" says so.
        let html = session.html(options: FinanceReportHTML.Options(includeTables: preferences.includeTables))
        Form {
            Section {
                header(report)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Balances", value: progress.label)
                if let report, !report.metals.items.isEmpty {
                    LabeledContent("Gold · silver", value: "\(Self.price(month.goldPricePerOz)) · \(Self.price(month.silverPricePerOz)) an oz")
                }
                if let report {
                    LabeledContent("Spent", value: "\(report.spending.totalText) · \(counted(report.spending.transactionCount, "transaction"))")
                }
            }
            .monospacedDigit()

            if let report {
                Section {
                    reportCard(report, html: html)
                }
            }

            if showsReviewRow, let model = session.model {
                Section {
                    Button(action: openReview) {
                        ReviewReadyRow(model: model)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .task(id: html) {
            guard let html, let report else { return }
            session.prepareShareFile(html: html, name: ReportNaming.documentName(for: report.scope, ownerName: nil))
        }
    }

    private func header(_ report: FinanceReportData?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(accent, in: Circle())
                .accessibilityHidden(true)
            Text("\(month.monthName) is finished")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text("Its balances and metal prices are saved, so \(month.monthName) won't change when gold does.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let hero = report?.hero {
                HStack(spacing: 5) {
                    Text(hero.netWorthText)
                        .fontWeight(.semibold)
                    if let deltaText = hero.deltaText, let delta = hero.delta {
                        Text(deltaText)
                            .fontWeight(.semibold)
                            .foregroundStyle(delta < 0 ? Color.red : accent)
                        if let name = hero.comparisonName {
                            Text("on \(name)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .monospacedDigit()
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func reportCard(_ report: FinanceReportData, html: String?) -> some View {
        let sections = session.sections(options: FinanceReportHTML.Options())
        let built = builtAt.formatted(.relative(presentation: .named))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ReportThumbnail(mix: report.mix)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ReportNaming.shortTitle(for: report.scope))
                        .font(.headline)
                    Text("\(counted(sections.count, "section")) · built on \(deviceName) \(built)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button(action: openReport) {
                    Text("Open Report")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .primaryActionStyle(tint: accent)
                .controlSize(.large)

                if let file = session.shareFile {
                    ShareLink(item: file, preview: SharePreview(ReportNaming.documentName(for: report.scope, ownerName: nil))) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(accent)
                }
            }
        }
        .padding(.vertical, 6)
    }

    /// "$4,420" for gold, "$50.50" for silver — cents only where they say something.
    static func price(_ value: Double) -> String {
        value >= 1_000 ? FinanceFormat.money(value) : FinanceFormat.cents(value)
    }
}

/// "Review is ready · 3 went well · 2 to watch · 2 to try", or the model
/// still writing it.
private struct ReviewReadyRow: View {
    let model: ReportReviewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.purple)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isWriting ? "Writing the review…" : "Review is ready")
                    .font(.headline)
                Text(model.counts.label.isEmpty ? "Nothing stood out" : model.counts.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if model.isWriting {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(.rect)
        .padding(.vertical, 4)
    }
}

/// A page in miniature: the report's own colours for where the money sits.
private struct ReportThumbnail: View {
    let mix: [FinanceReportData.MixLine]

    /// The page's `--s1`…`--s6` series colours, light.
    private static let series: [Color] = [
        Color(red: 0.91, green: 0.48, blue: 0.64),
        Color(red: 0.93, green: 0.63, blue: 0.00),
        Color(red: 0.92, green: 0.41, blue: 0.20),
        Color(red: 0.11, green: 0.69, blue: 0.48),
        Color(red: 0.16, green: 0.47, blue: 0.84),
        Color(red: 0.54, green: 0.36, blue: 0.84),
    ]

    var body: some View {
        let total = mix.reduce(0) { $0 + max($1.value, 0) }
        VStack(alignment: .leading, spacing: 4) {
            Capsule().fill(.tertiary).frame(width: 26, height: 4)
            RoundedRectangle(cornerRadius: 2).fill(.primary).frame(width: 36, height: 8)
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    ForEach(mix.prefix(4), id: \.name) { line in
                        Rectangle()
                            .fill(Self.series[(line.colorIndex - 1 + Self.series.count) % Self.series.count])
                            .frame(width: total > 0 ? proxy.size.width * max(line.value, 0) / total : 0)
                    }
                }
            }
            .frame(height: 6)
            ForEach([0.9, 0.7, 0.8], id: \.self) { width in
                Capsule().fill(.quaternary).frame(width: 42 * width, height: 3)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 8)
        .frame(width: 58, height: 76, alignment: .topLeading)
        .background(.background, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .accessibilityHidden(true)
    }
}

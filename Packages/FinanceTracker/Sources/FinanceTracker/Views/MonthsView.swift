import Charts
import Core
import CoreData
import SwiftUI

/// Every month, newest first, with one figure charted across them. + starts
/// the next month, every balance at zero.
struct MonthsView: View {
    @Environment(\.moduleLayout) private var layout
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    @Environment(\.financeReportPreferences) private var reportPreferences
    var data = FinanceFetches()

    @AppStorage("finance.monthsMetric") private var metricRaw = FinanceMetric.netWorth.rawValue
    @State private var pendingDelete: SharedFinanceMonth?
    /// The month the Mac's table opened by double-click.
    @State private var opened: SharedFinanceMonth?
    /// A month's report or a year in review: the viewer on the phone, a
    /// window of its own on the Mac.
    @State private var reportRequest: FinanceReportWindowValue?

    private var metric: FinanceMetric { FinanceMetric(rawValue: metricRaw) ?? .netWorth }

    var body: some View {
        let snapshot = data.snapshot
        let isEditable = snapshot.canEdit
        NavigationStack {
            Group {
                if snapshot.months.isEmpty {
                    ContentUnavailableView {
                        Label("No months yet", systemImage: "calendar")
                    } description: {
                        Text("Each month is a snapshot of every balance. Start one to begin.")
                    } actions: {
                        if isEditable {
                            Button("Start \(YearMonth(containing: .now).title)") { startNextMonth() }
                                .primaryActionStyle(tint: FinanceTrackerModule.accent.color)
                        } else if snapshot.isWaitingForICloud {
                            ProgressView("Checking iCloud…")
                        }
                    }
                    .scrollsForRefresh()
                } else {
                    list(snapshot, isEditable: isEditable)
                }
            }
            .refreshesFromCloud()
            .navigationTitle("Months")
            .toolbar {
                if layout == .sidebar {
                    ToolbarItem(placement: .primaryAction) {
                        Picker(selection: $metricRaw) {
                            ForEach(FinanceMetric.allCases) { option in
                                Text(option.displayName).tag(option.rawValue)
                            }
                        } label: {
                            Label("Show", systemImage: "chart.bar")
                        }
                        .pickerStyle(.menu)
                        .help("What the chart shows")
                    }
                    let years = FinanceReportData.reportYears(in: snapshot.months)
                    if !years.isEmpty {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                ForEach(years, id: \.self) { year in
                                    Button("\(String(year)) in Review") { viewReport(.year(year)) }
                                }
                            } label: {
                                Label("Year in Review", systemImage: "calendar.badge.clock")
                            }
                            .help("A year's report: net worth, spending and budgets month by month")
                        }
                    }
                }
            }
            .toolbar {
                if isEditable {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            startNextMonth()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(nextMonthLabel(snapshot))
                    }
                }
            }
            .presentsReport($reportRequest)
            .confirmationDialog(
                "Delete \(pendingDelete?.title ?? "month")?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Month", role: .destructive) {
                    if let pendingDelete { context.delete(pendingDelete) }
                    pendingDelete = nil
                    try? context.saveIfNeeded()
                }
            } message: {
                Text("Its balances, prices and budgets go with it. Transactions stay — they belong to their cards.")
            }
        }
    }

    @ViewBuilder
    private func list(_ snapshot: FinanceSnapshot, isEditable: Bool) -> some View {
        if layout == .sidebar {
            MacMonthsView(
                history: snapshot.history(),
                metric: metric,
                isEditable: isEditable,
                open: { opened = $0 },
                viewReport: { month in month.period.map { viewReport(.month($0)) } },
                delete: { pendingDelete = $0 }
            )
            .navigationDestination(item: $opened) { MonthEntryView(month: $0) }
            .debugOpensFirstItem { opened = data.snapshot.latestMonth }
        } else {
            phoneList(snapshot, isEditable: isEditable)
        }
    }

    private func phoneList(_ snapshot: FinanceSnapshot, isEditable: Bool) -> some View {
        let history = snapshot.history()
        let series = history.series(metric)
        return List {
            Section {
                // On the Mac this is a toolbar menu, not a list row.
                if layout == .tabs {
                    Picker("Show", selection: $metricRaw) {
                        ForEach(FinanceMetric.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }

                if !series.isEmpty {
                    MonthsChart(series: series, metric: metric)
                        .frame(height: 160)
                        .padding(.vertical, 6)
                }
            }

            Section {
                ForEach(Array(history.points.reversed())) { point in
                    NavigationLink {
                        MonthEntryView(month: point.month)
                    } label: {
                        MonthRow(
                            month: point.month,
                            value: point.summary.value(for: metric),
                            delta: history.delta(metric, at: point.period),
                            upIsGood: metric != .cardSpend
                        )
                    }
                    .swipeActions(edge: .trailing) {
                        if isEditable {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                pendingDelete = point.month
                            }
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Report", systemImage: "doc.text") { viewReport(.month(point.period)) }
                            .tint(FinanceTrackerModule.accent.color)
                    }
                    .contextMenu {
                        Button("View Report", systemImage: "doc.text") { viewReport(.month(point.period)) }
                    }
                }
            }

            let years = FinanceReportData.reportYears(in: snapshot.months)
            if !years.isEmpty {
                Section("Year in Review") {
                    ForEach(years, id: \.self) { year in
                        Button {
                            viewReport(.year(year))
                        } label: {
                            HStack {
                                Label("\(String(year)) in Review", systemImage: "calendar.badge.clock")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    /// Opens `scope`'s report on Settings' "Whose by default".
    private func viewReport(_ scope: ReportScope) {
        reportRequest = FinanceReportWindowValue(scope: scope, ownerName: reportPreferences.defaultOwnerName)
    }

    private func nextMonthLabel(_ snapshot: FinanceSnapshot) -> String {
        guard let latest = snapshot.latestMonth?.period else { return "Start \(YearMonth(containing: .now).title)" }
        return "Start \(latest.next.title)"
    }

    private func startNextMonth() {
        let household = FinanceHouseholdResolver.forWriting(in: context, container: container)
        MonthRollover.startNextMonth(in: household)
        try? context.saveIfNeeded()
    }
}

private struct MonthRow: View {
    @ObservedObject var month: SharedFinanceMonth
    let value: Double
    let delta: Double?
    let upIsGood: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(month.title)
                    .fontWeight(.semibold)
                if !month.isClosed {
                    Text("IN PROGRESS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(FinanceTrackerModule.accent.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(FinanceTrackerModule.accent.color.opacity(0.15), in: Capsule())
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(FinanceFormat.money(value))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                DeltaText(delta: delta, upIsGood: upIsGood)
                    .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

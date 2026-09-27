import Charts
import Core
import CoreData
import SwiftUI

/// The latest month at a glance: net worth and its trend, how far the month
/// is filled in, and the balance sheet in six tiles.
struct SummaryView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    var data = FinanceFetches()

    @State private var filter = OwnerFilter.all
    @State private var showingExchange = false

    var body: some View {
        let snapshot = data.snapshot
        NavigationStack {
            Group {
                if let latest = snapshot.latestMonth {
                    content(snapshot, latest: latest)
                } else {
                    ContentUnavailableView {
                        Label("No months yet", systemImage: FinanceTrackerModule.symbolName)
                    } description: {
                        Text("Start a month, then type in each account's balance. Next month starts as a copy, so only what moved needs changing.")
                    } actions: {
                        if canEdit(snapshot.household, in: container) {
                            Button("Start \(YearMonth(containing: .now).title)") { startFirstMonth() }
                                .primaryActionStyle(tint: FinanceTrackerModule.accent.color)
                        }
                    }
                }
            }
            .refreshesFromCloud()
            .navigationTitle("Finance")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingExchange = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    ShareHouseholdButton()
                }
            }
            .sheet(isPresented: $showingExchange) {
                MonthExchangeView(months: snapshot.months, household: snapshot.household)
            }
            // An owner deleted (here or by the partner) mustn't leave the
            // filter pointing at nothing.
            .onChange(of: snapshot.owners) { _, owners in
                if case .owner(let owner) = filter, !owners.contains(owner) {
                    filter = .all
                }
            }
        }
    }

    private func content(_ snapshot: FinanceSnapshot, latest: SharedFinanceMonth) -> some View {
        let history = snapshot.history(filter: filter)
        let summary = snapshot.summary(for: latest, filter: filter)
        let period = latest.period ?? YearMonth(containing: .now)
        return List {
            if snapshot.owners.count > 1 {
                Section {
                    Picker("Whose", selection: $filter) {
                        Text("All").tag(OwnerFilter.all)
                        ForEach(snapshot.owners) { owner in
                            Text(owner.name).tag(OwnerFilter.owner(owner))
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }

            Section {
                NetWorthCard(
                    title: latest.title,
                    netWorth: summary.netWorth,
                    delta: history.delta(.netWorth, at: period),
                    series: history.series(.netWorth, last: 12)
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            if !latest.isClosed {
                Section {
                    NavigationLink {
                        MonthEntryView(month: latest)
                    } label: {
                        MonthProgressRow(month: latest, progress: MonthRollover.progress(of: latest))
                    }
                }
            }

            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    SummaryTile(title: "Cash", value: summary.cash, symbol: AccountCategory.cash.symbolName)
                    SummaryTile(title: "Investments", value: summary.investments, symbol: AccountCategory.investments.symbolName)
                    SummaryTile(title: "Retirement", value: summary.retirement, symbol: AccountCategory.retirement.symbolName)
                    SummaryTile(title: "Gold & silver", value: summary.metals, symbol: "circle.hexagongrid")
                    SummaryTile(title: "Cars & property", value: summary.fixed, symbol: AccountCategory.fixed.symbolName)
                    SummaryTile(title: "Owed", value: summary.owed, symbol: AccountCategory.card.symbolName)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("Owed is this month's card spend plus what's left on the loans.")
            }
        }
    }

    private func startFirstMonth() {
        let household = FinanceHouseholdResolver.forWriting(in: context, container: container)
        MonthRollover.startNextMonth(in: household)
        try? context.saveIfNeeded()
    }
}

/// The big number, its change on last month, and a year's line.
private struct NetWorthCard: View {
    let title: String
    let netWorth: Double
    let delta: Double?
    let series: [FinanceHistory.Value]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Net worth · \(title)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(FinanceFormat.money(netWorth))
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let delta {
                HStack(spacing: 4) {
                    DeltaText(delta: delta)
                    Text(delta.rounded() == 0 ? "No change on last month" : "on last month")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
            if series.count > 1 {
                Chart(series) { point in
                    LineMark(
                        x: .value("Month", point.period.start, unit: .month),
                        y: .value("Net worth", point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(FinanceTrackerModule.accent.color)
                    PointMark(
                        x: .value("Month", point.period.start, unit: .month),
                        y: .value("Net worth", point.value)
                    )
                    .symbolSize(20)
                    .foregroundStyle(FinanceTrackerModule.accent.color)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis(.hidden)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.narrow))
                    }
                }
                .frame(height: 120)
                .padding(.top, 8)
            }
        }
    }
}

/// "Finish September · 20 of 32 updated" with a bar.
struct MonthProgressRow: View {
    let month: SharedFinanceMonth
    let progress: MonthProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Finish \(month.monthName)")
                    .fontWeight(.semibold)
                Spacer()
                Text(progress.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: progress.fraction)
                .tint(FinanceTrackerModule.accent.color)
        }
        .padding(.vertical, 4)
    }
}

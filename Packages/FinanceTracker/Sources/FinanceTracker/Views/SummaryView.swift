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
    @Environment(\.moduleLayout) private var layout

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
                        if snapshot.canEdit {
                            Button("Start \(YearMonth(containing: .now).title)") { startFirstMonth() }
                                .primaryActionStyle(tint: FinanceTrackerModule.accent.color)
                        } else if snapshot.isWaitingForICloud {
                            ProgressView("Checking iCloud…")
                        }
                    }
                    .scrollsForRefresh()
                }
            }
            .refreshesFromCloud()
            .navigationTitle("Finance")
            .toolbar {
                // On the Mac, whose figures these are is a toolbar menu, not a
                // segmented row inside the list — a filter reads as a filter
                // there, the way Photos or Mail filter.
                if layout == .sidebar, snapshot.owners.count > 1 {
                    ToolbarItem(placement: .primaryAction) {
                        Picker(selection: $filter) {
                            Text("Everyone").tag(OwnerFilter.all)
                            Divider()
                            ForEach(snapshot.owners) { owner in
                                Text(owner.name).tag(OwnerFilter.owner(owner))
                            }
                        } label: {
                            Label("Whose", systemImage: "person.2")
                        }
                        .pickerStyle(.menu)
                        .help("Show everyone's figures, or one person's")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingExchange = true
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                }
                // Beside Export on the Mac: as a secondary action it sat on its
                // own beside the section switcher.
                ToolbarItem(placement: layout.secondaryToolbarPlacement) {
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

    @ViewBuilder
    private func content(_ snapshot: FinanceSnapshot, latest: SharedFinanceMonth) -> some View {
        if layout == .sidebar {
            MacFinanceDashboard(snapshot: snapshot, latest: latest, filter: filter)
        } else {
            phoneList(snapshot, latest: latest)
        }
    }

    private func phoneList(_ snapshot: FinanceSnapshot, latest: SharedFinanceMonth) -> some View {
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
                        MonthProgressRow(month: latest, progress: snapshot.progress(of: latest))
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

// MARK: - Mac

/// The Mac's Summary: a dashboard sized for a window, not the phone's list
/// stretched across one. The phone's layout on a desktop was a segmented
/// "Whose" row, six flat grey bars and half a window of nothing — "looks like
/// something from 2001". Here: net worth over its year, how far this month is
/// filled in, and the balance sheet as cards on an adaptive grid, each with
/// its share of what's owned.
private struct MacFinanceDashboard: View {
    let snapshot: FinanceSnapshot
    let latest: SharedFinanceMonth
    let filter: OwnerFilter

    private var accent: Color { FinanceTrackerModule.accent.color }

    var body: some View {
        let history = snapshot.history(filter: filter)
        let summary = snapshot.summary(for: latest, filter: filter)
        let period = latest.period ?? YearMonth(containing: .now)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero(summary: summary, delta: history.delta(.netWorth, at: period), series: history.series(.netWorth, last: 12))

                if !latest.isClosed {
                    progressCard(snapshot.progress(of: latest))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Balance sheet")
                        .font(.title3.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                        ForEach(tiles(summary)) { tile in
                            MacBalanceTile(tile: tile, accent: accent)
                        }
                    }
                    Text("Owed is this month's card spend plus what's left on the loans.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: 1_100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .moduleSubtitle(latest.title)
    }

    private func hero(summary: MonthSummary, delta: Double?, series: [FinanceHistory.Value]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Net worth")
                .font(.headline)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(FinanceFormat.money(summary.netWorth))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let delta {
                    HStack(spacing: 4) {
                        DeltaText(delta: delta)
                        Text(delta.rounded() == 0 ? "no change on last month" : "on last month")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
            if series.count > 1 {
                Chart(series) { point in
                    AreaMark(
                        x: .value("Month", point.period.start, unit: .month),
                        y: .value("Net worth", point.value)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [accent.opacity(0.28), accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(
                        x: .value("Month", point.period.start, unit: .month),
                        y: .value("Net worth", point.value)
                    )
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .foregroundStyle(accent)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis {
                    AxisMarks(position: .trailing) { value in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let amount = value.as(Double.self) { Text(FinanceFormat.compactMoney(amount)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated))
                    }
                }
                .frame(height: 200)
                .padding(.top, 12)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
    }

    private func progressCard(_ progress: MonthProgress) -> some View {
        HStack(spacing: 16) {
            Gauge(value: progress.fraction) {
                EmptyView()
            } currentValueLabel: {
                Text(progress.fraction, format: .percent.precision(.fractionLength(0)))
                    .font(.caption2.weight(.semibold))
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Finish \(latest.monthName)")
                    .font(.headline)
                Text(progress.label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            NavigationLink {
                MonthEntryView(month: latest)
            } label: {
                Text("Continue")
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
    }

    private func tiles(_ summary: MonthSummary) -> [MacBalanceTile.Tile] {
        let assets = max(summary.totalAssets, 1)
        func tile(_ title: String, _ value: Double, _ symbol: String, share: Bool = true) -> MacBalanceTile.Tile {
            MacBalanceTile.Tile(title: title, value: value, symbol: symbol, share: share ? value / assets : nil)
        }
        return [
            tile("Cash", summary.cash, AccountCategory.cash.symbolName),
            tile("Investments", summary.investments, AccountCategory.investments.symbolName),
            tile("Retirement", summary.retirement, AccountCategory.retirement.symbolName),
            tile("Gold & silver", summary.metals, "circle.hexagongrid"),
            tile("Cars & property", summary.fixed, AccountCategory.fixed.symbolName),
            tile("Owed", summary.owed, AccountCategory.card.symbolName, share: false),
        ]
    }
}

/// One line of the balance sheet on the Mac: what, how much, and — for an
/// asset — its share of everything owned, as a thin bar.
private struct MacBalanceTile: View {
    struct Tile: Identifiable {
        let title: String
        let value: Double
        let symbol: String
        /// 0…1 of total assets; nil for what's owed.
        let share: Double?
        var id: String { title }
    }

    let tile: Tile
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tile.title, systemImage: tile.symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(FinanceFormat.money(tile.value))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
            if let share = tile.share {
                ProgressView(value: min(max(share, 0), 1)) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(share, format: .percent.precision(.fractionLength(0))) of assets")
                }
                .tint(accent)
                .font(.caption)
            } else {
                Text("This month's cards and loans")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        // One height for every tile, whatever its last line says.
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}

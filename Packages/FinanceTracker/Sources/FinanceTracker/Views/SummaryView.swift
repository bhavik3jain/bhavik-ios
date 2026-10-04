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
    /// Whether the person picked whose figures in this Summary. Until they
    /// do, a report opened from here follows Settings' "Whose by default":
    /// the Summary always starts on Everyone, so its Report button and the
    /// card's Open Report ignored that setting — on the most-used way in.
    @State private var filterWasChosen = false
    @State private var showingExchange = false
    /// The tile whose accounts are shown — see `BalanceTileDetailView`.
    @State private var openTile: BalanceTile?
    @Environment(\.moduleLayout) private var layout
    @Environment(\.financeAdvisor) private var advisor
    @Environment(\.financeAdvisorEnabled) private var isAdvisorEnabled
    @Environment(\.financeReportPreferences) private var reportPreferences

    /// The reported month's review, kept here rather than in the card: a
    /// list row's `.task` ends whenever the row scrolls away, which stopped
    /// the model mid-review — and the review sheet shows this same model, so
    /// it isn't written twice.
    @State private var brief: ReportReviewModel?
    @State private var showingReview = false
    /// The report to show: a cover on the phone, a window on the Mac
    /// (`presentsReport`).
    @State private var report: FinanceReportWindowValue?

    var body: some View {
        let snapshot = data.snapshot
        let scope = reportScope(snapshot)
        NavigationStack {
            Group {
                if let latest = snapshot.latestMonth {
                    content(snapshot, latest: latest)
                } else {
                    ContentUnavailableView {
                        Label("No months yet", systemImage: FinanceTrackerModule.symbolName)
                    } description: {
                        Text("Start a month, then type in each account's balance. Each new month starts at zero, with last month\u{2019}s figure a tap away.")
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
                // The reported month's report: the month the net-worth card
                // headlines, never a half-filled one (`FinanceHome.reportedMonth`).
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let scope { report = FinanceReportWindowValue(scope: scope, ownerName: reportOwnerName(data.snapshot)) }
                    } label: {
                        Label("Report", systemImage: "doc.text")
                    }
                    // ⇧⌘R, not the design's ⌘R: that is View ▸ Refresh from
                    // iCloud (CloudSyncCommands), and a menu command takes the
                    // key before any toolbar button sees it.
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(scope == nil)
                    .help(scope.map { "Open the \($0.title) report" } ?? "No month to report on yet")
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
                MonthExchangeView(
                    months: snapshot.months,
                    household: snapshot.household,
                    initialMonth: snapshot.latestMonth.map { FinanceHome.reportedMonth(for: $0, live: snapshot.live).yearMonth }
                )
            }
            .sheet(isPresented: $showingReview) {
                if let brief {
                    ReviewSheet(model: brief)
                }
            }
            .presentsReport($report)
            // The tile's own month — the reported one, so the detail adds up
            // to the figure that was tapped.
            .navigationDestination(item: $openTile) { tile in
                if let latest = snapshot.latestMonth {
                    BalanceTileDetailView(detail: BalanceTileDetail(
                        tile: tile,
                        month: FinanceHome.reportedMonth(for: latest, live: snapshot.live),
                        months: snapshot.months,
                        cards: snapshot.cards,
                        metals: snapshot.metals,
                        filter: filter,
                        live: snapshot.live
                    ))
                }
            }
            // An owner deleted (here or by the partner) mustn't leave the
            // filter pointing at nothing.
            .onChange(of: snapshot.owners) { _, owners in
                if case .owner(let owner) = filter, !owners.contains(owner) {
                    filter = .all
                }
            }
            .onChange(of: filter) { filterWasChosen = true }
        }
        // On the stack, not its root: the root's tasks end when a tile's
        // detail is pushed, which stopped the review mid-sentence.
        .keepsReportReview($brief, scope: scope, filter: filter, snapshot: snapshot)
    }

    /// Whose figures a report opened from here shows: the Summary's own
    /// pick once the person made one, else Settings' "Whose by default" while
    /// that person is still in the household.
    private func reportOwnerName(_ snapshot: FinanceSnapshot) -> String? {
        filterWasChosen
            ? filter.reportOwnerName
            : OwnerFilter.reportDefaultOwnerName(preferred: reportPreferences.defaultOwnerName, owners: snapshot.owners)
    }

    @ViewBuilder
    private func content(_ snapshot: FinanceSnapshot, latest: SharedFinanceMonth) -> some View {
        if layout == .sidebar {
            MacFinanceDashboard(snapshot: snapshot, latest: latest, filter: filter, brief: briefCard) { openTile = $0 }
        } else {
            phoneList(snapshot, latest: latest)
        }
    }

    private func phoneList(_ snapshot: FinanceSnapshot, latest: SharedFinanceMonth) -> some View {
        let history = snapshot.history(filter: filter)
        let reported = FinanceHome.reportedMonth(for: latest, live: snapshot.live)
        let summary = snapshot.summary(for: reported, filter: filter)
        let period = reported.period ?? YearMonth(containing: .now)
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
                    title: reported.title,
                    netWorth: summary.netWorth,
                    delta: history.delta(.netWorth, at: period),
                    series: history.series(.netWorth, through: period, last: 12)
                )
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            if let card = briefCard {
                Section {
                    card
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
                }
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
                    ForEach(BalanceTile.allCases) { tile in
                        // Health only for a household with an FSA/HSA, so
                        // the grid doesn't grow an empty tile for everyone else.
                        if tile != .health || summary.health != 0 {
                            Button {
                                openTile = tile
                            } label: {
                                SummaryTile(title: tile.title, value: tile.value(in: summary), symbol: tile.symbolName, opensDetail: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text("Owed is this month's card spend plus what's left on the loans. Tap a figure for what makes it up.")
            }
        }
    }

    /// The reported month — what the net-worth card headlines, and so what
    /// the report and the review are about.
    private func reportScope(_ snapshot: FinanceSnapshot) -> ReportScope? {
        snapshot.latestMonth
            .flatMap { FinanceHome.reportedMonth(for: $0, live: snapshot.live).period }
            .map(ReportScope.month)
    }

    /// "<Month> in brief", or nil when there's no review to show — no month
    /// yet, or Apple Intelligence in Finance switched off.
    private var briefCard: MonthBriefCard? {
        let availability = advisor.availability(isEnabled: isAdvisorEnabled)
        guard let brief, availability.reviewCardStyle != .hidden else { return nil }
        return MonthBriefCard(
            model: brief,
            availability: availability,
            readReview: { showingReview = true },
            openReport: { report = FinanceReportWindowValue(scope: brief.scope, ownerName: reportOwnerName(data.snapshot)) }
        )
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
    /// "<Month> in brief", between the net worth and the month's progress.
    let brief: MonthBriefCard?
    let open: (BalanceTile) -> Void

    private var accent: Color { FinanceTrackerModule.accent.color }

    var body: some View {
        let history = snapshot.history(filter: filter)
        let reported = FinanceHome.reportedMonth(for: latest, live: snapshot.live)
        let summary = snapshot.summary(for: reported, filter: filter)
        let period = reported.period ?? YearMonth(containing: .now)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero(
                    title: reported == latest ? nil : reported.title,
                    summary: summary,
                    delta: history.delta(.netWorth, at: period),
                    series: history.series(.netWorth, through: period, last: 12)
                )

                if let brief {
                    brief
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background.secondary, in: .rect(cornerRadius: 18))
                }

                if !latest.isClosed {
                    progressCard(snapshot.progress(of: latest))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Balance sheet")
                        .font(.title3.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                        ForEach(tiles(summary)) { tile in
                            Button {
                                open(tile.kind)
                            } label: {
                                MacBalanceTile(tile: tile, accent: accent)
                            }
                            .buttonStyle(.plain)
                            .help("Show what makes up \(tile.kind.title)")
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
        .moduleSubtitle(reported.title)
    }

    /// `title` names the month when it isn't the latest — see
    /// `FinanceHome.reportedMonth`.
    private func hero(title: String?, summary: MonthSummary, delta: Double?, series: [FinanceHistory.Value]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.map { "Net worth · \($0)" } ?? "Net worth")
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
        return BalanceTile.allCases
            .filter { $0 != .health || summary.health != 0 }
            .map { kind in
                let value = kind.value(in: summary)
                return MacBalanceTile.Tile(kind: kind, value: value, share: kind.isAsset ? value / assets : nil)
            }
    }
}

/// One line of the balance sheet on the Mac: what, how much, and — for an
/// asset — its share of everything owned, as a thin bar.
private struct MacBalanceTile: View {
    struct Tile: Identifiable {
        let kind: BalanceTile
        let value: Double
        /// 0…1 of total assets; nil for what's owed.
        let share: Double?
        var id: BalanceTile { kind }
    }

    let tile: Tile
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tile.kind.title, systemImage: tile.kind.symbolName)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
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
        .contentShape(.rect(cornerRadius: 14))
    }
}

import Charts
import Core
import SwiftUI

/// Months on the Mac: the chosen figure charted across a year, then every
/// month as a table row with each figure in its own column — the phone's
/// list showed one figure at a time and a single month as a window-wide bar.
/// Double-click opens the month.
struct MacMonthsView: View {
    let history: FinanceHistory
    let metric: FinanceMetric
    let isEditable: Bool
    let open: (SharedFinanceMonth) -> Void
    let delete: (SharedFinanceMonth) -> Void

    @State private var selection: FinanceHistory.Point.ID?

    private static let columns: [FinanceMetric] = [.cash, .investments, .retirement, .metals, .fixed, .cardSpend]

    var body: some View {
        let rows = Array(history.points.reversed())
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(metric.displayName)
                        .font(.headline)
                    if let latest = history.latest {
                        Text(FinanceFormat.money(latest.summary.value(for: metric)))
                            .font(.headline)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                MonthsChart(series: history.series(metric), metric: metric)
                    .frame(height: 180)
            }
            .padding(16)
            .background(.background.secondary, in: .rect(cornerRadius: 14))
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Table(rows, selection: $selection) {
                TableColumn("Month") { point in
                    HStack(spacing: 6) {
                        Text(point.month.title)
                            .fontWeight(.medium)
                        if !point.month.isClosed {
                            Text("In progress")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(FinanceTrackerModule.accent.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(FinanceTrackerModule.accent.color.opacity(0.15), in: Capsule())
                        }
                    }
                }
                .width(min: 200, ideal: 230)
                TableColumn("Net worth") { point in
                    Text(FinanceFormat.money(point.summary.netWorth))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
                .alignment(.numeric)
                TableColumn("Change") { point in
                    DeltaText(delta: history.delta(.netWorth, at: point.period))
                }
                .alignment(.numeric)
                TableColumnForEach(Self.columns) { column in
                    TableColumn(column.displayName) { point in
                        Text(FinanceFormat.money(point.summary.value(for: column)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .alignment(.numeric)
                }
            }
            .tableRowBackgroundsPlain()
            .contextMenu(forSelectionType: FinanceHistory.Point.ID.self) { ids in
                if let month = month(for: ids) {
                    Button("Open", systemImage: "arrow.up.forward.square") { open(month) }
                    if isEditable {
                        Divider()
                        Button("Delete Month…", systemImage: "trash", role: .destructive) { delete(month) }
                    }
                }
            } primaryAction: { ids in
                if let month = month(for: ids) { open(month) }
            }
        }
    }

    private func month(for ids: Set<FinanceHistory.Point.ID>) -> SharedFinanceMonth? {
        ids.first.flatMap { id in history.points.first { $0.id == id }?.month }
    }
}

/// One figure across the months, as bars — shared by the phone's list and
/// the Mac's table.
struct MonthsChart: View {
    let series: [FinanceHistory.Value]
    let metric: FinanceMetric

    var body: some View {
        Chart(series) { point in
            BarMark(
                x: .value("Month", point.period.start, unit: .month),
                y: .value(metric.displayName, point.value),
                width: .ratio(0.6)
            )
            .foregroundStyle(FinanceTrackerModule.accent.color.gradient)
            .cornerRadius(4)
        }
        .chartXScale(domain: FinanceHistory.chartDomain(series) ?? Date.distantPast...Date.now)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) { Text(FinanceFormat.compactMoney(amount)) }
                }
            }
        }
    }
}

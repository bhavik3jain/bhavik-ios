import Charts
import Core
import SwiftUI

/// What a Summary tile adds up: tap Cash and see every cash account, whose it
/// is, what it holds and how it moved on last month, with a year of the
/// total above them. Owed splits into cards and loans; Gold & silver lists
/// each item at the prices it's valued at.
struct BalanceTileDetailView: View {
    let detail: BalanceTileDetail

    private var accent: Color { FinanceTrackerModule.accent.color }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            if let prices = detail.prices {
                Section {
                    LabeledContent("Gold", value: "\(FinanceFormat.money(prices.gold)) / oz")
                    LabeledContent("Silver", value: "\(FinanceFormat.money(prices.silver)) / oz")
                } header: {
                    Text("Prices")
                } footer: {
                    Text(detail.pricesAreLive
                        ? "Today's prices, while \(detail.month.monthName) is open. Closing the month keeps them."
                        : "The prices \(detail.month.title) was closed at.")
                }
            }

            if detail.isEmpty {
                Section {
                    Text(emptyText)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(detail.groups) { group in
                Section {
                    ForEach(group.lines) { line in
                        row(line)
                    }
                } header: {
                    HStack {
                        Text(group.title)
                        Spacer()
                        Text(FinanceFormat.money(group.total))
                            .monospacedDigit()
                    }
                }
            }

            if detail.tile == .owed, !detail.isEmpty {
                Section {
                } footer: {
                    Text(detail.groups.contains { $0.title == "Cards" }
                        ? "Cards are \(detail.month.monthName)'s spend; loans are what's left to pay."
                        : "No card spend in \(detail.month.monthName). Loans are what's left to pay.")
                }
            }
        }
        .navigationTitle(detail.tile.title)
        .moduleSubtitle(detail.month.title)
        .readableWidthInSidebar()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(detail.tile.title) · \(detail.month.title)", systemImage: detail.tile.symbolName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(FinanceFormat.money(detail.total))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: 4) {
                if let change = detail.change {
                    DeltaText(delta: change, upIsGood: detail.tile.isAsset)
                    Text(change.rounded() == 0 ? "No change on last month" : "on last month")
                        .foregroundStyle(.secondary)
                }
                if let share = detail.shareOfAssets {
                    if detail.change != nil { Text("·").foregroundStyle(.secondary) }
                    Text("\(share, format: .percent.precision(.fractionLength(0))) of assets")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            if detail.series.count > 1 {
                Chart(detail.series) { point in
                    BarMark(
                        x: .value("Month", point.period.start, unit: .month),
                        y: .value(detail.tile.title, point.value)
                    )
                    .foregroundStyle(point.period == detail.month.period ? accent : accent.opacity(0.35))
                    .cornerRadius(3)
                }
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
                        AxisValueLabel(format: .dateTime.month(.narrow))
                    }
                }
                .frame(height: 140)
                .padding(.top, 8)
            }
        }
    }

    private func row(_ line: BalanceTileDetail.Line) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                if let subtitle = line.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(FinanceFormat.money(line.amount))
                    .monospacedDigit()
                Group {
                    if let gain = line.gain {
                        Text("\(FinanceFormat.signedMoney(gain)) gain")
                            .foregroundStyle(gain >= 0 ? Color.green : Color.red)
                    // A metal's month-on-month change is only the price moving,
                    // and beside another item's gain it read as one.
                    } else if detail.tile != .metals, let change = line.change, change.rounded() != 0 {
                        DeltaText(delta: change, upIsGood: detail.tile.isAsset)
                    } else if line.previous == nil, detail.previousTotal != nil {
                        Text("New").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyText: String {
        switch detail.tile {
        case .metals: "No gold or silver yet. Add items under Holdings."
        case .owed: "Nothing owed in \(detail.month.title): no card spend and no loans."
        default: "No \(detail.tile.title.lowercased()) accounts in \(detail.month.title). Add one under Holdings."
        }
    }
}

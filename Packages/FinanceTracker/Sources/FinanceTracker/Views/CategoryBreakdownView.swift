import Charts
import Core
import SwiftUI

/// Fixed colours for spending categories, biggest first, so the Transactions
/// bar, the Categories donut and its rows agree. Left to Swift Charts, each
/// chart picked its own, and a legend dot matched nothing outside its chart.
enum CategoryPalette {
    static let colors: [Color] = [.blue, .green, .orange, .purple, .red, .teal, .yellow, .indigo, .mint, .pink, .brown, .cyan]

    /// `names` once each, in order — a chart's scale can't take a name twice.
    static func domain(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    static func range(for domain: [String]) -> [Color] {
        domain.indices.map { colors[$0 % colors.count] }
    }

    static func color(of name: String, in domain: [String]) -> Color {
        colors[(domain.firstIndex(of: name) ?? 0) % colors.count]
    }
}

/// Spending's Categories view: where the month's money went, as a donut and
/// a row per category — its total, share and transaction count, opening onto
/// its split by expense and the transactions themselves. Sections for the
/// screen's own list.
struct CategoryBreakdownSections: View {
    let transactions: [SharedFinanceTransaction]
    let periodTitle: String

    var body: some View {
        let rows = SpendingSummary.breakdown(transactions)
        let domain = CategoryPalette.domain(rows.map(\.name))
        if rows.isEmpty {
            Section {
                Text("Nothing in \(periodTitle) yet.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                CategoryDonut(rows: rows, domain: domain, total: SpendingSummary.total(transactions), periodTitle: periodTitle)
                    .padding(.vertical, 8)
            }
            Section("By category") {
                ForEach(rows) { row in
                    DisclosureGroup {
                        ForEach(row.expenses) { expense in
                            HStack {
                                Text(expense.name)
                                Spacer()
                                Text(FinanceFormat.cents(expense.total))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                        NavigationLink {
                            CategoryTransactionsView(
                                name: row.name,
                                transactions: SpendingSummary.transactions(transactions, inCategory: row.name)
                            )
                        } label: {
                            Text("Show \(counted(row.count, "transaction"))")
                                .foregroundStyle(.tint)
                        }
                    } label: {
                        CategoryRowLabel(row: row, color: CategoryPalette.color(of: row.name, in: domain))
                    }
                }
            }
        }
    }
}

private struct CategoryDonut: View {
    let rows: [CategoryBreakdown]
    let domain: [String]
    let total: Double
    let periodTitle: String

    var body: some View {
        Chart(rows.filter { $0.total > 0 }) { row in
            SectorMark(angle: .value("Spent", row.total), innerRadius: .ratio(0.64), angularInset: 1.5)
                .cornerRadius(3)
                .foregroundStyle(by: .value("Category", row.name))
        }
        .chartForegroundStyleScale(domain: domain, range: CategoryPalette.range(for: domain))
        .chartLegend(.hidden)
        .chartBackground { proxy in
            GeometryReader { geometry in
                if let plot = proxy.plotFrame {
                    let frame = geometry[plot]
                    VStack(spacing: 2) {
                        Text(FinanceFormat.money(total))
                            .font(.title2.weight(.semibold))
                            .monospacedDigit()
                        Text("spent in \(periodTitle)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .position(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(height: 220)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(FinanceFormat.money(total)) spent in \(periodTitle)")
    }
}

private struct CategoryRowLabel: View {
    let row: CategoryBreakdown
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color)
                    .frame(width: 9, height: 9)
                Text(row.name)
                    .fontWeight(.medium)
                Spacer()
                Text(FinanceFormat.cents(row.total))
                    .monospacedDigit()
                    .foregroundStyle(row.total < 0 ? Color.green : Color.primary)
            }
            ProgressView(value: row.share)
                .tint(color)
            Text("\(counted(row.count, "transaction")) · \(row.share.formatted(.percent.precision(.fractionLength(0))))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// One category's transactions, newest first.
private struct CategoryTransactionsView: View {
    let name: String
    let transactions: [SharedFinanceTransaction]

    var body: some View {
        List {
            Section {
                ForEach(transactions.sorted { $0.date > $1.date }) { transaction in
                    TransactionRow(transaction: transaction)
                }
            } footer: {
                Text("\(counted(transactions.count, "transaction")), \(FinanceFormat.cents(SpendingSummary.total(transactions))) in all.")
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

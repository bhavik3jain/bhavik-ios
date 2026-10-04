import Core
import Foundation

/// The spending half of the page: spending and budgets, cards, and Worth fixing.
extension FinanceReportHTML.Page {
    // MARK: Spending

    var spending: String {
        let spending = data.spending
        var html = """
        <section class="card" id="spending"><h2>\(escape(title(of: "spending", otherwise: "Spending"))) · \(escape(spending.totalText))</h2>\
        <p class="lede">\(escape(spending.lede))</p>
        """
        html += spendingMinis
        if isYear, let year = data.year {
            html += monthColumns(year)
            html += yearCategories(year)
            html += yearBudgets(year)
        } else {
            html += budgets
        }
        html += noBudget
        html += byAccountAndMerchants
        html += recurring
        if !isYear {
            html += tableView(
                makeTable(
                    ["Category", ">Spent", ">Charges", ">3-month average", ">Change"],
                    spending.categories.map { category in
                        [
                            escape(category.name), escape(category.totalText), String(category.count),
                            escape(category.averageText ?? "—"), escape(category.changeText ?? "—"),
                        ]
                    }
                ),
                summary: "Every category"
            )
        }
        return html + "</section>"
    }

    /// The tiles under Spending's lede: against the usual, the biggest
    /// changes, and what recurs. For a year: the total, a month's average,
    /// against last year, and what recurs.
    var spendingMinis: String {
        let spending = data.spending
        var tiles: [String] = []
        if isYear, let year = data.year {
            tiles.append(mini("Spent in \(year.year)", year.spendTotalText, counted(spending.transactionCount, "transaction")))
            if let average = year.spendAverage, let averageText = year.spendAverageText {
                tiles.append(mini("A month, on average", averageText, "Over \(counted(year.months.count { $0.spend > 0 }, "month"))"))
                if let previous = year.previousYearMonthlyAverage, previous > 0 {
                    let change = average / previous - 1
                    tiles.append(mini(
                        "vs \(year.year - 1)",
                        FinanceFormat.signedPercent(change),
                        "\(averageText) a month against \(FinanceFormat.money(previous))",
                        valueClass: change > MonthCheck.spikeFraction ? "bad" : ""
                    ))
                }
            }
        } else {
            if let change = spending.changeVsAverage, let averageText = spending.averageText {
                tiles.append(mini("vs 3-month average", FinanceFormat.signedPercent(change), "\(spending.totalText) against \(averageText)"))
            }
            for category in spending.biggestChanges.prefix(2) {
                if let fraction = category.changeFraction, let averageText = category.averageText {
                    tiles.append(mini(
                        category.name,
                        category.changeText ?? FinanceFormat.signedPercent(fraction),
                        "\(category.totalText) against \(averageText)",
                        valueClass: fraction > MonthCheck.spikeFraction ? "bad" : ""
                    ))
                } else {
                    tiles.append(mini(category.name, category.totalText, category.changeText ?? ""))
                }
            }
        }
        if !spending.recurring.isEmpty {
            let new = spending.newRecurring.count
            let detail = counted(spending.recurring.count, "charge") + (new > 0 ? ", \(new) new" : "")
            tiles.append(mini("Recurring", spending.recurringMonthlyText, detail))
        }
        guard !tiles.isEmpty else { return "" }
        return "<div class=\"grid minis\">\(tiles.joined())</div>"
    }

    // MARK: Budgets

    /// The month's budgets with a limit — never one at the "No budget"
    /// sentinel, which `BudgetStatus` already lists as unbudgeted. A -1
    /// limit drawn as a budget read "-$1", always over, in builds before the
    /// sentinel was understood.
    var budgets: String {
        let rows = data.spending.budgets.filter { $0.limit >= 0 }
        guard !rows.isEmpty else { return "" }
        let bars = rows.map { row in
            let largest = max(row.spent, row.limit)
            let within = largest > 0 ? min(row.spent, row.limit) / largest : 0
            let over = largest > 0 && row.isOver ? (row.spent - row.limit) / largest : 0
            return "<div class=\"bud\"><div class=\"top\"><span>\(escape(row.category))</span>"
                + "<span\(row.isOver ? " class=\"over\"" : "")>\(escape(row.label))</span></div>"
                + "<div class=\"trk\"><div class=\"in\" style=\"width:\(FinanceReportHTML.percent(within))\"></div>"
                + "<div class=\"ov\" style=\"width:\(FinanceReportHTML.percent(over))\"></div></div></div>"
        }.joined()
        let table = makeTable(
            ["Category", ">Limit", ">Spent", ">Over"],
            rows.map { row in
                [escape(row.category), escape(FinanceFormat.money(row.limit)), escape(FinanceFormat.money(row.spent)), escape(row.isOver ? FinanceFormat.money(row.over) : "—")]
            }
        )
        return "<h3>Budgets</h3>\(householdWideNote)<div class=\"buds\">\(bars)</div>\(tableView(table))"
    }

    /// Under an owner filter, budgets still count everyone's spending: a
    /// household limit against one person's share would always look fine.
    var householdWideNote: String {
        guard data.spending.budgetsAreHouseholdWide else { return "" }
        return "<p class=\"note\" style=\"margin:-4px 0 12px\">Budgets are the household’s, so they count everyone’s spending, whoever this report is for.</p>"
    }

    /// Each budgeted category over the year: the months it went over.
    func yearBudgets(_ year: FinanceReportData.YearSection) -> String {
        let rows = year.budgets.filter { $0.monthsBudgeted > 0 }
        guard !rows.isEmpty else { return "" }
        let bars = rows.map { row in
            let overShare = Double(row.monthsOver) / Double(row.monthsBudgeted)
            let label = row.monthsOver == 0
                ? "Within budget \(row.monthsBudgeted == 1 ? "its one month" : "all \(row.monthsBudgeted) months")"
                : "Over in \(row.monthsOver) of \(counted(row.monthsBudgeted, "month")) · \(FinanceFormat.money(row.totalOver)) over"
            return "<div class=\"bud\"><div class=\"top\"><span>\(escape(row.category))</span>"
                + "<span\(row.monthsOver > 0 ? " class=\"over\"" : "")>\(escape(label))</span></div>"
                + "<div class=\"trk\"><div class=\"in\" style=\"width:\(FinanceReportHTML.percent(1 - overShare))\"></div>"
                + "<div class=\"ov\" style=\"width:\(FinanceReportHTML.percent(overShare))\"></div></div></div>"
        }.joined()
        let table = makeTable(
            ["Category", ">Months budgeted", ">Months over", ">Limits", ">Spent", ">Over"],
            rows.map { row in
                [
                    escape(row.category), String(row.monthsBudgeted), String(row.monthsOver),
                    escape(FinanceFormat.money(row.totalLimit)), escape(FinanceFormat.money(row.totalSpent)),
                    escape(row.totalOver > 0 ? FinanceFormat.money(row.totalOver) : "—"),
                ]
            }
        )
        return "<h3>Budgets, month by month</h3>\(householdWideNote)<div class=\"buds\">\(bars)</div>\(tableView(table))"
    }

    /// Categories kept with "No budget", and those spent on with none.
    var noBudget: String {
        let rows = data.spending.unbudgeted.filter { $0.spent.rounded() != 0 }
        guard !rows.isEmpty else { return "" }
        let chips = rows.map { row in
            let tip = row.isKeptWithNoBudget ? "Kept with “No budget”" : (row.isUncategorised ? "No category" : "Never given a budget")
            return "<span class=\"chip\" title=\"\(escape(tip))\">\(escape(row.category)) \(escape(row.spentText))</span>"
        }.joined()
        let heading = "No budget · \(data.spending.unbudgetedTotalText) in \(counted(rows.count, "category", plural: "categories"))"
        return "<div class=\"nobud\"><div class=\"lbl\">\(escape(heading))</div><div class=\"chips\">\(chips)</div></div>"
    }

    // MARK: Year columns and categories

    /// Spending per month, cards and cash stacked.
    func monthColumns(_ year: FinanceReportData.YearSection) -> String {
        let months = year.months
        let largest = months.map(\.spend).max() ?? 0
        guard !months.isEmpty, largest > 0 else { return "" }
        let columns = months.map { row in
            let card = max(min(row.cardSpend, row.spend), 0) / largest
            let cash = max(row.spend - max(row.cardSpend, 0), 0) / largest
            let tip = "\(row.period.title): \(row.spendText), \(FinanceFormat.money(row.cardSpend)) on cards"
            return "<div class=\"c\" title=\"\(escape(tip))\"><i style=\"height:\(FinanceReportHTML.percent(card))\"></i>"
                + "<i class=\"cash\" style=\"height:\(FinanceReportHTML.percent(cash))\"></i></div>"
        }.joined()
        let labels = months.map { "<span>\(escape($0.label))</span>" }.joined()
        let table = makeTable(
            ["Month", ">Spent", ">On cards", ">Budgets over"],
            months.map { row in
                [escape(row.period.title), escape(row.spendText), escape(FinanceFormat.money(row.cardSpend)), String(row.budgetsOver)]
            }
        )
        return """
        <h3>Month by month</h3>\
        <div class="keys"><span><span class="sw" style="background:var(--s1)"></span>On cards</span>\
        <span><span class="sw" style="background:var(--s2)"></span>From cash accounts</span></div>\
        <div class="cols-chart" role="img" aria-label="\(escape("Spending each month of \(year.year)"))">\(columns)</div>\
        <div class="cols-labels">\(labels)</div>\(tableView(table))
        """
    }

    /// The year's categories, biggest first.
    func yearCategories(_ year: FinanceReportData.YearSection) -> String {
        guard !year.categories.isEmpty else { return "" }
        let largest = year.categories.map(\.total).max() ?? 0
        let rows = year.categories.map { category in
            let width = largest > 0 ? max(category.total / largest, 0.006) : 0
            return "<div class=\"br\"><div class=\"bl\" title=\"\(escape(category.name))\">\(escape(category.name)) "
                + "<span>· \(escape(FinanceFormat.percent(category.share)))</span></div>"
                + "<div class=\"bt\"><div class=\"bf\" style=\"width:\(FinanceReportHTML.percent(width));background:var(--s1)\"></div></div>"
                + "<div class=\"bv\">\(escape(category.totalText))</div></div>"
        }.joined()
        let table = makeTable(
            ["Category", ">Spent", ">Share", ">A month", ">Last year, a month"],
            year.categories.map { category in
                let months = max(category.monthly.count { $0 != 0 }, 1)
                return [
                    escape(category.name), escape(category.totalText), escape(FinanceFormat.percent(category.share)),
                    escape(FinanceFormat.money(category.total / Double(months))),
                    escape(category.previousYearMonthlyAverage.map(FinanceFormat.money) ?? "—"),
                ]
            }
        )
        return "<h3>By category</h3><div class=\"rows\">\(rows)</div>\(tableView(table))"
    }

    // MARK: By account, merchants, recurring

    var byAccountAndMerchants: String {
        let spending = data.spending
        var halves: [String] = []
        if !spending.byAccount.isEmpty {
            let largest = spending.byAccount.map { abs($0.total) }.max() ?? 0
            let rows = spending.byAccount.map { account in
                let colour = account.isCard
                    ? (account.owner == nil ? ("", "background:var(--s1)") : FinanceReportHTML.ownerStyle(account.owner))
                    : ("", "background:var(--muted)")
                let width = largest > 0 ? max(abs(account.total) / largest, 0.006) : 0
                let tip = [account.name, account.ownerName, counted(account.count, "charge")].compactMap(\.self).joined(separator: " · ")
                return "<div class=\"br\" style=\"grid-template-columns:minmax(90px,1fr) minmax(0,1fr) 84px\">"
                    + "<div class=\"bl\" title=\"\(escape(tip))\">\(escape(account.name))</div>"
                    + "<div class=\"bt\"><div class=\"bf \(colour.0)\" style=\"width:\(FinanceReportHTML.percent(width));\(colour.1)\"></div></div>"
                    + "<div class=\"bv\">\(escape(account.totalText))</div></div>"
            }.joined()
            let title = spending.byAccount.allSatisfy(\.isCard) ? "By card" : "By card or account"
            halves.append("<div><h3>\(title)</h3><div class=\"rows\">\(rows)</div></div>")
        }
        if !spending.topMerchants.isEmpty {
            let table = makeTable(
                ["Merchant", ">Visits", ">Spent"],
                spending.topMerchants.map { [escape($0.name), String($0.visits), escape($0.totalText)] }
            )
            halves.append("<div><h3>Top merchants</h3><div class=\"tbl\">\(table)</div></div>")
        }
        guard !halves.isEmpty else { return "" }
        return "<div class=\"halves\">\(halves.joined())</div>"
    }

    var recurring: String {
        let charges = data.spending.recurring
        guard !charges.isEmpty else { return "" }
        let table = makeTable(
            ["Merchant", "Category", "Card", ">Amount", ">Months seen"],
            charges.map { charge in
                [
                    escape(charge.merchant) + (charge.isNew ? " <span class=\"pill warn\" style=\"font-size:10.5px\">New</span>" : ""),
                    escape(charge.category.isEmpty ? "—" : charge.category), escape(charge.accountName ?? "—"),
                    escape(charge.amountText), String(charge.monthsSeen),
                ]
            }
        )
        let yearly = FinanceFormat.money(data.spending.recurringMonthly * 12)
        let heading = "Recurring · \(data.spending.recurringMonthlyText) a month, \(yearly) a year"
        return "<h3>\(escape(heading))</h3><div class=\"tbl\">\(table)</div>"
    }

    // MARK: Cards

    var cards: String {
        let cards = data.cards
        guard !cards.cards.isEmpty else { return "" }
        let meter = cards.use.map {
            "<div class=\"meter\" role=\"img\" aria-label=\"\(escape("Card use \(cards.useText ?? "")"))\">"
                + "<div style=\"width:\(FinanceReportHTML.percent($0))\"></div></div>"
        } ?? ""
        let table = makeTable(
            ["Card", "Owner", ">Limit", ">Fee", isYear ? ">This year" : ">This month", ">Use"],
            cards.cards.map { card in
                [
                    escape(card.name), escape(card.ownerName ?? "—"), escape(card.limitText), escape(card.feeText),
                    escape(card.spendText), escape(card.useText ?? "—"),
                ]
            }
        )
        return """
        <section class="card" id="cards"><h2>\(escape(title(of: "cards", otherwise: "Cards")))</h2>\
        <p class="lede">\(escape(cards.lede))</p>\(meter)\
        <h3>Limit and use, by card</h3><div class="tbl">\(table)</div></section>
        """
    }

    // MARK: Worth fixing

    var fixing: String {
        let findings = data.worthFixing
        guard !findings.isEmpty else { return "" }
        let rows = findings.map { finding in
            let paragraph = finding.detail.isEmpty ? finding.plainText : finding.detail
            return "<div class=\"fd\(finding.severity == .note ? "" : " warn")\"><div class=\"fh\">"
                + "<span class=\"bdg\">\(escape(finding.kind.badge))</span><h4>\(escape(finding.title))</h4></div>"
                + "<p>\(escape(paragraph))</p></div>"
        }.joined()
        let lede = "\(counted(findings.count, "thing")) the app’s own checks found, the ones that most change the headline first. None of them comes from Apple Intelligence."
        return """
        <section class="card" id="fixing"><h2>\(escape(title(of: "fixing", otherwise: "Worth fixing")))</h2>\
        <p class="lede">\(escape(lede))</p><div class="fixes">\(rows)</div></section>
        """
    }
}

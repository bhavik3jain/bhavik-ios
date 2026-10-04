import Core
import Foundation

/// The balance-sheet half of the page: where the money sits, what moved, the
/// trend, accounts, and gold and silver.
extension FinanceReportHTML.Page {
    // MARK: Mix

    var mix: String {
        let lines = data.mix
        guard !lines.isEmpty else { return "" }
        let comparison = data.hero.comparisonName
        let stack = lines.filter { $0.share > 0 }.map { line in
            "<div title=\"\(escape("\(line.name) · \(line.valueText) · \(line.shareText)"))\" "
                + "style=\"flex:\(FinanceReportHTML.coordinate(line.share * 1000)) 1 0px;background:var(--s\(line.colorIndex))\"></div>"
        }.joined()
        let header = "<div class=\"lg hd\"><span class=\"sw\" style=\"background:none\"></span><span class=\"n\">Category</span>"
            + "<span class=\"v\">Value</span><span class=\"p\">Share</span>"
            + (comparison.map { "<span class=\"d\">vs \(escape($0))</span>" } ?? "") + "</div>"
        let rows = lines.map { line in
            "<div class=\"lg\"><span class=\"sw\" style=\"background:var(--s\(line.colorIndex))\"></span>"
                + "<span class=\"n\">\(escape(line.name))</span><span class=\"v\">\(escape(line.valueText))</span>"
                + "<span class=\"p\">\(escape(line.shareText))</span>"
                + (comparison == nil ? "" : "<span class=\"d \(FinanceReportHTML.toneClass(line.delta))\">\(escape(line.deltaText ?? "—"))</span>")
                + "</div>"
        }.joined()
        let tableRows = lines.map { line in
            [
                escape(line.name), escape(line.valueText), escape(line.shareText),
                escape(line.previous.map(FinanceFormat.money) ?? "—"), escape(line.deltaText ?? "—"),
            ]
        }
        let table = makeTable(["Category", ">Value", ">Share", ">\(comparison ?? "Before")", ">Change"], tableRows)
        return """
        <section class="card" id="mix"><h2>\(escape(title(of: "mix", otherwise: "Where the money sits")))</h2>\
        <p class="lede">\(escape(data.mixLede))</p>\
        <div class="stack" role="img" aria-label="Assets by kind">\(stack)</div>\
        <div class="legend">\(header)\(rows)</div>\(tableView(table))</section>
        """
    }

    // MARK: What moved

    var moved: String {
        let lines = data.moved
        guard !lines.isEmpty else { return "" }
        let largest = lines.map { abs($0.impact) }.max() ?? 0
        let heading = title(of: "moved", otherwise: "What moved") + (data.hero.deltaText.map { " · \($0)" } ?? "")
        let rows = lines.map { line in
            let share = largest > 0 ? abs(line.impact) / largest : 0
            let negative = line.impact.rounded() < 0 ? FinanceReportHTML.percent(share) : "0%"
            let positive = line.impact.rounded() > 0 ? FinanceReportHTML.percent(share) : "0%"
            return "<div class=\"mv\"><span class=\"n\" title=\"\(escape(line.name))\">\(escape(line.name))</span>"
                + "<div class=\"t\"><div><i class=\"neg\" style=\"width:\(negative)\"></i></div>"
                + "<div><i class=\"pos\" style=\"width:\(positive)\"></i></div></div>"
                + "<span class=\"val \(FinanceReportHTML.toneClass(line.impact))\">\(escape(line.impactText))</span></div>"
        }.joined()
        let table = makeTable(["Line", ">Effect on net worth"], lines.map { [escape($0.name), escape($0.impactText)] })
        return """
        <section class="card" id="moved"><h2>\(escape(heading))</h2>\
        <p class="lede">\(escape(data.movedLede))</p>\
        <div class="rows" style="gap:6px" role="img" aria-label="\(escape("Each line’s effect on net worth"))">\(rows)</div>\
        \(tableView(table))</section>
        """
    }

    // MARK: Trend

    var trend: String {
        let trend = data.trend
        var parts = ""
        if isYear, let year = data.year {
            parts += yearMinis(year)
        }
        parts += lineChart(trend.points, dips: Set(trend.dips))
        let table: String
        if isYear, let year = data.year {
            table = makeTable(
                ["Month", ">Net worth", ">Change", ">Spent", ">Budgets over"],
                year.months.map { row in
                    [
                        escape(row.period.title) + (row.isClosed ? "" : " <span class=\"flat\">· open</span>"),
                        escape(row.netWorthText), escape(row.changeText ?? "—"), escape(row.spendText), String(row.budgetsOver),
                    ]
                }
            )
        } else {
            var previous: Double?
            table = makeTable(
                ["Month", ">Net worth", ">Change"],
                trend.points.map { point in
                    defer { previous = point.value }
                    return [escape(point.period.title), escape(point.valueText), escape(previous.map { FinanceFormat.change(point.value - $0) } ?? "—")]
                }
            )
        }
        return """
        <section class="card" id="trend"><h2>\(escape(title(of: "trend", otherwise: isYear ? "Month by month" : "The last 12 months")))</h2>\
        <p class="lede">\(escape(trend.lede))</p>\(parts)\(tableView(table))</section>
        """
    }

    /// A year's start, end, best and worst month, over its chart.
    func yearMinis(_ year: FinanceReportData.YearSection) -> String {
        var tiles: [String] = []
        if let start = year.startNetWorth, let period = year.startPeriod {
            tiles.append(mini("Start · \(period.title)", FinanceFormat.money(start), "Net worth"))
        }
        // "End of 2026" read as the year's close in October, with a quarter
        // of it still to come: a year in progress names its last month.
        let last = year.months.last?.period
        let isOver = last?.month == 12 && year.months.last?.isClosed == true
        let endLabel = isOver || last == nil ? "End of \(year.year)" : "So far · \(last!.title)"
        let endDetail = year.changeText.map { "\($0) \(isOver ? "over the year" : "so far this year")" } ?? "Net worth"
        tiles.append(mini(endLabel, FinanceFormat.money(year.endNetWorth), endDetail))
        if let best = year.bestMonth, let change = best.changeText {
            tiles.append(mini("Best month", best.period.monthName, change, valueClass: ""))
        }
        if let worst = year.worstMonth, let change = worst.changeText, worst.id != year.bestMonth?.id {
            tiles.append(mini("Weakest month", worst.period.monthName, change, valueClass: ""))
        }
        return "<div class=\"grid minis\" style=\"margin-bottom:16px\">\(tiles.joined())</div>"
    }

    /// One small tile: label, value, detail.
    func mini(_ label: String, _ value: String, _ detail: String, valueClass: String = "") -> String {
        "<div class=\"mini\"><div class=\"l\">\(escape(label))</div>"
            + "<div class=\"v\(valueClass.isEmpty ? "" : " \(valueClass)")\">\(escape(value))</div>"
            + "<div class=\"s\">\(escape(detail))</div></div>"
    }

    /// The net-worth line, twice: a wide chart, and a narrow one with bigger
    /// type for a phone. One 880-wide SVG scaled into a 360-point web view
    /// set its month labels at about 4 points — unreadable — so the page
    /// carries both and CSS shows the one that fits.
    func lineChart(_ points: [FinanceReportData.TrendPoint], dips: Set<YearMonth>) -> String {
        guard !points.isEmpty else { return "" }
        let first = points[0]
        let last = points[points.count - 1]
        let label = escape("Net worth each month from \(first.period.title) to \(last.period.title)")
        let wide = lineChartSVG(points, dips: dips, width: 880, height: 240, left: 40, fontSize: 10.5, labelEvery: 1, label: label)
        let narrow = lineChartSVG(points, dips: dips, width: 360, height: 230, left: 44, fontSize: 11, labelEvery: points.count > 7 ? 2 : 1, label: label)
        return """
        <div class="chart-w">\(wide)</div><div class="chart-n">\(narrow)</div>
        """
    }

    func lineChartSVG(
        _ points: [FinanceReportData.TrendPoint],
        dips: Set<YearMonth>,
        width: Double,
        height: Double,
        left: Double,
        fontSize: Double,
        labelEvery: Int,
        label: String
    ) -> String {
        let c = FinanceReportHTML.coordinate
        let top = 20.0
        let bottom = height - 40
        let right = width - 20
        let ticks = FinanceReportHTML.niceTicks(points.map(\.value))
        let low = ticks.first ?? 0
        let high = ticks.last ?? 1
        let x: (Int) -> Double = { index in
            points.count == 1 ? (left + right) / 2 : left + Double(index) * (right - left) / Double(points.count - 1)
        }
        let y: (Double) -> Double = { value in
            high == low ? (top + bottom) / 2 : bottom - (value - low) / (high - low) * (bottom - top)
        }
        var svg = "<svg viewBox=\"0 0 \(c(width)) \(c(height))\" role=\"img\" aria-label=\"\(label)\" "
            + "style=\"width:100%;height:auto;display:block;overflow:visible\">"
        svg += "<g font-size=\"\(c(fontSize))\" fill=\"var(--muted)\" text-anchor=\"end\">"
        for (index, tick) in ticks.enumerated() {
            let ty = y(tick)
            svg += "<line x1=\"\(c(left))\" y1=\"\(c(ty))\" x2=\"\(c(width - 10))\" y2=\"\(c(ty))\" stroke=\"var(--\(index == 0 ? "axis" : "grid"))\"/>"
            svg += "<text x=\"\(c(left - 8))\" y=\"\(c(ty + 4))\">\(escape(FinanceFormat.compactMoney(tick)))</text>"
        }
        svg += "</g>"
        let xy = points.enumerated().map { (x($0.offset), y($0.element.value)) }
        if xy.count >= 2 {
            let line = xy.map { "\(c($0.0)),\(c($0.1))" }.joined(separator: " ")
            svg += "<polygon points=\"\(c(xy[0].0)),\(c(bottom)) \(line) \(c(xy[xy.count - 1].0)),\(c(bottom))\" fill=\"var(--s1)\" opacity=\"0.08\"/>"
            svg += "<polyline points=\"\(line)\" fill=\"none\" stroke=\"var(--s1)\" stroke-width=\"2.4\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>"
        }
        for (index, point) in points.enumerated() where dips.contains(point.period) && index != points.count - 1 {
            svg += "<circle cx=\"\(c(xy[index].0))\" cy=\"\(c(xy[index].1))\" r=\"3.5\" fill=\"var(--badfill)\" stroke=\"var(--surface)\" stroke-width=\"1.5\">"
                + "<title>\(escape("\(point.period.title): \(point.valueText)"))</title></circle>"
        }
        let end = xy[xy.count - 1]
        let last = points[points.count - 1]
        svg += "<circle cx=\"\(c(end.0))\" cy=\"\(c(end.1))\" r=\"5\" fill=\"var(--s1)\" stroke=\"var(--surface)\" stroke-width=\"2\"/>"
        let labelY = end.1 - 13 < 12 ? end.1 + 22 : end.1 - 13
        svg += "<text x=\"\(c(end.0 - 8))\" y=\"\(c(labelY))\" font-size=\"\(c(fontSize + 1.5))\" fill=\"var(--text)\" text-anchor=\"end\" font-weight=\"600\">\(escape(last.valueText))</text>"
        svg += "<g font-size=\"\(c(fontSize))\" fill=\"var(--muted)\" text-anchor=\"middle\">"
        for (index, point) in points.enumerated() {
            // Every `labelEvery`th month, counted back from the last so the
            // month the report is about always has its label.
            guard (points.count - 1 - index) % max(labelEvery, 1) == 0 else { continue }
            svg += "<text x=\"\(c(xy[index].0))\" y=\"\(c(bottom + 22))\">\(escape(point.label))</text>"
        }
        svg += "</g></svg>"
        return svg
    }

    // MARK: Accounts

    var accounts: String {
        guard !data.accountGroups.isEmpty else { return "" }
        let cards = data.accountGroups.map { group in
            let largest = group.rows.map { abs($0.value) }.max() ?? 0
            let rows = group.rows.map { row in
                let colour = FinanceReportHTML.ownerStyle(row.owner)
                let width = largest > 0 ? max(abs(row.value) / largest, 0.006) : 0
                let tip = [row.name, row.ownerName, row.valueText].compactMap(\.self).joined(separator: " · ")
                return "<div class=\"br\" style=\"grid-template-columns:minmax(90px,1fr) minmax(0,1.1fr) 84px\">"
                    + "<div class=\"bl\" title=\"\(escape(tip))\">\(escape(row.name))"
                    + (row.isUnchanged ? " <span>· unchanged</span>" : "") + "</div>"
                    + "<div class=\"bt\"><div class=\"bf \(colour.className)\" style=\"width:\(FinanceReportHTML.percent(width));\(colour.style)\"></div></div>"
                    + "<div class=\"bv\">\(escape(row.valueText))</div></div>"
            }.joined()
            let owners = group.owners.isEmpty ? "" : "<div class=\"owners\">" + group.owners.map { owner in
                let colour = FinanceReportHTML.ownerStyle(owner)
                return "<span><span class=\"sw \(colour.className)\" style=\"\(colour.style)\"></span>\(escape(owner.name))</span>"
            }.joined() + "</div>"
            let table = makeTable(
                ["Account", "Owner", ">Value", ">Change"],
                group.rows.map { row in
                    [escape(row.name), escape(row.ownerName ?? "—"), escape(row.valueText), escape(row.change.map(FinanceFormat.change) ?? "—")]
                }
            )
            return """
            <section class="card"><h2>\(escape(group.title)) · \(escape(group.totalText))</h2>\
            <p class="lede" style="margin-bottom:14px">\(escape(group.lede))</p>\
            <div class="rows">\(rows)</div>\(owners)\(tableView(table))</section>
            """
        }.joined()
        return "<div class=\"pair\" id=\"accounts\">\(cards)</div>"
    }

    // MARK: Gold and silver

    var metals: String {
        let metals = data.metals
        guard !metals.items.isEmpty else { return "" }
        var tiles: [String] = []
        for total in [metals.gold, metals.silver] where total.count > 0 {
            tiles.append(mini(total.metal.displayName, total.valueText, total.detail))
        }
        for location in metals.locations {
            tiles.append(mini(location.name.isEmpty ? "No location" : location.name, location.valueText, location.detail))
        }
        let largest = metals.items.map { abs($0.value) }.max() ?? 0
        let items = metals.items.map { item in
            let width = largest > 0 ? max(abs(item.value) / largest, 0.006) : 0
            return "<div class=\"br\"><div class=\"bl\" title=\"\(escape("\(item.name) · \(item.detail)"))\">\(escape(item.name)) "
                + "<span>· \(escape(item.detail))</span></div>"
                + "<div class=\"bt\"><div class=\"bf\" style=\"width:\(FinanceReportHTML.percent(width));background:var(--\(item.isTyped ? "s4" : "s1"))\"></div></div>"
                + "<div class=\"bv\">\(escape(item.valueText))</div></div>"
        }.joined()
        let keys = metals.typedItems.isEmpty ? "" : """
            <div class="keys"><span><span class="sw" style="background:var(--s1)"></span>Weight × price</span>\
            <span><span class="sw" style="background:var(--s4)"></span>Typed value</span></div>
            """
        var html = """
        <section class="card" id="metals"><h2>\(escape(title(of: "metals", otherwise: "Gold and silver"))) · \(escape(metals.totalText))</h2>\
        <p class="lede">\(escape(metals.lede))</p><div class="grid minis">\(tiles.joined())</div>\
        <h3>Every item, by value</h3>\(keys)<div class="rows">\(items)</div>
        """
        html += paidVersusNow
        html += tableView(makeTable(
            ["Item", "Metal", ">Weight", "Location", "Owner", ">Value", ">Paid", ">Change"],
            metals.items.map { item in
                [
                    escape(item.name) + (item.isTyped ? " <span class=\"flat\">· typed value</span>" : ""),
                    escape(item.metal.displayName), escape(item.gramsText), escape(item.location.isEmpty ? "—" : item.location),
                    escape(item.ownerName ?? "—"), escape(item.valueText), escape(item.costText ?? "—"),
                    escape(item.gainFraction.map(FinanceFormat.signedPercent) ?? "—"),
                ]
            }
        ))
        return html + "</section>"
    }

    /// The dumbbell: what each item with a recorded cost was paid, and what it's worth now.
    var paidVersusNow: String {
        let costed = data.metals.costedItems
        guard !costed.isEmpty else { return "" }
        let scale = (costed.map { max($0.cost ?? 0, $0.value) }.max() ?? 0) * 1.06
        guard scale > 0 else { return "" }
        let rows = costed.map { item in
            let paid = (item.cost ?? 0) / scale
            let now = item.value / scale
            let change = item.gainFraction.map(FinanceFormat.signedPercent) ?? "—"
            let tip = "\(item.name): paid \(item.costText ?? "—"), now \(item.valueText)"
            return "<div class=\"dumb\" title=\"\(escape(tip))\"><div class=\"n\">\(escape(item.name))</div><div class=\"tr\">"
                + "<div class=\"cn\" style=\"left:\(FinanceReportHTML.percent(min(paid, now)));width:\(FinanceReportHTML.percent(abs(now - paid)))\"></div>"
                + "<div class=\"dt\" style=\"left:\(FinanceReportHTML.percent(paid));background:var(--s4)\"></div>"
                + "<div class=\"dt\" style=\"left:\(FinanceReportHTML.percent(now));background:var(--s1)\"></div></div>"
                + "<div class=\"ch \(FinanceReportHTML.toneClass(item.gain))\">\(escape(change))</div></div>"
        }.joined()
        let heading = costed.count == data.metals.items.count
            ? "Paid vs now"
            : "Paid vs now · the \(counted(costed.count, "item")) with a recorded cost"
        return """
        <h3>\(escape(heading))</h3>\
        <div class="keys"><span><span class="sw dot" style="background:var(--s4)"></span>Paid</span>\
        <span><span class="sw dot" style="background:var(--s1)"></span>Now</span></div>\
        <div class="rows" style="gap:6px">\(rows)</div>
        """
    }
}

extension FinanceReportHTML {
    /// Round axis values covering every value: four or so steps of 1, 2, 2.5
    /// or 5 times a power of ten, lowest first. A flat series gets a band
    /// around it so the line sits mid-chart rather than on an edge.
    static func niceTicks(_ values: [Double], steps: Int = 4) -> [Double] {
        let finite = values.filter(\.isFinite)
        guard var low = finite.min(), var high = finite.max() else { return [0, 1] }
        if high - low < 1 {
            let pad = max(abs(high) * 0.05, 100)
            low -= pad
            high += pad
        }
        let rough = (high - low) / Double(max(steps, 1))
        let magnitude = pow(10, floor(log10(rough)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= rough } ?? 10 * magnitude
        let start = floor(low / step) * step
        let end = ceil(high / step) * step
        var ticks: [Double] = []
        var tick = start
        while tick <= end + step / 2 && ticks.count < 12 {
            ticks.append(tick)
            tick += step
        }
        return ticks
    }
}

#if DEBUG
import CoreData
import Foundation

/// Fills a household with made-up figures so the module has something in it
/// on a fresh simulator. Debug builds only, only when launched with
/// `-FinanceSeed`, and a no-op once any household has data. Generic sample
/// data — nothing from the real Numbers sheet.
///
/// Twelve months, the last left open with only its cash filled in, so the
/// Summary (and a report) headlines the month before it, as a real
/// half-typed month does. That month is built to set off the report's
/// checks: Food over budget, Subscriptions over two months running with a
/// new $9.99 charge, Travel with none in the months before, spending in
/// categories with no budget (one kept with "No budget", the
/// `SharedFinanceBudget.noLimit` sentinel) and none at all, two balances
/// that match the month before to the dollar, investments that dip twice in
/// the year. The typed-value ring and the coin with no cost basis are
/// metals. With only three months seeded, the report's 12-month line,
/// 3-month averages and year in review had nothing to show.
public enum FinanceDebugSeed {
    public static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "FinanceSeed")
    }

    /// How many months the seed makes, ending with the open one.
    static let monthCount = 12

    /// (day, cost, merchant, category, expense, paid-with index) — cards
    /// 0…2, then 3 for the joint checking account.
    typealias Charge = (day: Int, cost: Double, merchant: String, category: String, expense: String, account: Int)

    @MainActor
    public static func run(context: NSManagedObjectContext, container: NSPersistentCloudKitContainer?, asOf now: Date = .now) {
        let households = (try? context.fetch(SharedFinanceHousehold.fetchRequest())) ?? []
        guard households.allSatisfy(\.isEmpty) else { return }

        let household = FinanceHouseholdResolver.forWriting(in: context, container: container)
        // A new household starts with no people, so the seed makes its own.
        if household.sortedOwners.isEmpty {
            _ = SharedFinanceOwner(name: "Bhavik", household: household)
            _ = SharedFinanceOwner(name: "Saloni", household: household)
            _ = SharedFinanceOwner(name: "Joint", kind: .joint, household: household)
        }
        let owners = household.sortedOwners
        func owner(_ name: String) -> SharedFinanceOwner? {
            owners.first { $0.name == name }
        }
        let bhavik = owner("Bhavik")
        let saloni = owner("Saloni")
        let joint = owner("Joint")

        // (institution, name, category, owner, balance in the month before
        // last, monthly change, matches the month before when finished last)
        let accountSamples: [(String, String, AccountCategory, SharedFinanceOwner?, Double, Double, Bool)] = [
            ("First Bank", "Checking", .cash, joint, 8_200, 350, false),
            ("First Bank", "Savings", .cash, joint, 24_000, 500, false),
            ("Credit Union", "Checking", .cash, bhavik, 3_100, 120, false),
            ("Online Bank", "High-yield savings", .cash, saloni, 12_400, 300, false),
            ("Online Brokerage", "Taxable", .investments, bhavik, 61_500, 1_200, false),
            ("Online Brokerage", "Taxable", .investments, saloni, 38_000, 900, true),
            ("Plan Provider", "401(k)", .retirement, bhavik, 142_000, 2_100, false),
            ("Plan Provider", "Roth IRA", .retirement, saloni, 57_300, 800, false),
            ("Benefits Co", "HSA", .health, bhavik, 4_600, 150, true),
            ("", "Family car", .fixed, joint, 21_000, -250, false),
            ("Auto Lender", "Car loan", .loan, joint, 14_800, -420, false),
        ]
        var monthly: [(account: SharedFinanceAccount, start: Double, change: Double, stale: Bool)] = []
        for (institution, name, category, owner, start, change, stale) in accountSamples {
            let account = SharedFinanceAccount(institution: institution, name: name, category: category, household: household, owner: owner)
            monthly.append((account, start, change, stale))
        }

        let cardSamples: [(String, String, SharedFinanceOwner?, Double, Double)] = [
            ("Big Bank", "Travel Rewards", bhavik, 25_000, 95),
            ("Big Bank", "Cash Back", saloni, 12_000, 0),
            ("Store", "Everyday", joint, 8_000, 0),
        ]
        var payers: [SharedFinanceAccount] = []
        for (institution, name, owner, limit, fee) in cardSamples {
            let card = SharedFinanceAccount(institution: institution, name: name, category: .card, household: household, owner: owner)
            card.limit = limit
            card.annualFee = fee
            payers.append(card)
        }
        // Rent by Zelle, straight from the joint checking account: spending
        // that isn't owed on a card.
        payers.append(monthly[0].account)

        let gold = SharedFinanceMetalItem(name: "Gold - Bar 100 g", metal: .gold, grams: 100, household: household, owner: joint)
        gold.location = "Locker"
        gold.pricePaidPerOz = 2_300
        let chain = SharedFinanceMetalItem(name: "Gold - Chain", metal: .gold, grams: 27, household: household, owner: saloni)
        chain.location = "Home"
        chain.purchaseValue = 1_900
        let ring = SharedFinanceMetalItem(name: "Gold - Ring", metal: .gold, grams: 6, household: household, owner: saloni)
        ring.location = "Home"
        ring.hasManualValue = true
        ring.manualValue = 3_500
        let coin = SharedFinanceMetalItem(name: "Gold - Coin 1 oz", metal: .gold, grams: 31.1035, household: household, owner: bhavik)
        coin.location = "Locker"
        let silver = SharedFinanceMetalItem(name: "Silver - Bar 50 g", metal: .silver, grams: 50, household: household, owner: joint)
        silver.location = "Locker"
        silver.pricePaidPerOz = 28

        // Twelve months ending with this one; the last is left open. Index
        // `last - 2` is "the month before last" the samples start from.
        let current = YearMonth(containing: now)
        let last = monthCount - 1
        let periods = (0..<monthCount).map { YearMonth(year: current.year, month: current.month - (last - $0)) }
        let goldPrices = [3_400.0, 3_480, 3_560, 3_650, 3_720, 3_800, 3_900, 4_000, 4_150, 4_300, 4_420, 4_500]
        let silverPrices = [38.0, 39, 40, 41, 42.5, 43, 44, 45.5, 47, 48, 50.5, 52]
        let budgets: [(String, Double)] = [
            ("Food", 600), ("Groceries", 700), ("Travel", 400),
            ("Entertainment", 200), ("Home", 2_700), ("Subscriptions", 80),
            // Tracked on purpose with no limit.
            ("Clothes", SharedFinanceBudget.noLimit),
        ]

        func amount(_ sample: (account: SharedFinanceAccount, start: Double, change: Double, stale: Bool), at index: Int) -> Double {
            // The last finished month carries a few balances over unchanged,
            // the way one nobody looked up does.
            let effective = sample.stale && index == last - 1 ? last - 2 : index
            var value = sample.start + sample.change * Double(effective - (last - 2))
            // Two market dips in Bhavik's brokerage, so the year has months
            // that fell.
            if sample.account.category == .investments, sample.account.owner == bhavik, [3, 7].contains(effective) {
                value -= 9_000
            }
            return value
        }

        for (index, period) in periods.enumerated() {
            let month = SharedFinanceMonth(period: period, household: household)
            month.goldPricePerOz = goldPrices[index]
            month.silverPricePerOz = silverPrices[index]
            let isOpen = index == last
            for sample in monthly {
                // The open month the way a new one starts now: zero, except
                // the cash already filled in.
                let filled = !isOpen || sample.account.category == .cash
                _ = SharedFinanceBalance(account: sample.account, month: month, amount: filled ? amount(sample, at: index) : 0, edited: filled)
            }
            for (category, limit) in budgets {
                _ = SharedFinanceBudget(category: category, limit: limit, month: month)
            }
            if !isOpen {
                month.close(asOf: period.end)
            }

            let charges = isOpen ? openMonthCharges : finishedMonthCharges(index: index, last: last)
            // The open month's days are squeezed into the part already gone,
            // so the budget pace reads sensibly.
            let today = FinanceCalendar.calendar.component(.day, from: now)
            for charge in charges {
                let day = isOpen ? max(1, min(charge.day, today)) : charge.day
                let date = FinanceCalendar.date(period.year, period.month, day).addingTimeInterval(12 * 3_600)
                let transaction = SharedFinanceTransaction(date: date, cost: charge.cost, merchant: charge.merchant, household: household, card: payers[charge.account])
                transaction.category = charge.category
                transaction.expense = charge.expense
                transaction.breakDown = "N/A"
                if charge.merchant == "Taqueria" {
                    // A friend's covering half.
                    transaction.actualCost = charge.cost / 2
                    transaction.breakDown = "Split with a friend"
                }
            }
        }
        try? context.save()
    }

    /// A finished month's spending. Every month has rent, groceries (always
    /// under budget), food out, a streaming and a gym subscription, a film
    /// and fuel; every other month an anniversary dinner puts Food over.
    /// Cloud storage starts the month before last, putting Subscriptions over
    /// for two months running. The last finished month adds the report's
    /// talking points.
    static func finishedMonthCharges(index: Int, last: Int) -> [Charge] {
        let wobble = Double(index % 3)
        var charges: [Charge] = [
            (1, 2_400, "Landlord", "Home", "Rent (Zelle)", 3),
            (2, 152.30 + wobble * 6, "Corner Market", "Groceries", "Weekly shop", 2),
            (9, 148.75 - Double(index % 4) * 4, "Corner Market", "Groceries", "Weekly shop", 2),
            (16, 139.20 + Double(index % 2) * 9, "Corner Market", "Groceries", "Weekly shop", 2),
            (23, 141.60, "Corner Market", "Groceries", "Weekly shop", 2),
            (5, 15.99, "Streaming Co", "Subscriptions", "TV", 1),
            (7, 59.99, "Gym App", "Subscriptions", "Gym", 0),
            (11, 62.00 + Double(index % 5) * 8, "Noodle House", "Food", "Dinner", 0),
            (18, 36.50 + Double(index % 4) * 6, "Bakery", "Food", "Breakfast", 0),
            (25, 240.00 + wobble * 30, "Taqueria", "Food", "Dinner with friends", 0),
            (14, 30.00 + wobble * 15, "Cinema", "Entertainment", "Movie night", 1),
            (20, 38.00 + wobble * 9, "Gas Station", "Car", "Fuel", 2),
        ]
        if index % 2 == 0 {
            charges.append((27, 380, "Steak House", "Food", "Anniversary dinner", 0))
        }
        if index >= last - 2 {
            charges.append((8, 14.99, "Cloud Storage", "Subscriptions", "Photos", 1))
        }
        if index == 4 {
            charges.append((12, 420, "Airline", "Travel", "Flights", 0))
        }
        if index % 4 == 1 {
            charges.append((21, 140, "Hardware Store", "Home", "Shelves", 2))
        }
        if index == last - 1 {
            charges += [
                (12, 9.99, "Music App", "Subscriptions", "Music", 1),
                (9, 310, "Airline", "Travel", "Flights", 0),
                (15, 120, "Clothes Shop", "Clothes", "Jacket", 1),
                (16, -40, "Clothes Shop", "Clothes", "Return", 1),
                (3, 13.35, "City Parking", "Parking", "Parking", 0),
                (8, 23.40, "Pharmacy", "Health", "Prescriptions", 1),
                (19, 55, "Office Supply", "Work", "Printer ink", 0),
                (10, 29, "Bowling Alley", "Entertainment", "Bowling", 1),
                // Typed in a hurry with no category.
                (22, 18, "Corner Kiosk", "", "", 2),
            ]
        }
        return charges
    }

    /// The open month so far.
    static let openMonthCharges: [Charge] = [
        (1, 2_400, "Landlord", "Home", "Rent (Zelle)", 3),
        (1, 54.20, "Corner Market", "Groceries", "Weekly shop", 2),
        (2, 12.50, "Coffee Place", "Food", "Coffee", 0),
        (3, 4.35, "City Parking", "Parking", "Parking", 0),
        (4, 88.10, "Corner Market", "Groceries", "Weekly shop", 2),
        (5, 15.99, "Streaming Co", "Subscriptions", "TV", 1),
        (6, 62.00, "Noodle House", "Food", "Dinner", 0),
        (7, 140.00, "Hardware Store", "Home", "Shelves", 2),
        (7, 59.99, "Gym App", "Subscriptions", "Gym", 0),
        (8, 23.40, "Pharmacy", "Health", "Prescriptions", 1),
        (8, 14.99, "Cloud Storage", "Subscriptions", "Photos", 1),
        (10, 45.00, "Cinema", "Entertainment", "Movie night", 1),
        (11, 71.35, "Corner Market", "Groceries", "Weekly shop", 2),
        (12, 9.99, "Music App", "Subscriptions", "Music", 1),
        (13, 96.00, "Taqueria", "Food", "Dinner with friends", 0),
        (14, 38.00, "Gas Station", "Car", "Fuel", 2),
        (15, 120.00, "Clothes Shop", "Clothes", "Jacket", 1),
        (16, -40.00, "Clothes Shop", "Clothes", "Return", 1),
        (17, 64.80, "Corner Market", "Groceries", "Weekly shop", 2),
        (18, 18.25, "Bakery", "Food", "Breakfast", 0),
        (19, 55.00, "Office Supply", "Work", "Printer ink", 0),
        (20, 29.00, "Bowling Alley", "Entertainment", "Bowling", 1),
    ]
}
#endif

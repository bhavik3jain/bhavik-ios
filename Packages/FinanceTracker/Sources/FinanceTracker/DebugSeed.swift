#if DEBUG
import CoreData
import Foundation

/// Fills a household with made-up figures so the module has something in it
/// on a fresh simulator. Debug builds only, only when launched with
/// `-FinanceSeed`, and a no-op once any household has data. Generic sample
/// data — nothing from the real Numbers sheet.
public enum FinanceDebugSeed {
    public static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "FinanceSeed")
    }

    @MainActor
    public static func run(context: NSManagedObjectContext, container: NSPersistentCloudKitContainer?, asOf now: Date = .now) {
        let households = (try? context.fetch(SharedFinanceHousehold.fetchRequest())) ?? []
        guard households.allSatisfy(\.isEmpty) else { return }

        let household = FinanceHouseholdResolver.forWriting(in: context, container: container)
        let owners = household.sortedOwners
        func owner(_ name: String) -> SharedFinanceOwner? {
            owners.first { $0.name == name }
        }
        let bhavik = owner("Bhavik")
        let saloni = owner("Saloni")
        let joint = owner("Joint")

        // (institution, name, category, owner, balance two months ago, monthly change)
        let accountSamples: [(String, String, AccountCategory, SharedFinanceOwner?, Double, Double)] = [
            ("First Bank", "Checking", .cash, joint, 8_200, 350),
            ("First Bank", "Savings", .cash, joint, 24_000, 500),
            ("Online Brokerage", "Taxable", .investments, bhavik, 61_500, 1_200),
            ("Online Brokerage", "Taxable", .investments, saloni, 38_000, 900),
            ("Plan Provider", "401(k)", .retirement, bhavik, 142_000, 2_100),
            ("Plan Provider", "Roth IRA", .retirement, saloni, 57_300, 800),
            ("", "Family car", .fixed, joint, 21_000, -250),
            ("Auto Lender", "Car loan", .loan, joint, 14_800, -420),
        ]
        var monthly: [(SharedFinanceAccount, Double, Double)] = []
        for (institution, name, category, owner, start, change) in accountSamples {
            let account = SharedFinanceAccount(institution: institution, name: name, category: category, household: household, owner: owner)
            monthly.append((account, start, change))
        }

        let cardSamples: [(String, String, SharedFinanceOwner?, Double, Double)] = [
            ("Big Bank", "Travel Rewards", bhavik, 25_000, 95),
            ("Big Bank", "Cash Back", saloni, 12_000, 0),
            ("Store", "Everyday", joint, 8_000, 0),
        ]
        var cards: [SharedFinanceAccount] = []
        for (institution, name, owner, limit, fee) in cardSamples {
            let card = SharedFinanceAccount(institution: institution, name: name, category: .card, household: household, owner: owner)
            card.limit = limit
            card.annualFee = fee
            cards.append(card)
        }

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

        // Three months ending with this one; the last is left open.
        let current = YearMonth(containing: now)
        let periods = [current.previous.previous, current.previous, current]
        let goldPrices = [4_300.0, 4_420.0, 4_500.0]
        let silverPrices = [48.0, 50.5, 52.0]
        let budgets: [(String, Double)] = [
            ("Food", 600), ("Groceries", 700), ("Travel", 400),
            ("Entertainment", 200), ("Home", 300), ("Subscriptions", 80),
        ]
        for (index, period) in periods.enumerated() {
            let month = SharedFinanceMonth(period: period, household: household)
            month.goldPricePerOz = goldPrices[index]
            month.silverPricePerOz = silverPrices[index]
            for (account, start, change) in monthly {
                _ = SharedFinanceBalance(account: account, month: month, amount: start + change * Double(index), edited: index < 2 || account.category == .cash)
            }
            for (category, limit) in budgets {
                _ = SharedFinanceBudget(category: category, limit: limit, month: month)
            }
            if index < 2 {
                month.close(asOf: period.end)
            }
        }

        // (day, cost, merchant, category, expense, card index)
        let transactionSamples: [(Int, Double, String, String, String, Int)] = [
            (1, 54.20, "Corner Market", "Groceries", "Weekly shop", 2),
            (2, 12.50, "Coffee Place", "Food", "Coffee", 0),
            (3, 4.35, "City Parking", "Parking", "Parking", 0),
            (4, 88.10, "Corner Market", "Groceries", "Weekly shop", 2),
            (5, 15.99, "Streaming Co", "Subscriptions", "TV", 1),
            (6, 62.00, "Noodle House", "Food", "Dinner", 0),
            (7, 140.00, "Hardware Store", "Home", "Shelves", 2),
            (8, 23.40, "Pharmacy", "Health", "Prescriptions", 1),
            (9, 310.00, "Airline", "Travel", "Flights", 0),
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
        // Days are squeezed into the part of the month already gone, so the
        // budget pace reads sensibly.
        let today = FinanceCalendar.calendar.component(.day, from: now)
        for (day, cost, merchant, category, expense, cardIndex) in transactionSamples {
            let clampedDay = max(1, min(day, today))
            let date = FinanceCalendar.date(current.year, current.month, clampedDay).addingTimeInterval(12 * 3_600)
            let transaction = SharedFinanceTransaction(date: date, cost: cost, merchant: merchant, household: household, card: cards[cardIndex])
            transaction.category = category
            transaction.expense = expense
            transaction.breakDown = "N/A"
            if merchant == "Taqueria" {
                // A friend's covering half.
                transaction.actualCost = cost / 2
                transaction.breakDown = "Split with a friend"
            }
        }
        try? context.save()
    }
}
#endif

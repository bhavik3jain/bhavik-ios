#if DEBUG
import CoreData
import Foundation

/// Adds a small household's worth of accounts so the module has something in
/// it on a fresh simulator. Debug builds only, only when launched with
/// `-PointsSeed`, and a no-op once any account exists.
public enum PointsDebugSeed {
    public static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "PointsSeed")
    }

    @MainActor
    public static func run(context: NSManagedObjectContext, container: NSPersistentCloudKitContainer?) {
        guard ((try? context.count(for: SharedPointsAccount.fetchRequest())) ?? 0) == 0 else { return }

        let household = HouseholdResolver.forWriting(in: context, container: container)
        let alex = SharedPointsOwner(name: "Alex", household: household)
        let sam = SharedPointsOwner(name: "Sam", household: household)

        let samples: [(String, String, PointsKind, SharedPointsOwner?, Int, Int?)] = [
            ("Sapphire Reserve", "Ultimate Rewards", .creditCard, alex, 184_250, nil),
            ("Amex Gold", "Membership Rewards", .creditCard, sam, 96_400, nil),
            ("Bonvoy", "Marriott Bonvoy", .hotel, alex, 62_000, 40),
            ("World of Hyatt", "", .hotel, sam, 31_500, nil),
            ("United", "MileagePlus", .airline, alex, 48_900, nil),
            ("Delta", "SkyMiles", .airline, nil, 12_300, nil)
        ]
        for (name, program, kind, owner, balance, expiresInDays) in samples {
            let account = SharedPointsAccount(name: name, kind: kind, household: household, owner: owner)
            account.program = program
            if let expiresInDays {
                account.expiresAt = Date.now.addingTimeInterval(TimeInterval(expiresInDays) * 86_400)
            }
            account.recordBalance(balance - 5_000, note: "Opening balance", asOf: .now.addingTimeInterval(-30 * 86_400))
            account.recordBalance(balance)
        }
        try? context.save()
    }
}
#endif

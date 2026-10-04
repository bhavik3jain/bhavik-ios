import Core
import CoreData
import Foundation
import UserNotifications

public extension FinanceTrackerModule {
    /// Finance's wording for Core's shared-change notifications — see
    /// `SharedChangeNotifier`, which `BhavikApp` hands this to. The root is
    /// always the household.
    ///
    /// Never an amount: a notification shows on the lock screen, and a
    /// balance or a charge is nobody else's business.
    static func describeSharedChange(_ object: NSManagedObject, _ change: SharedObjectChange) -> SharedChangeDescription? {
        let inserted = change.kind == .inserted
        switch object {
        case let household as SharedFinanceHousehold:
            return description(household, inserted ? "shared \(householdName(household))" : "updated \(householdName(household))")

        case let owner as SharedFinanceOwner:
            guard let household = owner.household else { return nil }
            let name = named(owner.name, fallback: "someone")
            return description(household, inserted ? "added \(name)" : "changed \(name)")

        case let account as SharedFinanceAccount:
            guard let household = account.household else { return nil }
            let name = named(account.name, fallback: "an account")
            return description(household, inserted ? "added \(name)" : "changed \(name)")

        case let month as SharedFinanceMonth:
            guard let household = month.household else { return nil }
            let title = month.period?.title ?? "a month"
            let action: String
            if inserted {
                action = "started \(title)"
            } else if change.updatedProperties.contains("closedAt") {
                action = month.closedAt == nil ? "reopened \(title)" : "closed \(title)"
            } else {
                action = "updated \(title)"
            }
            return description(household, action)

        case let balance as SharedFinanceBalance:
            guard let household = balance.month?.household ?? balance.account?.household else { return nil }
            let name = named(balance.account?.name ?? "", fallback: "a balance")
            let month = balance.month?.period.map { " for \($0.title)" } ?? ""
            return description(household, "updated \(name)\(month)")

        case let budget as SharedFinanceBudget:
            guard let household = budget.month?.household else { return nil }
            // "the", never "a", in front of the category: a hard-coded "a"
            // read "set a Entertainment budget" for any category starting
            // with a vowel. A blank category still reads "set the budget".
            let category = budget.category.trimmingCharacters(in: .whitespacesAndNewlines)
            let budgetName = category.isEmpty ? "budget" : "\(category) budget"
            let month = budget.month?.period.map { " for \($0.title)" } ?? ""
            if !budget.hasLimit {
                // A category kept with no budget (`SharedFinanceBudget.noLimit`).
                let name = category.isEmpty ? "a category" : category
                return description(household, inserted ? "added \(name)\(month)" : "took the budget off \(name)\(month)")
            }
            return description(household, inserted ? "set the \(budgetName)\(month)" : "changed the \(budgetName)\(month)")

        case let item as SharedFinanceMetalItem:
            guard let household = item.household else { return nil }
            let name = named(item.name, fallback: "a metal item")
            return description(household, inserted ? "added \(name)" : "changed \(name)")

        case let transaction as SharedFinanceTransaction:
            guard let household = transaction.household ?? transaction.card?.household else { return nil }
            let merchant = transaction.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            // The merchant goes after "at", never after an article: "a \(merchant)
            // transaction" read "added a Amazon transaction" on the lock screen.
            let what = merchant.isEmpty ? "a transaction" : "a transaction at \(merchant)"
            return description(household, inserted ? "added \(what)" : "changed \(what)")

        default:
            return nil
        }
    }

    private static func description(_ household: SharedFinanceHousehold, _ action: String) -> SharedChangeDescription {
        SharedChangeDescription(rootID: household.objectID, rootTitle: householdName(household), action: action)
    }

    fileprivate static func householdName(_ household: SharedFinanceHousehold) -> String {
        named(household.name, fallback: "Household")
    }

    private static func named(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

/// "September's report is ready": told to this device when a month is
/// finished on another one — a partner's device, or this person's own other
/// device — so the report built from it is worth opening. A tap opens Finance
/// on that month's report (`FinanceReportRouter`).
///
/// It rides on `SharedChangeNotifier` rather than reading persistent history
/// itself: the notifier already sees exactly the changes CloudKit imported,
/// once each, across launches, and never this device's own saves — and
/// anything new that read history would have to be added to the notifier's
/// purge cutoff, or lose the transactions it hadn't read yet. `watching(_:…)`
/// wraps Finance's describer for the notifier only; iCloud's own alerts
/// (`SharedChangeServerAlerts`) get the plain describer, which they also call
/// just to look up a household's title.
///
/// Never an amount, like every Finance notification: it shows on the lock
/// screen.
public enum FinanceReportReady {
    /// Every notice's identifier starts with this; one per month, so closing,
    /// reopening and closing again replaces the notice rather than stacking.
    public static let identifierPrefix = "finance.reportReady."

    /// How long after a month was closed its synced close is still news. A
    /// device that was off for longer has missed the moment — and the guard
    /// keeps a re-import of an old month (which can mark `closedAt` as
    /// updated without anyone closing anything) from announcing it again.
    static let freshness: TimeInterval = 3 * 24 * 60 * 60

    /// The closes already notified, newest last, so one close is told once
    /// however many times its record is re-imported.
    static let ledgerKey = "finance.reportReady.notified"
    static let ledgerLimit = 24

    public struct Notice: Sendable, Equatable {
        public let identifier: String
        public let scope: ReportScope
        public let title: String
        public let body: String
        public let closedAt: Date

        /// What a tap hands to `FinanceReportRouter.open(destination:)`.
        public var destination: String { FinanceReportRouter.destination(for: scope) }

        /// One close: the month and the moment, so a reopen-and-close later
        /// is news again.
        var ledgerEntry: String { "\(scope.rawValue)@\(Int(closedAt.timeIntervalSince1970))" }
    }

    /// The notice for a change the notifier imported, or nil when it isn't a
    /// month being finished. Only an update that touched `closedAt` and left
    /// it set counts: a month that arrives already closed is an import of an
    /// old month or the download after joining a share, not a month someone
    /// just finished.
    public static func notice(
        for object: NSManagedObject,
        _ change: SharedObjectChange,
        asOf now: Date = .now
    ) -> Notice? {
        guard change.kind == .updated,
              change.updatedProperties.contains("closedAt"),
              let month = object as? SharedFinanceMonth,
              let closedAt = month.closedAt,
              let period = month.period,
              now.timeIntervalSince(closedAt) < freshness
        else { return nil }
        let household = month.household.map(FinanceTrackerModule.householdName) ?? "Household"
        return notice(period: period, closedAt: closedAt, householdTitle: household, asOf: now)
    }

    /// "September's report is ready" — the year too once it isn't this
    /// year's, so January's notice about December says "December 2025".
    public static func notice(period: YearMonth, closedAt: Date, householdTitle: String, asOf now: Date = .now) -> Notice {
        let name = period.year == YearMonth(containing: now).year ? period.monthName : period.title
        return Notice(
            identifier: identifierPrefix + period.rawValue,
            scope: .month(period),
            title: "\(name)'s report is ready",
            body: "\(period.title) is finished in \(householdTitle). Open it to see what changed and what to watch.",
            closedAt: closedAt
        )
    }

    /// Records `notice` as told; false if this same close was told already.
    static func claim(_ notice: Notice, defaults: UserDefaults) -> Bool {
        var told = defaults.stringArray(forKey: ledgerKey) ?? []
        guard !told.contains(notice.ledgerEntry) else { return false }
        told.append(notice.ledgerEntry)
        defaults.set(Array(told.suffix(ledgerLimit)), forKey: ledgerKey)
        return true
    }

    /// Finance's describer for `SharedChangeNotifier`, which also posts the
    /// report-ready notice when a change finishes a month and `isEnabled()`
    /// (Settings' "Notify when a report is ready") says so. The describer's
    /// own answer is returned unchanged, so the shared-change notification
    /// ("Saloni closed September 2026") still goes out beside it.
    ///
    /// Runs on the notifier's background context, like any describer: reads
    /// the object, never saves it. `isEnabled` must be safe to call there.
    public static func watching(
        _ describe: @escaping SharedChangeDescriber,
        moduleID: String,
        moduleName: String,
        isEnabled: @escaping @Sendable () -> Bool
    ) -> SharedChangeDescriber {
        { object, change in
            if let notice = notice(for: object, change), isEnabled(), claim(notice, defaults: .standard) {
                post(notice, moduleID: moduleID, moduleName: moduleName)
            }
            return describe(object, change)
        }
    }

    /// Hands `notice` to the system. Carries the module, so a tap opens
    /// Finance through the same router as a shared-change notification, and
    /// the destination, so it opens on the report. Without permission the
    /// center drops it silently, which is the right outcome.
    static func post(_ notice: Notice, moduleID: String, moduleName: String) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = moduleName
        content.body = notice.body
        content.sound = .default
        content.threadIdentifier = notice.identifier
        content.userInfo = [
            SharedChangeNotifications.moduleUserInfoKey: moduleID,
            SharedChangeNotifications.destinationUserInfoKey: notice.destination,
        ]
        let request = UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil)
        let title = notice.title
        UNUserNotificationCenter.current().add(request) { error in
            SharedChangeActivityLog.record(SharedChangeLogEntry(
                moduleID: moduleID,
                outcome: error == nil ? .posted : .refused,
                detail: error.map { "\(title) (\($0.localizedDescription))" } ?? title
            ))
        }
    }
}

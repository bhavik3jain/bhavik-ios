import Foundation
import UserNotifications

/// "October has started" on the 1st of every month, at 9 in the morning:
/// the nudge to fill in the month's balances.
///
/// One notification per month rather than one repeating trigger, so each
/// can name its month. A year of them is scheduled whenever Finance opens,
/// which keeps the run going for anyone who opens it at least once a year.
/// They're local, so each partner gets their own and nothing syncs.
public enum FinanceMonthReminder {
    /// Settings' "Monthly reminder" switch. On by default.
    public static let enabledKey = "finance.monthlyReminder"
    /// Every scheduled request's identifier starts with this, so a
    /// reschedule clears exactly these and nothing else.
    static let identifierPrefix = "finance.monthStart."
    static let hour = 9
    static let monthsAhead = 12

    struct Reminder: Equatable {
        let identifier: String
        let period: YearMonth
        let fireDate: DateComponents
        let title: String
        let body: String
    }

    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// The next `monthsAhead` 1sts after `now`. Today's is included only
    /// while 9 a.m. hasn't passed.
    static func upcoming(asOf now: Date = .now, calendar: Calendar = FinanceCalendar.calendar) -> [Reminder] {
        let current = YearMonth(containing: now)
        let firesToday = calendar.component(.day, from: now) == 1 && calendar.component(.hour, from: now) < hour
        var period = firesToday ? current : current.next
        var reminders: [Reminder] = []
        for _ in 0..<monthsAhead {
            reminders.append(Reminder(
                identifier: identifierPrefix + period.rawValue,
                period: period,
                fireDate: DateComponents(year: period.year, month: period.month, day: 1, hour: hour),
                title: "\(period.monthName) has started",
                body: "Time to fill in \(period.monthName)'s balances in Finance."
            ))
            period = period.next
        }
        return reminders
    }

    /// Replaces whatever reminders are pending with a fresh year of them,
    /// or just removes them when the switch is off. Asks for permission the
    /// first time; without it the center drops them silently.
    public static func reschedule(asOf now: Date = .now) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard isEnabled() else { return }
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        for reminder in upcoming(asOf: now) {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            content.threadIdentifier = "finance.monthStart"
            // Read by Core's notification delegate: a tap opens Finance.
            content.userInfo = ["module": "finance"]
            let trigger = UNCalendarNotificationTrigger(dateMatching: reminder.fireDate, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger))
        }
    }
}

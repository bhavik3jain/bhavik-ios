import Foundation
import Observation

/// A report someone outside Finance asked to see — today only a tapped
/// "September's report is ready" notification (`FinanceReportReady`). The app
/// sets `pending` (see `open(destination:)`), opens Finance, and Finance's root
/// view presents the report and clears it.
///
/// Process-wide rather than an environment value: the tap can land before any
/// window exists (it launched the app), and on the Mac whichever window is in
/// front should answer it, once.
@MainActor
@Observable
public final class FinanceReportRouter {
    public static let shared = FinanceReportRouter()

    /// The report to present, until Finance has presented it. Finance clears it.
    public var pending: ReportScope?

    private init() {}

    /// What a report-ready notification carries as its destination
    /// (`SharedChangeNotifications.destinationUserInfoKey`).
    public nonisolated static let destinationPrefix = "finance.report:"

    public nonisolated static func destination(for scope: ReportScope) -> String {
        destinationPrefix + scope.rawValue
    }

    /// The scope a destination names, or nil for anything that isn't a
    /// Finance report — another module's destination passes through untouched.
    public nonisolated static func scope(fromDestination destination: String) -> ReportScope? {
        guard destination.hasPrefix(destinationPrefix) else { return nil }
        return ReportScope(rawValue: String(destination.dropFirst(destinationPrefix.count)))
    }

    /// Takes a tapped notification's destination if it names a Finance
    /// report; returns whether it did.
    @discardableResult
    public func open(destination: String) -> Bool {
        guard let scope = Self.scope(fromDestination: destination) else { return false }
        pending = scope
        return true
    }
}

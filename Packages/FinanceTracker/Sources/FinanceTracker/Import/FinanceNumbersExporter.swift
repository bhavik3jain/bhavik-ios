import SwiftUI

/// Turns a month into a filled copy of the Numbers template.
///
/// Only a Mac can: the template's tables grow by having Numbers add rows
/// itself (`scripts/finance/numbers_fill.js`), and only Numbers on the Mac can
/// be scripted — there's no API anywhere for writing a .numbers file. So the
/// app injects one on macOS, and on the phone this is nil and Export offers
/// the JSON for the Mac script instead.
public struct FinanceNumbersExporter: Sendable {
    /// Fills a copy of the template and returns where it is: a temporary
    /// file named "Finance 2026-09.numbers", for the caller to move to where
    /// the user wants it. Takes a minute or two.
    public let fill: @Sendable (FinanceMonthDocument) async throws -> URL

    public init(fill: @escaping @Sendable (FinanceMonthDocument) async throws -> URL) {
        self.fill = fill
    }
}

extension EnvironmentValues {
    @Entry public var financeNumbersExporter: FinanceNumbersExporter? = nil
}

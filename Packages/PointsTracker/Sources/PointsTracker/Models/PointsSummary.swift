import Core
import Foundation
import CoreData

/// Points and miles added up separately — they're different currencies, so a
/// single grand total would be meaningless.
public struct PointsTotal: Equatable, Sendable {
    public var points = 0
    public var miles = 0

    public init(points: Int = 0, miles: Int = 0) {
        self.points = points
        self.miles = miles
    }

    public init(_ accounts: [SharedPointsAccount]) {
        for account in accounts {
            add(account.balance, in: account.kind.unit)
        }
    }

    public mutating func add(_ amount: Int, in unit: PointsUnit) {
        switch unit {
        case .points: points += amount
        case .miles: miles += amount
        }
    }

    public var isZero: Bool { points == 0 && miles == 0 }

    /// "245,000 pts · 80,000 mi", leaving out whichever side is zero.
    public var summary: String {
        var parts: [String] = []
        if points != 0 { parts.append("\(points.formatted()) pts") }
        if miles != 0 { parts.append("\(miles.formatted()) mi") }
        return parts.isEmpty ? "0 pts" : parts.joined(separator: " · ")
    }
}

/// How the accounts list is sectioned.
public enum PointsGrouping: String, CaseIterable, Identifiable, Sendable {
    case owner
    case kind

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .owner: "Person"
        case .kind: "Type"
        }
    }
}

/// One section of the accounts list.
public struct PointsSection: Identifiable {
    public let id: String
    public let title: String
    public let accounts: [SharedPointsAccount]

    public var total: PointsTotal { PointsTotal(accounts) }
}

public enum PointsSummary {
    /// Title of the section for accounts with no one assigned.
    public static let unassigned = "Unassigned"

    /// Sections for the accounts list. By person: people alphabetically, then
    /// anything unassigned last. By type: credit cards, hotels, airlines. Empty
    /// sections are left out; inside each, the biggest balance comes first.
    public static func sections(_ accounts: [SharedPointsAccount], by grouping: PointsGrouping) -> [PointsSection] {
        let sorted = accounts.sorted {
            $0.balance != $1.balance
                ? $0.balance > $1.balance
                : $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        switch grouping {
        case .kind:
            return PointsKind.allCases.compactMap { kind in
                let matching = sorted.filter { $0.kind == kind }
                return matching.isEmpty ? nil : PointsSection(id: kind.rawValue, title: kind.groupName, accounts: matching)
            }
        case .owner:
            let owners = Set(sorted.compactMap(\.owner))
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            var sections = owners.map { owner in
                PointsSection(
                    id: owner.objectID.uriRepresentation().absoluteString,
                    title: owner.name.isEmpty ? "Unnamed" : owner.name,
                    accounts: sorted.filter { $0.owner == owner }
                )
            }
            let unowned = sorted.filter { $0.owner == nil }
            if !unowned.isEmpty {
                sections.append(PointsSection(id: "unassigned", title: unassigned, accounts: unowned))
            }
            return sections
        }
    }

    /// Accounts whose balance expires within `days`, soonest first.
    public static func expiringSoon(_ accounts: [SharedPointsAccount], within days: Int = 90, asOf now: Date = .now) -> [SharedPointsAccount] {
        accounts
            .filter { $0.expiresSoon(within: days, asOf: now) }
            .sorted { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
    }

    /// The home screen's one line for the Points row.
    public static func homeDetail(for accounts: [SharedPointsAccount], asOf now: Date = .now) -> String {
        guard !accounts.isEmpty else { return "No accounts yet" }
        let expiring = expiringSoon(accounts, asOf: now).count
        if expiring > 0 { return "\(counted(expiring, "account")) expiring soon" }
        return PointsTotal(accounts).summary
    }
}

/// Reads a points figure typed by hand. Text-backed rather than
/// `TextField(value:format:)`, which only writes its binding on commit — and
/// a number pad has no Return key, so tapping Add straight after typing
/// saved an opening balance of 0.
public enum PointsInput {
    /// Digits only, so "184,250" and "184 250" both read; nil when there are none.
    public static func parse(_ text: String) -> Int? {
        let digits = text.filter(\.isASCII).filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return Int(digits.prefix(15))
    }
}

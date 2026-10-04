import Foundation

/// What a report covers: one month, or one calendar year ("Year in review").
///
/// Codable as its `rawValue` string ("2026-09" or "2026"), so it can be the
/// value a Mac report window is opened with and a key in the local review
/// cache, without making `YearMonth` itself Codable.
public enum ReportScope: Hashable, Sendable, Codable, Identifiable, CustomStringConvertible {
    case month(YearMonth)
    case year(Int)

    public var id: String { rawValue }

    /// "2026-09" for a month, "2026" for a year.
    public var rawValue: String {
        switch self {
        case .month(let period): period.rawValue
        case .year(let year): String(year)
        }
    }

    /// Reads `rawValue` back; nil for anything else.
    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespaces)
        if let period = YearMonth(trimmed) {
            self = .month(period)
        } else if trimmed.count == 4, let year = Int(trimmed), year > 0 {
            self = .year(year)
        } else {
            return nil
        }
    }

    public var description: String { rawValue }

    /// "September 2026", or "2026 in review".
    public var title: String {
        switch self {
        case .month(let period): period.title
        case .year(let year): "\(year) in review"
        }
    }

    /// "September", or "2026" — "Ask about September", "<name>'s report".
    public var shortTitle: String {
        switch self {
        case .month(let period): period.monthName
        case .year(let year): String(year)
        }
    }

    public var isYear: Bool {
        if case .year = self { return true }
        return false
    }

    /// The month, for a month scope.
    public var month: YearMonth? {
        if case .month(let period) = self { return period }
        return nil
    }

    /// The calendar year either scope falls in.
    public var year: Int {
        switch self {
        case .month(let period): period.year
        case .year(let year): year
        }
    }

    /// The scope one step earlier: the month before, or the year before —
    /// the viewer's ‹ button.
    public var previous: ReportScope {
        switch self {
        case .month(let period): .month(period.previous)
        case .year(let year): .year(year - 1)
        }
    }

    /// The scope one step later — the viewer's › button.
    public var next: ReportScope {
        switch self {
        case .month(let period): .month(period.next)
        case .year(let year): .year(year + 1)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let scope = ReportScope(rawValue: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a report scope: \(text)")
        }
        self = scope
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

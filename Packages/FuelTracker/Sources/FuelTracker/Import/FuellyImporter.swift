import Core
import CoreData
import Foundation

public struct ImportSummary: Sendable, Equatable {
    public var fillUpsImported = 0
    public var servicesImported = 0
    public var duplicatesSkipped = 0
    public var rowsFailed = 0
    public var vehicleNames: [String] = []

    public var totalImported: Int { fillUpsImported + servicesImported }
}

public enum ImportError: LocalizedError {
    case unreadableFile
    case missingColumns([String])

    public var errorDescription: String? {
        switch self {
        case .unreadableFile:
            "That file could not be read. Export a CSV from Fuelly and try again."
        case .missingColumns(let columns):
            "This CSV is missing the \(columns.joined(separator: ", ")) column\(columns.count == 1 ? "" : "s")."
        }
    }
}

/// Imports a Fuelly CSV export.
///
/// The format ships a few quirks worth knowing: numbers are quoted and carry
/// thousands separators, money carries a leading `$`, octane arrives as
/// `Premium [Octane: 93]`, and `Service` rows share the sheet with fill-ups
/// while carrying no fuel at all. Fuelly's own MPG column is ignored — it is
/// blank or zero on partial fills — and recomputed from odometer and gallons.
public enum FuellyImporter {
    private static let requiredColumns = ["Type", "Date", "Vehicle", "Odometer"]

    @MainActor
    public static func importCSV(
        at url: URL,
        into context: NSManagedObjectContext
    ) throws -> ImportSummary {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        else {
            throw ImportError.unreadableFile
        }

        return try importCSV(text: text, into: context)
    }

    @MainActor
    public static func importCSV(text: String, into context: NSManagedObjectContext) throws -> ImportSummary {
        let rows = CSVParser.rows(from: text)
        guard let header = rows.first else { throw ImportError.unreadableFile }

        var columnIndex: [String: Int] = [:]
        for (index, name) in header.enumerated() {
            columnIndex[name.trimmingCharacters(in: .whitespaces)] = index
        }

        let missing = requiredColumns.filter { columnIndex[$0] == nil }
        guard missing.isEmpty else { throw ImportError.missingColumns(missing) }

        var summary = ImportSummary()
        var vehiclesByName = try existingVehiclesByName(in: context)
        var seen = try existingEntryKeys(in: context)

        for row in rows.dropFirst() {
            func value(_ column: String) -> String {
                guard let index = columnIndex[column], index < row.count else { return "" }
                return row[index].trimmingCharacters(in: .whitespaces)
            }

            let vehicleName = value("Vehicle")
            guard !vehicleName.isEmpty,
                  let date = parseDate(value("Date"), time: value("Time")),
                  let odometer = parseInt(value("Odometer"))
            else {
                summary.rowsFailed += 1
                continue
            }

            let isService = value("Type").caseInsensitiveCompare("Service") == .orderedSame
            let key = EntryKey(vehicle: vehicleName, odometer: odometer, date: date, isService: isService)
            guard !seen.contains(key) else {
                summary.duplicatesSkipped += 1
                continue
            }

            let vehicle: SharedVehicle
            if let existing = vehiclesByName[vehicleName] {
                vehicle = existing
            } else {
                let created = SharedVehicle(context: context, name: vehicleName)
                vehiclesByName[vehicleName] = created
                vehicle = created
                summary.vehicleNames.append(vehicleName)
            }

            let entry = SharedFuelEntry(
                context: context,
                kind: isService ? .service : .fillUp,
                date: date,
                odometer: odometer,
                gallons: parseDouble(value("Gallons")) ?? 0,
                pricePerGallon: parseDouble(value("Cost/Gallon")) ?? 0,
                totalCost: parseDouble(value("Total Cost")) ?? 0,
                isFullTank: value("Filled Up").caseInsensitiveCompare("Partial") != .orderedSame,
                octane: parseOctane(value("Octane")),
                station: value("Gas Brand").isEmpty ? value("Location") : value("Gas Brand"),
                notes: value("Notes"),
                services: value("Services")
            )
            entry.vehicle = vehicle
            seen.insert(key)

            if isService {
                summary.servicesImported += 1
            } else {
                summary.fillUpsImported += 1
            }
        }

        try context.saveIfNeeded()
        return summary
    }

    // MARK: - Duplicate detection

    private struct EntryKey: Hashable {
        let vehicle: String
        let odometer: Int
        let date: Date
        let isService: Bool
    }

    @MainActor
    private static func existingVehiclesByName(in context: NSManagedObjectContext) throws -> [String: SharedVehicle] {
        let vehicles = try context.fetch(SharedVehicle.fetchRequest())
        return Dictionary(vehicles.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @MainActor
    private static func existingEntryKeys(in context: NSManagedObjectContext) throws -> Set<EntryKey> {
        let entries = try context.fetch(SharedFuelEntry.fetchRequest())
        return Set(entries.map {
            EntryKey(
                vehicle: $0.vehicle?.name ?? "",
                odometer: $0.odometer,
                date: $0.date,
                isService: $0.kind == .service
            )
        })
    }

    // MARK: - Field parsing

    private static let dateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dateTimeParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd h:mm a"
        return formatter
    }()

    static func parseDate(_ date: String, time: String) -> Date? {
        guard !date.isEmpty else { return nil }
        if !time.isEmpty, let combined = dateTimeParser.date(from: "\(date) \(time)") {
            return combined
        }
        return dateParser.date(from: date)
    }

    /// Strips thousands separators before converting, so `"37,057"` reads as 37057.
    static func parseInt(_ text: String) -> Int? {
        let digits = text.filter(\.isNumber)
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    /// Strips currency symbols and thousands separators, so `"$6,405.36"` reads as 6405.36.
    static func parseDouble(_ text: String) -> Double? {
        let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard !cleaned.isEmpty else { return nil }
        return Double(cleaned)
    }

    /// Reduces `"Premium [Octane: 93]"` to `"93"`, leaving plain values untouched.
    static func parseOctane(_ text: String) -> String {
        guard let range = text.range(of: "Octane:") else { return text }
        let remainder = text[range.upperBound...]
        let number = remainder.prefix { $0.isNumber || $0 == " " }
        let trimmed = number.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? text : trimmed
    }
}

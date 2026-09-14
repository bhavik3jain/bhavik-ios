import Core
import Foundation
import SwiftData
import Testing
@testable import FuelTracker

@MainActor
private func makeContext() throws -> ModelContext {
    let schema = Schema(FuelTrackerModule.models)
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])
    return ModelContext(container)
}

private func fixtureText() throws -> String {
    let url = try #require(Bundle.module.url(forResource: "FuellyExport", withExtension: "csv"))
    return try String(contentsOf: url, encoding: .utf8)
}

// MARK: - Field parsing

@Test func parsesNumbersCarryingThousandsSeparatorsAndCurrency() {
    #expect(FuellyImporter.parseInt("37,057") == 37057)
    #expect(FuellyImporter.parseDouble("$6,405.36") == 6405.36)
    #expect(FuellyImporter.parseDouble("$5.739") == 5.739)
    #expect(FuellyImporter.parseInt("") == nil)
}

@Test func extractsOctaneRating() {
    #expect(FuellyImporter.parseOctane("Premium [Octane: 93]") == "93")
    #expect(FuellyImporter.parseOctane("") == "")
}

@Test func csvParserKeepsCommasInsideQuotedFields() {
    let rows = CSVParser.rows(from: "\"a\",\"37,057\",\"c\"\n\"d\",\"$6,405.36\",\"f\"")
    #expect(rows.count == 2)
    #expect(rows[0] == ["a", "37,057", "c"])
    #expect(rows[1][1] == "$6,405.36")
}

// MARK: - Importing the real export

@MainActor
@Test func importsEveryRowOfTheFuellyExport() throws {
    let context = try makeContext()
    let summary = try FuellyImporter.importCSV(text: fixtureText(), into: context)

    #expect(summary.rowsFailed == 0, "Every row in the export should parse")
    #expect(summary.fillUpsImported == 83)
    #expect(summary.servicesImported == 4)
    #expect(Set(summary.vehicleNames) == ["My Q5", "My X3"])
}

@MainActor
@Test func separatesVehiclesAndKeepsServicesOutOfFillUps() throws {
    let context = try makeContext()
    _ = try FuellyImporter.importCSV(text: fixtureText(), into: context)

    let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
    #expect(vehicles.count == 2)

    let q5 = try #require(vehicles.first { $0.name == "My Q5" })
    let x3 = try #require(vehicles.first { $0.name == "My X3" })

    #expect(q5.orderedServices.count == 4)
    #expect(x3.orderedServices.isEmpty)
    #expect(q5.orderedFillUps.allSatisfy { $0.kind == .fillUp })
    #expect(x3.orderedFillUps.count == 7)
}

@MainActor
@Test func reimportingTheSameFileAddsNothing() throws {
    let context = try makeContext()
    let first = try FuellyImporter.importCSV(text: fixtureText(), into: context)
    let second = try FuellyImporter.importCSV(text: fixtureText(), into: context)

    #expect(second.totalImported == 0)
    #expect(second.duplicatesSkipped == first.totalImported)
    #expect(try context.fetchCount(FetchDescriptor<FuelEntry>()) == first.totalImported)
}

@MainActor
@Test func preservesDetailFromARepresentativeRow() throws {
    let context = try makeContext()
    _ = try FuellyImporter.importCSV(text: fixtureText(), into: context)

    let entries = try context.fetch(FetchDescriptor<FuelEntry>())
    let entry = try #require(entries.first { $0.odometer == 37_057 })

    #expect(entry.gallons == 16.095)
    #expect(entry.pricePerGallon == 5.739)
    #expect(entry.totalCost == 92.37)
    #expect(entry.octane == "93")
    #expect(entry.isFullTank)

    let service = try #require(entries.first { $0.odometer == 65_250 })
    #expect(service.kind == .service)
    #expect(service.totalCost == 6405.36)
    #expect(service.services.contains("Brakes"))
    #expect(service.gallons == 0)
}

@MainActor
@Test func marksPartialFillUps() throws {
    let context = try makeContext()
    _ = try FuellyImporter.importCSV(text: fixtureText(), into: context)

    let entries = try context.fetch(FetchDescriptor<FuelEntry>())
    let partials = entries.filter { $0.kind == .fillUp && !$0.isFullTank }
    #expect(partials.count == 2)
    #expect(partials.allSatisfy { $0.gallons > 0 })
    #expect(Set(partials.map(\.odometer)) == [38_521, 42_691])
}

// MARK: - Fuel economy

@Test func mpgIsMeasuredBetweenFullTanks() {
    let entries = [
        FuelEntry(date: .now, odometer: 1000, gallons: 10, isFullTank: true),
        FuelEntry(date: .now, odometer: 1300, gallons: 10, isFullTank: true)
    ]
    let points = FuelStatistics.mpgPoints(for: entries)

    #expect(points.count == 1, "The first fill only establishes a baseline")
    #expect(points[0].miles == 300)
    #expect(points[0].mpg == 30)
}

@Test func partialFillRollsIntoTheNextFullTank() {
    let entries = [
        FuelEntry(date: .now, odometer: 1000, gallons: 10, isFullTank: true),
        FuelEntry(date: .now, odometer: 1150, gallons: 4, isFullTank: false),
        FuelEntry(date: .now, odometer: 1300, gallons: 6, isFullTank: true)
    ]
    let points = FuelStatistics.mpgPoints(for: entries)

    #expect(points.count == 1, "A partial fill cannot close a tank on its own")
    #expect(points[0].miles == 300)
    #expect(points[0].gallons == 10, "Both the partial and the full fill are burned over that distance")
    #expect(points[0].mpg == 30)
}

@Test func serviceRecordsAreIgnoredByFuelEconomy() {
    let entries = [
        FuelEntry(date: .now, odometer: 1000, gallons: 10, isFullTank: true),
        FuelEntry(kind: .service, date: .now, odometer: 1100, totalCost: 500),
        FuelEntry(date: .now, odometer: 1300, gallons: 10, isFullTank: true)
    ]
    let points = FuelStatistics.mpgPoints(for: entries)

    #expect(points.count == 1)
    #expect(points[0].mpg == 30)
}

@MainActor
@Test func computedEconomyForRealDataLandsInARealisticRange() throws {
    let context = try makeContext()
    _ = try FuellyImporter.importCSV(text: fixtureText(), into: context)

    let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
    let q5 = try #require(vehicles.first { $0.name == "My Q5" })
    let x3 = try #require(vehicles.first { $0.name == "My X3" })

    let q5MPG = try #require(FuelStatistics.averageMPG(for: q5.orderedFillUps))
    let x3MPG = try #require(FuelStatistics.averageMPG(for: x3.orderedFillUps))

    // Both are gas SUVs; anything outside this band means the maths is wrong.
    #expect(q5MPG > 20 && q5MPG < 30, "Q5 averaged \(q5MPG) mpg")
    #expect(x3MPG > 20 && x3MPG < 40, "X3 averaged \(x3MPG) mpg")

    let pricePerGallon = try #require(FuelStatistics.averagePricePerGallon(for: q5.orderedFillUps))
    #expect(pricePerGallon > 3 && pricePerGallon < 6)
}

@MainActor
@Test func outOfOrderDatesDoNotProduceNegativeDistances() throws {
    let context = try makeContext()
    _ = try FuellyImporter.importCSV(text: fixtureText(), into: context)

    let vehicles = try context.fetch(FetchDescriptor<Vehicle>())
    let q5 = try #require(vehicles.first { $0.name == "My Q5" })

    // The export carries a row dated 2025-12-31 that sits between December 2024
    // and February 2025 by odometer, so ordering must follow the odometer.
    let points = FuelStatistics.mpgPoints(for: q5.orderedFillUps)
    #expect(points.allSatisfy { $0.miles > 0 })
    #expect(points.allSatisfy { $0.mpg > 5 && $0.mpg < 60 })
}

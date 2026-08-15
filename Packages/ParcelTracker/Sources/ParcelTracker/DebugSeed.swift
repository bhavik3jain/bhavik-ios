#if DEBUG
import Foundation
import SwiftData

/// Adds a couple of parcels so the module has something in it on a fresh
/// simulator. Debug builds only, and only when launched with `-ParcelSeed`.
public enum ParcelDebugSeed {
    public static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "ParcelSeed")
    }

    @MainActor
    public static func run(context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Parcel>())) ?? []
        let numbers = Set(existing.map(\.trackingNumber))

        let samples = [
            ("1ZR0Y0651268323735", "Headphones"),
            ("111111111111", "FedEx sample")
        ]

        for (number, name) in samples where !numbers.contains(number) {
            let parcel = Parcel(
                trackingNumber: number,
                name: name,
                carrier: CarrierDetector.detect(number).carrier
            )
            parcel.status = .pending
            context.insert(parcel)
        }
        try? context.save()
    }
}
#endif

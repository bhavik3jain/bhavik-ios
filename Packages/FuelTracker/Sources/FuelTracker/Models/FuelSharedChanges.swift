import Core
import CoreData
import Foundation

public extension FuelTrackerModule {
    /// Fuel's wording for Core's shared-change notifications — see
    /// `SharedChangeNotifier`, which `BhavikApp` hands this to. The root is
    /// always the vehicle.
    static func describeSharedChange(_ object: NSManagedObject, _ change: SharedObjectChange) -> SharedChangeDescription? {
        switch object {
        case let vehicle as SharedVehicle:
            let action = change.kind == .inserted
                ? "shared \(vehicleName(vehicle))"
                : change.updatedProperties.contains("name") ? "renamed a vehicle to \(vehicleName(vehicle))" : "updated \(vehicleName(vehicle))"
            return SharedChangeDescription(rootID: vehicle.objectID, rootTitle: vehicleName(vehicle), action: action)

        case let entry as SharedFuelEntry:
            guard let vehicle = entry.vehicle else { return nil }
            let what: String
            switch entry.kind {
            case .fillUp:
                let station = entry.station.trimmingCharacters(in: .whitespacesAndNewlines)
                what = station.isEmpty ? "a fill-up" : "a fill-up at \(station)"
            case .service:
                let services = entry.services.trimmingCharacters(in: .whitespacesAndNewlines)
                what = services.isEmpty ? "a service" : "a service (\(services))"
            }
            let action = change.kind == .inserted ? "logged \(what)" : "edited \(what)"
            return SharedChangeDescription(rootID: vehicle.objectID, rootTitle: vehicleName(vehicle), action: action)

        default:
            return nil
        }
    }

    private static func vehicleName(_ vehicle: SharedVehicle) -> String {
        let name = vehicle.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "a vehicle" : name
    }
}

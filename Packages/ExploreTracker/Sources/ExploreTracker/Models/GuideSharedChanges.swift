import Core
import CoreData
import Foundation

public extension ExploreTrackerModule {
    /// Explore's wording for Core's shared-change notifications — see
    /// `SharedChangeNotifier`, which `BhavikApp` hands this to. The root is
    /// always the guide. `GuidePin` is never described: pins are per device
    /// and never shared.
    static func describeSharedChange(_ object: NSManagedObject, _ change: SharedObjectChange) -> SharedChangeDescription? {
        switch object {
        case let guide as SharedGuide:
            let action: String
            if change.kind == .inserted {
                action = "shared \(guideName(guide))"
            } else if change.updatedProperties.isSubset(of: ["pinnedAt", "identifier"]) {
                // Housekeeping, not an edit: the retired pin being cleared,
                // or an old guide being given its identifier.
                return nil
            } else if change.updatedProperties.contains("name") {
                action = "renamed a guide to \(guideName(guide))"
            } else {
                action = "updated \(guideName(guide))"
            }
            return SharedChangeDescription(rootID: guide.objectID, rootTitle: guideName(guide), action: action)

        case let place as SharedGuidePlace:
            guard let guide = place.guide else { return nil }
            let trimmed = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? "a place" : trimmed
            let action: String
            if change.kind == .inserted {
                action = "added \(name)"
            } else if change.updatedProperties.contains("isTried"), place.isTried {
                action = "tried \(name)"
            } else if change.updatedProperties.contains("rating"), place.rating > 0 {
                action = "rated \(name) \(counted(place.rating, "star"))"
            } else {
                action = "changed \(name)"
            }
            return SharedChangeDescription(rootID: guide.objectID, rootTitle: guideName(guide), action: action)

        default:
            return nil
        }
    }

    private static func guideName(_ guide: SharedGuide) -> String {
        let name = guide.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "a guide" : name
    }
}

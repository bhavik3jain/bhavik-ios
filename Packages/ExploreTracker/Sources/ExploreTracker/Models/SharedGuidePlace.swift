import CoreData
import Foundation

/// One place in a guide — backed by Core Data / `NSPersistentCloudKitContainer`
/// rather than SwiftData, so a guide's whole place list can be shared for live
/// co-editing. Its CloudKit-facing record type is `SharedGuidePlace`,
/// matching this Swift class name: see `GuideModel.swift` for the
/// entity/class split, and for why every initializer here goes through
/// `NSEntityDescription.entity(forEntityName:in:)` instead of this class's
/// own inherited `init(context:)`.
@objc(SharedGuidePlace)
public final class SharedGuidePlace: NSManagedObject, Identifiable {
    @NSManaged public var name: String
    /// A few words of why it's on the list, "go before 11:30".
    @NSManaged public var note: String
    @NSManaged public var address: String
    @NSManaged public var categoryRaw: String
    /// Stored as `NSNumber?`, not `Double?` directly: `@NSManaged` implies
    /// `@objc dynamic`, and a bare `Double?` can't be represented in
    /// Objective-C (unlike a class type such as `NSNumber`, or a non-optional
    /// scalar). `latitude`/`longitude` below are the `Double?` this class
    /// actually exposes. Both `nil` for a place added by hand; such a place is
    /// listed but never drawn on a map or counted toward the guide's region.
    @NSManaged var latitudeNumber: NSNumber?
    @NSManaged var longitudeNumber: NSNumber?
    @NSManaged public var isTried: Bool
    /// 1 to 5 once tried; 0 means no rating given.
    @NSManaged public var rating: Int
    @NSManaged public var triedAt: Date?
    @NSManaged public var addedAt: Date

    @NSManaged public var guide: SharedGuide?

    public convenience init(
        context: NSManagedObjectContext,
        name: String,
        category: PlaceCategory,
        note: String = "",
        address: String = "",
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        let entity = NSEntityDescription.entity(forEntityName: GuideModel.EntityName.place, in: context)!
        self.init(entity: entity, insertInto: context)
        self.name = name
        self.categoryRaw = category.rawValue
        self.note = note
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.addedAt = .now
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedGuidePlace> {
        let request = NSFetchRequest<SharedGuidePlace>(entityName: GuideModel.EntityName.place)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

public extension SharedGuidePlace {
    var id: NSManagedObjectID { objectID }

    var category: PlaceCategory {
        get { PlaceCategory(rawValue: categoryRaw) ?? .places }
        set { categoryRaw = newValue.rawValue }
    }

    var latitude: Double? {
        get { latitudeNumber?.doubleValue }
        set { latitudeNumber = newValue.map(NSNumber.init) }
    }

    var longitude: Double? {
        get { longitudeNumber?.doubleValue }
        set { longitudeNumber = newValue.map(NSNumber.init) }
    }

    /// Every map/location read in the module funnels through this — the one
    /// place `nil` either coordinate becomes "no pin".
    var point: GeoPoint? {
        guard let latitude, let longitude else { return nil }
        return GeoPoint(latitude: latitude, longitude: longitude)
    }

    /// Flips a place between To try and Tried. Un-trying drops the rating too:
    /// a rating left behind on a To try place would resurface, unasked for,
    /// the next time it was ticked off.
    func setTried(_ tried: Bool, asOf now: Date = .now) {
        isTried = tried
        if tried {
            if triedAt == nil { triedAt = now }
        } else {
            triedAt = nil
            rating = 0
        }
    }
}

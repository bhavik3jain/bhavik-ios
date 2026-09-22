import CoreData

public extension NSManagedObjectContext {
    /// Unlike SwiftData, Core Data never autosaves — every mutation site across
    /// the three modules on `CloudSharedStore` needs an explicit save, and a
    /// forgotten one is data silently vanishing on the next launch. One helper,
    /// used everywhere, so that mistake has a single place to get right.
    func saveIfNeeded() throws {
        if hasChanges { try save() }
    }
}

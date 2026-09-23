import Core
import CoreData
import CryptoKit
import Foundation

/// One person's pin on one guide — a personal preference, synced only between
/// that person's own devices.
///
/// Pins used to be `SharedGuide.pinnedAt`, a field on the guide record, which
/// broke as soon as a guide was shared: pinning reordered the list for
/// everyone on the share, and a read-only participant's pin saved locally but
/// could never be written to CloudKit, so it silently never synced. So a pin
/// is its own record, and two things keep it out of any share:
///
/// - **No relationship to `SharedGuide`.** `NSPersistentCloudKitContainer`
///   shares a root object's whole relationship graph, so a relationship would
///   drag everyone's pins into the share with the guide. It points at
///   `SharedGuide.identifier` by value instead.
/// - **Always assigned to the private store** (`GuidePins.setPinned`). Both
///   stores claim every entity (see `CloudSharedStore.makeContainer`), so this
///   is enforced at insert rather than by the model.
///
/// Two of one person's devices can each pin the same guide before they sync,
/// leaving two rows for one guide. Nothing de-duplicates them on write (there
/// is no unique constraint under CloudKit); every reader tolerates them
/// instead — see `GuidePins`.
@objc(GuidePin)
public final class GuidePin: NSManagedObject {
    /// The `SharedGuide.identifier` this pin is for.
    @NSManaged public var guideIdentifier: String
    @NSManaged public var pinnedAt: Date

    convenience init(context: NSManagedObjectContext, guideIdentifier: String, pinnedAt: Date) {
        let entity = NSEntityDescription.entity(forEntityName: GuideModel.EntityName.pin, in: context)!
        self.init(entity: entity, insertInto: context)
        self.guideIdentifier = guideIdentifier
        self.pinnedAt = pinnedAt
    }

    @nonobjc public static func fetchRequest(predicate: NSPredicate? = nil) -> NSFetchRequest<GuidePin> {
        let request = NSFetchRequest<GuidePin>(entityName: GuideModel.EntityName.pin)
        request.predicate = predicate
        return request
    }
}

/// `SharedGuide.identifier` for guides that predate the field.
public enum GuideIdentity {
    /// Built only from what every copy of the guide already agrees on, so two
    /// devices backfilling the same synced guide independently write the same
    /// value, and neither overwrites the other with something different.
    ///
    /// `createdAt` is cut to whole seconds because the copies don't agree on
    /// anything finer: the device that made the guide holds its full-precision
    /// date, while every other device holds the one that came back through
    /// CloudKit, which keeps milliseconds only. A SHA-256 rather than
    /// `hashValue`, which is seeded afresh in every process.
    public static func derived(name: String, areaLabel: String, createdAt: Date) -> String {
        let seconds = Int64(createdAt.timeIntervalSinceReferenceDate.rounded(.down))
        let text = [name, areaLabel, String(seconds)].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(text.utf8))
        return "derived-" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func derived(for guide: SharedGuide) -> String {
        derived(name: guide.name, areaLabel: guide.areaLabel, createdAt: guide.createdAt)
    }

    /// Gives every guide in `store` that has no identifier its derived one.
    /// Idempotent: a guide that has one is never touched.
    ///
    /// Private store only: a guide in the shared store belongs to someone
    /// else, whose own device backfills it, and a read-only participant's
    /// write to it would never reach CloudKit. Until that lands,
    /// `GuidePins.key(for:)` derives the same value on the fly.
    @MainActor
    public static func backfill(in context: NSManagedObjectContext, store: NSPersistentStore) {
        let request = SharedGuide.fetchRequest(predicate: NSPredicate(format: "identifier == %@", ""))
        request.affectedStores = [store]
        guard let guides = try? context.fetch(request), !guides.isEmpty else { return }
        for guide in guides {
            guide.identifier = derived(for: guide)
        }
        try? context.saveIfNeeded()
    }
}

/// Reading and writing pins, so the views stay declarative and this is
/// testable.
///
/// A guide is pinned if *any* `GuidePin` row names it, and ordered by the
/// *earliest* of them — duplicates from two devices pinning before they synced
/// are expected, and taking the earliest means the order doesn't jump when the
/// later duplicate arrives. Unpinning deletes every row for the guide, or the
/// surviving duplicate would re-pin it.
@MainActor
public struct GuidePins {
    public let context: NSManagedObjectContext
    /// Where new pins go. `nil` only without a container (a preview); pinning
    /// then does nothing rather than risk landing a pin in the shared store.
    public let privateStore: NSPersistentStore?

    public init(context: NSManagedObjectContext, privateStore: NSPersistentStore?) {
        self.context = context
        self.privateStore = privateStore
    }

    /// How the views build one: the module's container is already in the
    /// environment (`\.explorePersistentContainer`) for sharing.
    public init(context: NSManagedObjectContext, container: NSPersistentCloudKitContainer?) {
        self.init(context: context, privateStore: container?.privatePersistentStore)
    }

    /// The value a guide's pins are keyed on. A guide the backfill hasn't
    /// reached yet (one in the shared store — see `GuideIdentity.backfill`)
    /// gets the same derived value the backfill would give it, so its pin
    /// survives the backfill landing.
    public static func key(for guide: SharedGuide) -> String {
        guide.identifier.isEmpty ? GuideIdentity.derived(for: guide) : guide.identifier
    }

    /// Guide key → when it was first pinned, from whatever pin rows the caller
    /// already has (a view's `@FetchRequest`).
    public static func earliestPinDates(_ pins: some Sequence<GuidePin>) -> [String: Date] {
        var dates: [String: Date] = [:]
        for pin in pins {
            dates[pin.guideIdentifier] = min(dates[pin.guideIdentifier] ?? pin.pinnedAt, pin.pinnedAt)
        }
        return dates
    }

    /// `earliestPinDates` over every pin in `context`.
    public static func pinDates(in context: NSManagedObjectContext) -> [String: Date] {
        earliestPinDates((try? context.fetch(GuidePin.fetchRequest())) ?? [])
    }

    public func pinnedAt(for guide: SharedGuide) -> Date? {
        rows(for: Self.key(for: guide)).map(\.pinnedAt).min()
    }

    public func isPinned(_ guide: SharedGuide) -> Bool {
        pinnedAt(for: guide) != nil
    }

    /// Pinning an already-pinned guide keeps its original date, so it doesn't
    /// jump behind guides pinned after it. Doesn't save — the caller does, as
    /// with every other edit.
    ///
    /// Not gated on share permission: it writes only this person's own
    /// private-store record, never the guide.
    public func setPinned(_ pinned: Bool, _ guide: SharedGuide, asOf now: Date = .now) {
        let key = Self.key(for: guide)
        let existing = rows(for: key)
        if pinned {
            guard existing.isEmpty else { return }
            insertPin(key, pinnedAt: now)
        } else {
            existing.forEach(context.delete)
        }
    }

    /// Whether any guide still carries a pin in the retired
    /// `SharedGuide.pinnedAt` — i.e. whether `migrateRetiredPinnedAt` has work
    /// to do, and so has to wait for iCloud first.
    public func hasRetiredPinsToMigrate() -> Bool {
        guard let request = retiredPinsRequest() else { return false }
        return ((try? context.count(for: request)) ?? 0) > 0
    }

    /// Moves every pin still held in `SharedGuide.pinnedAt` into a `GuidePin`,
    /// then clears the field. Backfills identifiers first, since a pin needs
    /// one to point at.
    ///
    /// Clearing is what makes this one-shot across devices, not just per
    /// device: if the field were left set, a device that ran this late — after
    /// the guide had been unpinned elsewhere and its `GuidePin` deleted — would
    /// find a date and no pin, and quietly pin the guide again. Idempotent by
    /// content too: an existing pin for the guide is kept, never duplicated.
    ///
    /// Private store only — nothing was shared before this shipped, so every
    /// `pinnedAt` there is the owner's own; one on a guide shared *to* this
    /// person was someone else's pin.
    public func migrateRetiredPinnedAt() {
        guard let privateStore else { return }
        GuideIdentity.backfill(in: context, store: privateStore)
        guard let request = retiredPinsRequest(),
              let guides = try? context.fetch(request), !guides.isEmpty else { return }
        for guide in guides where !guide.identifier.isEmpty {
            if let pinnedAt = guide.pinnedAt, rows(for: guide.identifier).isEmpty {
                insertPin(guide.identifier, pinnedAt: pinnedAt)
            }
            guide.pinnedAt = nil
        }
        try? context.saveIfNeeded()
    }

    // MARK: - Private

    private func rows(for key: String) -> [GuidePin] {
        (try? context.fetch(GuidePin.fetchRequest(predicate: NSPredicate(format: "guideIdentifier == %@", key)))) ?? []
    }

    private func insertPin(_ key: String, pinnedAt: Date) {
        guard let privateStore else { return }
        let pin = GuidePin(context: context, guideIdentifier: key, pinnedAt: pinnedAt)
        context.assign(pin, to: privateStore)
    }

    private func retiredPinsRequest() -> NSFetchRequest<SharedGuide>? {
        guard let privateStore else { return nil }
        let request = SharedGuide.fetchRequest(predicate: NSPredicate(format: "pinnedAt != nil"))
        request.affectedStores = [privateStore]
        return request
    }
}

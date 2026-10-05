import Foundation

/// When `SharedChangeNotifier` may read a store's history: not while a
/// CloudKit import is still running in it.
///
/// Reading who changed what — `fetchShares(matching:)`, `records(for:)`,
/// `recordIDs(for:)` — waits on the container's request executor, which the
/// import holds until it's done. Read mid-import, every lookup sat behind it:
/// after a sync reset the Mac logged "Wait timed out during call to
/// recordForManagedObjectID" every ten minutes for three and a half hours.
enum SharedChangeImportWatch {
    /// An import running longer than this is treated as stuck and history is
    /// read anyway, rather than held back for good (seconds).
    static let maximumDeferral: TimeInterval = 5 * 60

    /// When the import under way in a store started, after an event in it —
    /// given `current`, the one under way before. A store's mirroring
    /// delegate runs one request at a time, so any event that started after
    /// the import is proof it's over, whether or not its end was posted.
    static func importStart(current: Date?, eventIsImport: Bool, eventStarted: Date, eventEnded: Bool) -> Date? {
        guard let current else { return eventIsImport && !eventEnded ? eventStarted : nil }
        // An older event's late notice says nothing about the import now.
        if eventStarted < current { return current }
        // This import's start again, or a newer one's.
        if eventIsImport && !eventEnded { return eventStarted }
        // Its end, or anything after it.
        return nil
    }

    /// Whether to hold history back for an import that started at
    /// `importStartedAt`.
    static func defers(importStartedAt: Date?, asOf now: Date = .now) -> Bool {
        guard let importStartedAt else { return false }
        return now.timeIntervalSince(importStartedAt) < maximumDeferral
    }
}

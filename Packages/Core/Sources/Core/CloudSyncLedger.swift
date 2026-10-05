import CoreData
import Foundation

/// What `NSPersistentCloudKitContainer` did, copied out of its
/// `NSPersistentCloudKitContainer.Event` into a plain value.
///
/// A copy rather than the event itself because Core Data offers no way to
/// construct an `Event` outside the framework, which would leave
/// `CloudSyncLedger` — the logic that decides "has this refresh brought
/// anything in yet?" — untestable.
public struct CloudSyncEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case setup
        case `import`
        case export
    }

    /// The same for an event's start and end notifications, which is how the
    /// ledger pairs them up.
    public var id: UUID
    public var storeIdentifier: String
    public var kind: Kind
    public var startDate: Date
    /// `nil` while the event is still under way.
    public var endDate: Date?
    public var succeeded: Bool
    public var errorDescription: String?

    public init(
        id: UUID = UUID(),
        storeIdentifier: String,
        kind: Kind,
        startDate: Date,
        endDate: Date? = nil,
        succeeded: Bool = false,
        errorDescription: String? = nil
    ) {
        self.id = id
        self.storeIdentifier = storeIdentifier
        self.kind = kind
        self.startDate = startDate
        self.endDate = endDate
        self.succeeded = succeeded
        self.errorDescription = errorDescription
    }

    init(_ event: NSPersistentCloudKitContainer.Event) {
        let kind: Kind = switch event.type {
        case .setup: .setup
        case .import: .import
        case .export: .export
        @unknown default: .setup
        }
        self.init(
            id: event.identifier,
            storeIdentifier: event.storeIdentifier,
            kind: kind,
            startDate: event.startDate,
            endDate: event.endDate,
            succeeded: event.succeeded,
            errorDescription: event.error?.localizedDescription
        )
    }
}

/// Per-store bookkeeping of CloudKit mirroring, fed every
/// `NSPersistentCloudKitContainer.eventChangedNotification` in order.
///
/// The notification fires twice per event — once when it starts (no end date)
/// and once when it finishes — so "is anything syncing right now" is the set
/// of events seen starting but not yet finishing.
public struct CloudSyncLedger: Sendable, Equatable {
    public struct Store: Sendable, Equatable {
        /// End of the latest *successful* import: everything another device
        /// had exported by then is in this store.
        public var lastImportAt: Date?
        /// End of the latest successful export: everything saved here by then
        /// is in iCloud.
        public var lastExportAt: Date?
        /// End of the latest import to finish, whether or not it succeeded —
        /// what a refresh waits on.
        public var lastImportEndedAt: Date?
        /// End of the latest export to finish, whether or not it succeeded —
        /// what Share waits on after `share()` didn't come back with one.
        public var lastExportEndedAt: Date?
        /// The latest finished event's error; cleared by the next success.
        public var lastError: String?
    }

    public private(set) var stores: [String: Store] = [:]
    private var inFlight: [UUID: CloudSyncEvent] = [:]

    public init() {}

    public mutating func record(_ event: CloudSyncEvent) {
        var store = stores[event.storeIdentifier] ?? Store()
        defer { stores[event.storeIdentifier] = store }

        // A store's mirroring delegate runs one request at a time, so an
        // event in this store that started before this one is over, whether
        // or not its end was ever posted. Without this, one end that never
        // came (after a reset the Mac's setup logged "Waiting on save zone"
        // and then nothing) left the store "syncing" until relaunch: Settings
        // said so, and every Share waited out its whole sync limit first.
        inFlight = inFlight.filter { _, earlier in
            earlier.storeIdentifier != event.storeIdentifier || earlier.id == event.id
                || earlier.startDate >= event.startDate
        }

        guard let end = event.endDate else {
            inFlight[event.id] = event
            return
        }
        inFlight[event.id] = nil

        if event.kind == .import {
            store.lastImportEndedAt = Self.later(store.lastImportEndedAt, end)
        }
        if event.kind == .export {
            store.lastExportEndedAt = Self.later(store.lastExportEndedAt, end)
        }
        guard event.succeeded else {
            store.lastError = event.errorDescription ?? "iCloud sync failed."
            return
        }
        store.lastError = nil
        switch event.kind {
        case .import: store.lastImportAt = Self.later(store.lastImportAt, end)
        case .export: store.lastExportAt = Self.later(store.lastExportAt, end)
        case .setup: break
        }
    }

    /// Whether any import, export or setup is under way.
    public var isSyncing: Bool { !inFlight.isEmpty }

    /// Whether an import, export or setup is under way in one of `scope`'s
    /// stores — one container's, for Share: its `share()` waits on the same
    /// request executor, and on the Mac a share queued behind a sync that
    /// never finished timed out ("Share-Export") every time.
    public func isSyncing(in scope: Set<String>) -> Bool {
        inFlight.values.contains { scope.contains($0.storeIdentifier) }
    }

    /// When the oldest unfinished event in `scope` started. One that started
    /// minutes ago and never ended is a stuck sync, not a slow one: after a
    /// reset the Mac's setup logged "Waiting on save zone" and then nothing
    /// for eleven hours.
    public func oldestInFlightStart(in scope: Set<String>) -> Date? {
        inFlight.values.filter { scope.contains($0.storeIdentifier) }.map(\.startDate).min()
    }

    /// Whether an import in `scope` finished, well or not, after `date`.
    public func importEnded(after date: Date, in scope: Set<String>) -> Bool {
        scope.contains { identifier in
            stores[identifier]?.lastImportEndedAt.map { $0 > date } ?? false
        }
    }

    /// Whether an export in `scope` finished, well or not, after `date`.
    public func exportEnded(after date: Date, in scope: Set<String>) -> Bool {
        scope.contains { identifier in
            stores[identifier]?.lastExportEndedAt.map { $0 > date } ?? false
        }
    }

    /// The latest moment this device and iCloud were known to agree: the end
    /// of the latest successful import or export in any store.
    public var lastSyncedAt: Date? {
        stores.values
            .flatMap { [$0.lastImportAt, $0.lastExportAt] }
            .compactMap { $0 }
            .max()
    }

    /// Every store the ledger has heard from — which includes stores it was
    /// never told about, like the one SwiftData builds privately.
    public var knownStores: Set<String> { Set(stores.keys) }

    public enum Progress: Sendable, Equatable {
        /// At least one store in scope hasn't finished an import since the
        /// request.
        case waiting
        /// Every store in scope finished a successful import after the request.
        case finished
        /// Every store in scope finished an import after the request, and at
        /// least one failed — with the first failure's message.
        case failed(String)
    }

    /// How far a refresh requested at `requestedAt` has got across `scope`.
    ///
    /// An import that was already running when the request came in counts
    /// once it ends: it asks CloudKit for changes partway through, after
    /// anything a partner saved before the tap was already on the server.
    public func progress(since requestedAt: Date, in scope: Set<String>) -> Progress {
        guard !scope.isEmpty else { return .waiting }
        var failure: String?
        for identifier in scope.sorted() {
            guard let store = stores[identifier],
                  let ended = store.lastImportEndedAt,
                  ended >= requestedAt else { return .waiting }
            if store.lastImportAt.map({ $0 < ended }) ?? true, failure == nil {
                failure = store.lastError ?? "iCloud sync failed."
            }
        }
        return failure.map(Progress.failed) ?? .finished
    }

    private static func later(_ current: Date?, _ candidate: Date) -> Date {
        guard let current else { return candidate }
        return max(current, candidate)
    }
}

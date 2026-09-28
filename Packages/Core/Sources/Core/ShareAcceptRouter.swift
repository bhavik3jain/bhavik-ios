import CloudKit
import CoreData

/// Modules register their own `NSPersistentCloudKitContainer` here at launch,
/// keyed by the CloudKit record type of their share root (e.g. "CD_SharedTrip"
/// — Core Data names every record type "CD_" + entity name), so the app
/// shell's share-accept delegate can hand an incoming invitation to the right
/// module's container without importing any module's models.
@MainActor
public final class ShareAcceptRouter: ObservableObject {
    public static let shared = ShareAcceptRouter()
    private init() {}

    /// What the app shows after a tapped invitation, good or bad. Accepting
    /// used to fail without a word: the app opened and nothing happened.
    public struct Outcome: Identifiable, Equatable {
        public let id = UUID()
        public let title: String
        public let message: String
    }

    @Published public var outcome: Outcome?

    private var containersByShareType: [String: NSPersistentCloudKitContainer] = [:]

    public func register(recordTypePrefix: String, container: NSPersistentCloudKitContainer) {
        containersByShareType[recordTypePrefix] = container
    }

    /// The value a share of `object` is stamped with, which `accept` routes
    /// on: its record type, the same key its module registered under.
    public nonisolated static func shareType(for object: NSManagedObject) -> String? {
        object.entity.name.map { "CD_\($0)" }
    }

    /// Stamps `share` with the module it belongs to. Returns whether anything
    /// changed, so an existing share is only re-saved when it needs it.
    ///
    /// `NSPersistentCloudKitContainer` shares a whole record zone, and a zone
    /// share has no root record — `metadata.rootRecord` stays nil even when
    /// fetched with `shouldFetchRootRecord`. Routing by root record type
    /// therefore dropped every invitation. `shareType` is a system field of
    /// every CKShare, so writing it needs no schema change.
    @discardableResult
    public nonisolated static func stamp(_ share: CKShare, for object: NSManagedObject) -> Bool {
        guard let type = shareType(for: object),
              share[CKShare.SystemFieldKey.shareType] as? String != type else { return false }
        share[CKShare.SystemFieldKey.shareType] = type as CKRecordValue
        return true
    }

    /// Called from the app shell for every accepted invitation, on both
    /// platforms and on both iOS paths (app already running, or launched by
    /// the tap).
    public func accept(_ metadata: CKShare.Metadata) {
        guard let type = metadata.share[CKShare.SystemFieldKey.shareType] as? String,
              let container = containersByShareType[type] else {
            outcome = Outcome(
                title: "Couldn't Open This Share",
                message: "This share was made by an older version of the app. Ask the person who shared it to open Share on it once more, then tap the link again."
            )
            return
        }
        // acceptShareInvitations wants the loaded store, which is only
        // reachable through the coordinator by the URL its description gave.
        guard let sharedStoreURL = container.persistentStoreDescriptions
                .first(where: { $0.cloudKitContainerOptions?.databaseScope == .shared })?.url,
              let sharedStore = container.persistentStoreCoordinator.persistentStore(for: sharedStoreURL) else {
            outcome = Outcome(title: "Couldn't Open This Share", message: "The app's shared storage isn't available.")
            return
        }
        // From a background queue: this runs as the app launches from a
        // tapped invitation, and the call waits synchronously on the same
        // executor as `persistUpdatedShare` — see CloudShareCalls.swift.
        container.acceptShareInvitationsInBackground(from: metadata, into: sharedStore) { error in
            let message = error?.localizedDescription
            Task { @MainActor in
                if let message {
                    self.outcome = Outcome(title: "Couldn't Open This Share", message: message)
                } else {
                    self.outcome = Outcome(
                        title: "Share Added",
                        message: "It can take a minute to download. It'll appear in its tracker, marked Shared with me."
                    )
                    // The moment notifications about the other person's
                    // changes start to matter — see SharedChangeNotifications.
                    await SharedChangeNotifications.requestAuthorizationIfUndetermined()
                    SharedChangeServerAlerts.shared.sync(force: true)
                }
            }
        }
    }
}

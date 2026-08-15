import CloudKit
import SwiftUI

/// Whether iCloud is in a state where syncing can happen.
///
/// SwiftData does not report progress or a last-synced time, so this reports
/// what can actually be known — the account's standing — rather than implying a
/// freshness the framework never tells us about.
public enum CloudSyncState: Equatable, Sendable {
    case checking
    case syncing
    case signedOut
    case restricted
    case temporarilyUnavailable
    case undetermined

    public var summary: String {
        switch self {
        case .checking: "Checking…"
        case .syncing: "On"
        case .signedOut: "Signed out"
        case .restricted: "Restricted"
        case .temporarilyUnavailable: "Unavailable"
        case .undetermined: "Unknown"
        }
    }

    /// What it means for the reader's data, and what to do about it.
    public var explanation: String {
        switch self {
        case .checking:
            "Checking with iCloud."
        case .syncing:
            "Everything you track syncs through your iCloud account, so it comes back when you reinstall or set up another device."
        case .signedOut:
            "This device isn't signed in to iCloud, so nothing is syncing. Your data is still saved here."
        case .restricted:
            "iCloud is restricted on this device, so nothing is syncing. Your data is still saved here."
        case .temporarilyUnavailable:
            "iCloud is unavailable at the moment. Syncing picks up again on its own."
        case .undetermined:
            "iCloud couldn't be reached, so it isn't clear whether syncing is working."
        }
    }

    public var isHealthy: Bool { self == .syncing }

    public var symbolName: String {
        switch self {
        case .checking: "arrow.triangle.2.circlepath"
        case .syncing: "checkmark.icloud"
        case .signedOut, .restricted: "xmark.icloud"
        case .temporarilyUnavailable, .undetermined: "exclamationmark.icloud"
        }
    }

    public init(_ status: CKAccountStatus) {
        self = switch status {
        case .available: .syncing
        case .noAccount: .signedOut
        case .restricted: .restricted
        case .temporarilyUnavailable: .temporarilyUnavailable
        case .couldNotDetermine: .undetermined
        @unknown default: .undetermined
        }
    }
}

public enum CloudSync {
    /// Asks CloudKit how the account stands. Any failure reads as undetermined
    /// rather than as working, so a problem is never shown as healthy.
    public static func state(containerID: String) async -> CloudSyncState {
        let container = CKContainer(identifier: containerID)
        do {
            return CloudSyncState(try await container.accountStatus())
        } catch {
            return .undetermined
        }
    }
}

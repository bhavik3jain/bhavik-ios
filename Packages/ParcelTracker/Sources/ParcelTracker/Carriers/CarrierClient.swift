import Foundation

/// A status reading for one parcel, as returned by a carrier.
public struct TrackingResult: Sendable, Equatable {
    public let status: ParcelStatus
    public let estimatedDelivery: Date?
    public let events: [TrackingEvent]

    public init(status: ParcelStatus, estimatedDelivery: Date? = nil, events: [TrackingEvent] = []) {
        self.status = status
        self.estimatedDelivery = estimatedDelivery
        self.events = events
    }
}

public struct TrackingEvent: Sendable, Equatable {
    public let occurredAt: Date
    public let detail: String
    public let location: String
    public let status: ParcelStatus
    /// Position in the carrier's own newest-first listing.
    ///
    /// Carriers stamp several scans with the same time — FedEx reports the
    /// delivery and the out-for-delivery scan to the same minute — so sorting
    /// by date alone can put the wrong one last. Their ordering breaks the tie.
    public let sequence: Int

    public init(occurredAt: Date, detail: String, location: String, status: ParcelStatus, sequence: Int = 0) {
        self.occurredAt = occurredAt
        self.detail = detail
        self.location = location
        self.status = status
        self.sequence = sequence
    }
}

public extension Array where Element == TrackingEvent {
    /// Oldest first, falling back to the carrier's ordering when times match.
    var chronological: [TrackingEvent] {
        sorted {
            $0.occurredAt == $1.occurredAt ? $0.sequence > $1.sequence : $0.occurredAt < $1.occurredAt
        }
    }
}

public enum CarrierError: LocalizedError, Equatable {
    case missingCredentials(Carrier)
    case notSupported(Carrier)
    case notFound
    case unauthorized
    case rateLimited
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredentials(let carrier):
            "Add \(carrier.displayName) API credentials in Settings to track automatically."
        case .notSupported(let carrier):
            "\(carrier.displayName) parcels are updated by hand — tap the parcel to open \(carrier.displayName)'s own tracking."
        case .notFound:
            "The carrier doesn't recognise that tracking number yet. New labels can take a day to appear."
        case .unauthorized:
            "Those API credentials were rejected. Check them in Settings."
        case .rateLimited:
            "The carrier is rate limiting requests. Try again shortly."
        case .network(let detail):
            detail
        }
    }
}

/// Reads parcel status from one carrier.
public protocol CarrierClient: Sendable {
    var carrier: Carrier { get }
    func track(_ trackingNumber: String) async throws -> TrackingResult
}

/// Routes a parcel to whichever client handles its carrier.
public struct CarrierRouter: Sendable {
    private let clients: [Carrier: any CarrierClient]

    public init(clients: [any CarrierClient]) {
        self.clients = Dictionary(clients.map { ($0.carrier, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func track(_ trackingNumber: String, carrier: Carrier) async throws -> TrackingResult {
        guard carrier.supportsAutomaticTracking else {
            throw CarrierError.notSupported(carrier)
        }
        guard let client = clients[carrier] else {
            throw CarrierError.missingCredentials(carrier)
        }
        return try await client.track(trackingNumber)
    }
}

import Foundation
import SwiftData

public enum ParcelStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case inTransit
    case outForDelivery
    case delivered
    case exception
    case unknown

    public var displayName: String {
        switch self {
        case .pending: "Label created"
        case .inTransit: "In transit"
        case .outForDelivery: "Out for delivery"
        case .delivered: "Delivered"
        case .exception: "Exception"
        case .unknown: "Unknown"
        }
    }

    public var symbolName: String {
        switch self {
        case .pending: "shippingbox"
        case .inTransit: "box.truck"
        case .outForDelivery: "truck.box"
        case .delivered: "checkmark.circle.fill"
        case .exception: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }

    public var isSettled: Bool { self == .delivered }
}

@Model
public final class Parcel {
    public var trackingNumber: String = ""
    public var name: String = ""
    public var carrierRaw: String = Carrier.other.rawValue
    public var statusRaw: String = ParcelStatus.unknown.rawValue
    public var addedAt: Date = Date.now
    /// When the app last succeeded in reading this parcel's status.
    public var lastRefreshedAt: Date?
    public var estimatedDelivery: Date?
    /// Set when a refresh fails, so a stale status is never shown as current.
    public var lastErrorMessage: String = ""
    public var isArchived: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \ParcelEvent.parcel)
    public var events: [ParcelEvent]? = []

    public var carrier: Carrier {
        get { Carrier(rawValue: carrierRaw) ?? .other }
        set { carrierRaw = newValue.rawValue }
    }

    public var status: ParcelStatus {
        get { ParcelStatus(rawValue: statusRaw) ?? .unknown }
        set { statusRaw = newValue.rawValue }
    }

    public init(trackingNumber: String, name: String, carrier: Carrier) {
        self.trackingNumber = trackingNumber
        self.name = name
        self.carrierRaw = carrier.rawValue
        self.addedAt = .now
    }

    /// Newest first, using the carrier's ordering to settle equal timestamps.
    public var orderedEvents: [ParcelEvent] {
        (events ?? []).sorted {
            $0.occurredAt == $1.occurredAt ? $0.sequence < $1.sequence : $0.occurredAt > $1.occurredAt
        }
    }

    public var trackingURL: URL? {
        carrier.trackingURL(for: trackingNumber)
    }

    /// Parcels the app can't refresh itself are the reader's to update, so the
    /// UI marks them rather than showing a status that will never change.
    public var isManual: Bool {
        !carrier.supportsAutomaticTracking
    }
}

@Model
public final class ParcelEvent {
    public var occurredAt: Date = Date.now
    public var detail: String = ""
    public var location: String = ""
    public var statusRaw: String = ParcelStatus.unknown.rawValue
    /// Position in the carrier's listing, used to order scans that share a
    /// timestamp — FedEx reports delivery and out-for-delivery to the minute.
    public var sequence: Int = 0

    public var parcel: Parcel?

    public var status: ParcelStatus {
        get { ParcelStatus(rawValue: statusRaw) ?? .unknown }
        set { statusRaw = newValue.rawValue }
    }

    public init(occurredAt: Date, detail: String, location: String = "", status: ParcelStatus = .unknown) {
        self.occurredAt = occurredAt
        self.detail = detail
        self.location = location
        self.statusRaw = status.rawValue
    }
}

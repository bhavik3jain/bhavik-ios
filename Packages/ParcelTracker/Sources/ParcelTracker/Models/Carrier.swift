import Foundation

public enum Carrier: String, CaseIterable, Codable, Sendable {
    case ups
    case fedex
    case usps
    case other

    public var displayName: String {
        switch self {
        case .ups: "UPS"
        case .fedex: "FedEx"
        case .usps: "USPS"
        case .other: "Other"
        }
    }

    /// Whether the app can fetch status for this carrier itself.
    ///
    /// USPS closed third-party tracking in April 2026 — its API now serves only
    /// the shipper of record. UPS has an API the app could use, but it isn't
    /// wired up yet. Either way the parcel is followed by hand and opened on
    /// the carrier's own site.
    public var supportsAutomaticTracking: Bool {
        switch self {
        case .fedex: true
        case .ups, .usps, .other: false
        }
    }

    /// Why a carrier can't be read automatically, for the screens that explain it.
    public var manualTrackingReason: String? {
        switch self {
        case .fedex, .other:
            nil
        case .ups:
            "UPS orders are tracked by hand: check UPS's tracking page, then set this order's status."
        case .usps:
            "USPS shares tracking only with whoever shipped an order, so check USPS's tracking page, then set this order's status."
        }
    }

    /// The carrier's own tracking page, for parcels the app can't follow itself.
    public func trackingURL(for number: String) -> URL? {
        let encoded = number.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? number
        return switch self {
        case .usps: URL(string: "https://tools.usps.com/go/TrackConfirmAction?tLabels=\(encoded)")
        case .ups: URL(string: "https://www.ups.com/track?tracknum=\(encoded)")
        case .fedex: URL(string: "https://www.fedex.com/fedextrack/?trknbr=\(encoded)")
        case .other: nil
        }
    }
}

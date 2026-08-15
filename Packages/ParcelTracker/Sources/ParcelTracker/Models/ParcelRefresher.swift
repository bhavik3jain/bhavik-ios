import Foundation
import SwiftData

/// Applies a carrier reading to a stored parcel.
public enum ParcelRefresher {
    @MainActor
    @discardableResult
    public static func refresh(
        _ parcel: Parcel,
        using router: CarrierRouter,
        context: ModelContext
    ) async -> Bool {
        do {
            let result = try await router.track(parcel.trackingNumber, carrier: parcel.carrier)
            apply(result, to: parcel, context: context)
            parcel.lastErrorMessage = ""
            parcel.lastRefreshedAt = .now
            try? context.save()
            return true
        } catch {
            // The status already on screen came from an earlier reading, so it
            // stays put — but the failure is recorded rather than swallowed, so
            // the row can say the parcel hasn't been re-read.
            parcel.lastErrorMessage = error.localizedDescription
            try? context.save()
            return false
        }
    }

    @MainActor
    static func apply(_ result: TrackingResult, to parcel: Parcel, context: ModelContext) {
        parcel.status = result.status
        parcel.estimatedDelivery = result.estimatedDelivery

        // Events are replaced rather than merged: the carrier's listing is the
        // whole history, and matching on time alone would duplicate the scans
        // that share a timestamp.
        for existing in parcel.events ?? [] {
            context.delete(existing)
        }
        for event in result.events {
            let stored = ParcelEvent(
                occurredAt: event.occurredAt,
                detail: event.detail,
                location: event.location,
                status: event.status
            )
            stored.sequence = event.sequence
            stored.parcel = parcel
            context.insert(stored)
        }
    }
}

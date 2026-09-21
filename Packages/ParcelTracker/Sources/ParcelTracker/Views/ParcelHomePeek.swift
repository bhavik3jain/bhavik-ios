import Core
import SwiftUI

public extension ParcelTrackerModule {
    /// What long-pressing Orders on the home screen shows: everything still on
    /// its way, soonest expected first, with its latest scan.
    @MainActor
    static func homePeek(parcels: [Parcel]) -> some View {
        ParcelHomePeek(
            active: parcels
                .filter { !$0.status.isSettled }
                .sorted { ($0.estimatedDelivery ?? .distantFuture) < ($1.estimatedDelivery ?? .distantFuture) }
        )
    }
}

struct ParcelHomePeek: View {
    let active: [Parcel]

    var body: some View {
        ModulePeekCard(
            accent: ParcelTrackerModule.accent,
            icon: "shippingbox.fill",
            subtitle: active.isEmpty ? "" : "\(counted(active.count, "order")) on the way"
        ) {
            if active.isEmpty {
                PeekEmpty("Nothing on the way.")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(active.prefix(4)) { parcel in
                        PeekRow(
                            parcel.name.isEmpty ? parcel.trackingNumber : parcel.name,
                            detail: detail(for: parcel),
                            value: parcel.status.displayName,
                            tint: parcel.status == .exception ? .red : ParcelTrackerModule.accent.color
                        )
                    }
                    if active.count > 4 {
                        PeekEmpty("and \(counted(active.count - 4, "more order"))")
                    }
                }
            }
        }
    }

    private func detail(for parcel: Parcel) -> String {
        var parts = [parcel.carrier.displayName]
        if let eta = parcel.estimatedDelivery {
            parts.append("due \(eta.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))")
        } else if let latest = parcel.orderedEvents.first, !latest.detail.isEmpty {
            parts.append(latest.detail)
        }
        return parts.joined(separator: " · ")
    }
}

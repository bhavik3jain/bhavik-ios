import Core
import SwiftUI

public extension ParcelTrackerModule {
    /// The Mac Overview's Orders card: how many are on the way and how far the
    /// first two have got, soonest expected first.
    @MainActor
    static func overviewCard(parcels: [Parcel], open: @escaping () -> Void) -> some View {
        ParcelOverviewCard(
            active: parcels
                .filter { !$0.status.isSettled }
                .sorted { ($0.estimatedDelivery ?? .distantFuture) < ($1.estimatedDelivery ?? .distantFuture) },
            open: open
        )
    }
}

struct ParcelOverviewCard: View {
    let active: [Parcel]
    let open: () -> Void

    var body: some View {
        OverviewCard(accent: ParcelTrackerModule.accent, icon: ParcelTrackerModule.symbolName, open: open) {
            // Tight enough for two orders in the Overview's 190pt row: the
            // Mac's linear progress bar is taller than the phone's, and at the
            // looser spacing the card grew past its neighbours.
            VStack(alignment: .leading, spacing: 6) {
                OverviewValue(active.isEmpty ? "Nothing on the way" : "\(active.count) on the way")
                Spacer(minLength: 0)
                ForEach(active.prefix(2)) { parcel in
                    row(parcel)
                }
            }
        }
    }

    private func row(_ parcel: Parcel) -> some View {
        let accent = ParcelTrackerModule.accent.color
        let status = parcel.status
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(parcel.name.isEmpty ? parcel.trackingNumber : parcel.name)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(status.displayName)
                    .fontWeight(status == .outForDelivery ? .semibold : .regular)
                    .foregroundStyle(status == .exception ? AnyShapeStyle(.red) : (status == .outForDelivery ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary)))
            }
            .font(.system(size: 12))
            ProgressView(value: progress(status))
                .progressViewStyle(.linear)
                .tint(status == .exception ? .red : accent)
                .accessibilityHidden(true)
        }
    }

    /// Roughly how far along its journey a status puts an order — a picture,
    /// not a measurement, so it lives with the bar that draws it.
    private func progress(_ status: ParcelStatus) -> Double {
        switch status {
        case .pending, .unknown: 0.12
        case .inTransit, .exception: 0.5
        case .outForDelivery: 0.88
        case .delivered: 1
        }
    }
}

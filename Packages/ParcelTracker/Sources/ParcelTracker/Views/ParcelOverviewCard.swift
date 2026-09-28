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
            if active.isEmpty {
                OverviewEmptyState("Nothing on the way", message: "Add an order's tracking number to follow it here.")
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    OverviewValue(String(active.count), unit: "on the way")
                    OverviewCaption(expected)
                    Spacer(minLength: 6)
                    // Tight enough for two orders in the Overview's row
                    // (`OverviewGrid.rowHeight`): the Mac's linear progress bar
                    // is taller than the phone's, and at a looser spacing the
                    // card grew past its neighbours.
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(active.prefix(2)) { parcel in
                            row(parcel)
                        }
                    }
                }
            }
        }
    }

    /// When the soonest one is due, or how many are out for delivery today.
    private var expected: String {
        let out = active.count { $0.status == .outForDelivery }
        if out > 0 { return "\(counted(out, "order")) out for delivery" }
        if let soonest = active.first?.estimatedDelivery {
            return "Next due \(soonest.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))"
        }
        return "No delivery dates yet"
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

import Core
import SwiftData
import SwiftUI

/// Orders on the Mac: what's coming as three figures, then every order in a
/// sortable table — the phone's two short lists, across a desktop window,
/// were three lines of text in an empty page. Double-click opens an order.
struct MacOrdersView: View {
    let parcels: [Parcel]
    let open: (Parcel) -> Void
    let delete: (Parcel) -> Void

    @State private var sortOrder = [KeyPathComparator(\Parcel.addedAt, order: .reverse)]
    @State private var selection: Parcel.ID?

    private var accent: Color { ParcelTrackerModule.accent.color }

    var body: some View {
        let onTheWay = parcels.filter { !$0.status.isSettled }
        let nextDue = onTheWay.compactMap(\.estimatedDelivery).min()
        let delivered = parcels.filter(\.status.isSettled)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                MacStatCard(title: "On the way", value: String(onTheWay.count), detail: counted(parcels.count, "order") + " in all", symbol: "shippingbox.fill", tint: accent)
                MacStatCard(
                    title: "Next due",
                    value: nextDue.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "—",
                    detail: nextDue.map { $0.formatted(.relative(presentation: .named)) } ?? "No dates from the carriers yet",
                    symbol: "calendar",
                    tint: accent
                )
                MacStatCard(title: "Delivered", value: String(delivered.count), detail: "Kept until archived", symbol: "checkmark.circle.fill", tint: .green)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Table(parcels.sorted(using: sortOrder), selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Order", value: \.listTitle) { parcel in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(parcel.listTitle)
                            if !parcel.lastErrorMessage.isEmpty {
                                Text(parcel.lastErrorMessage)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .lineLimit(1)
                            }
                        }
                    } icon: {
                        Image(systemName: parcel.status.symbolName)
                            .foregroundStyle(parcel.status == .delivered ? Color.green : accent)
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("Carrier", value: \.carrierName)
                    .width(min: 70, ideal: 90)
                TableColumn("Status", value: \.statusName) { parcel in
                    Text(parcel.isManual ? "\(parcel.status.displayName) · Manual" : parcel.status.displayName)
                }
                .width(min: 90, ideal: 130)
                TableColumn("Due", value: \.dueSortKey) { parcel in
                    if let due = parcel.estimatedDelivery, !parcel.status.isSettled {
                        Text(due.formatted(.dateTime.month(.abbreviated).day()))
                            .monospacedDigit()
                    }
                }
                .width(min: 60, ideal: 80)
                TableColumn("Tracking", value: \.trackingNumber) { parcel in
                    Text(parcel.trackingNumber)
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .width(min: 120, ideal: 180)
                TableColumn("Added", value: \.addedAt) { parcel in
                    Text(parcel.addedAt.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 100)
            }
            // No blank striped rows filling the space under the last one.
            .alternatingRowBackgrounds(.disabled)
            .contextMenu(forSelectionType: Parcel.ID.self) { ids in
                if let parcel = parcel(for: ids) {
                    Button("Open", systemImage: "arrow.up.forward.app") { open(parcel) }
                    if let url = parcel.trackingURL {
                        Link(destination: url) { Label("Track on \(parcel.carrier.displayName)", systemImage: "safari") }
                    }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(parcel) }
                }
            } primaryAction: { ids in
                if let parcel = parcel(for: ids) { open(parcel) }
            }
        }
    }

    private func parcel(for ids: Set<Parcel.ID>) -> Parcel? {
        ids.first.flatMap { id in parcels.first { $0.id == id } }
    }
}

extension Parcel {
    /// For the Mac table's sortable columns.
    var listTitle: String { name.isEmpty ? trackingNumber : name }
    var carrierName: String { carrier.displayName }
    var statusName: String { status.displayName }
    /// No date sorts last.
    var dueSortKey: Date { estimatedDelivery ?? .distantFuture }
}

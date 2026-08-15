import SwiftData
import Core
import SwiftUI

struct ParcelListView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage(ParcelTrackerModule.fedExKeyDefaultsKey) private var fedExKey = ""
    @AppStorage(ParcelTrackerModule.fedExSecretDefaultsKey) private var fedExSecret = ""

    @Query(filter: #Predicate<Parcel> { !$0.isArchived }, sort: \Parcel.addedAt, order: .reverse)
    private var parcels: [Parcel]

    @State private var showingAdd = false
    @State private var isRefreshing = false

    private var active: [Parcel] { parcels.filter { !$0.status.isSettled } }
    private var delivered: [Parcel] { parcels.filter { $0.status.isSettled } }

    var body: some View {
        NavigationStack {
            Group {
                if parcels.isEmpty {
                    ContentUnavailableView {
                        Label("No parcels", systemImage: "shippingbox")
                    } description: {
                        Text("Add a tracking number and the carrier is worked out for you.")
                    } actions: {
                        Button("Add Parcel") { showingAdd = true }
                            .buttonStyle(.borderedProminent)
                            .tint(ParcelTrackerModule.accent.color)
                    }
                } else {
                    List {
                        if !active.isEmpty {
                            Section("On the way") {
                                ForEach(active) { parcel in
                                    row(for: parcel)
                                }
                                .onDelete { delete(active, at: $0) }
                            }
                        }
                        if !delivered.isEmpty {
                            Section("Delivered") {
                                ForEach(delivered) { parcel in
                                    row(for: parcel)
                                }
                                .onDelete { delete(delivered, at: $0) }
                            }
                        }
                    }
                    .refreshable { await refreshAll() }
                }
            }
            .navigationTitle("Parcels")
            .moduleChrome(accent: ParcelTrackerModule.accent) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddParcelView()
            }
        }
    }

    private func row(for parcel: Parcel) -> some View {
        NavigationLink {
            ParcelDetailView(parcel: parcel, router: router)
        } label: {
            ParcelRow(parcel: parcel)
        }
    }

    private var router: CarrierRouter {
        var clients: [any CarrierClient] = []
        if !fedExKey.isEmpty, !fedExSecret.isEmpty {
            clients.append(FedExClient(apiKey: fedExKey, apiSecret: fedExSecret))
        }
        return CarrierRouter(clients: clients)
    }

    private func refreshAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let router = router
        for parcel in parcels where parcel.carrier.supportsAutomaticTracking {
            await ParcelRefresher.refresh(parcel, using: router, context: modelContext)
        }
    }

    private func delete(_ source: [Parcel], at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(source[index])
        }
    }
}

struct ParcelRow: View {
    let parcel: Parcel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: parcel.status.symbolName)
                .font(.title3)
                .foregroundStyle(parcel.status == .delivered ? .green : ParcelTrackerModule.accent.color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(parcel.name.isEmpty ? parcel.trackingNumber : parcel.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(parcel.carrier.displayName)
                    Text("·")
                    Text(parcel.status.displayName)
                    if parcel.isManual {
                        Text("· Manual")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !parcel.lastErrorMessage.isEmpty {
                    Label(parcel.lastErrorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }

            Spacer()

            if let estimated = parcel.estimatedDelivery, parcel.status != .delivered {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Due")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(estimated, format: .dateTime.month().day())
                        .font(.caption)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
    }
}

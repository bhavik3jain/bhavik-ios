import SwiftData
import SwiftUI

struct ParcelDetailView: View {
    @Bindable var parcel: Parcel
    let router: CarrierRouter

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @State private var isRefreshing = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: parcel.status.symbolName)
                        .font(.largeTitle)
                        .foregroundStyle(parcel.status == .delivered ? .green : ParcelTrackerModule.accent.color)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(parcel.status.displayName)
                            .font(.headline)
                        Text("\(parcel.carrier.displayName) · \(parcel.trackingNumber)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if let refreshed = parcel.lastRefreshedAt {
                            Text("Checked \(refreshed.formatted(.relative(presentation: .named)))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)

                if let estimated = parcel.estimatedDelivery {
                    LabeledContent("Estimated delivery") {
                        Text(estimated, format: .dateTime.weekday(.wide).month().day())
                    }
                }
            }

            if !parcel.lastErrorMessage.isEmpty {
                Section {
                    Label(parcel.lastErrorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                } footer: {
                    Text("The status above is from the last successful check, not from just now.")
                }
            }

            Section {
                if parcel.carrier.supportsAutomaticTracking {
                    Button {
                        Task { await refresh() }
                    } label: {
                        HStack {
                            Label("Refresh", systemImage: "arrow.clockwise")
                            if isRefreshing {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRefreshing)
                }

                if let url = parcel.trackingURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Open in \(parcel.carrier.displayName)", systemImage: "safari")
                    }
                }

                Picker("Status", selection: $parcel.statusRaw) {
                    ForEach(ParcelStatus.allCases, id: \.rawValue) { status in
                        Text(status.displayName).tag(status.rawValue)
                    }
                }
                .disabled(parcel.carrier.supportsAutomaticTracking)
            } footer: {
                if parcel.isManual {
                    Text("\(parcel.carrier.displayName) doesn't let apps look up parcels they didn't ship, so set the status yourself after checking with the carrier.")
                }
            }

            if !parcel.orderedEvents.isEmpty {
                Section("History") {
                    ForEach(parcel.orderedEvents) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.detail)
                                .font(.subheadline)
                            HStack(spacing: 6) {
                                Text(event.occurredAt, format: .dateTime.month().day().hour().minute())
                                if !event.location.isEmpty {
                                    Text("· \(event.location)")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(parcel.name.isEmpty ? parcel.trackingNumber : parcel.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard parcel.carrier.supportsAutomaticTracking, parcel.lastRefreshedAt == nil else { return }
            await refresh()
        }
    }

    private func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        await ParcelRefresher.refresh(parcel, using: router, context: modelContext)
    }
}

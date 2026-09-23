import Core
import CoreData
import SwiftUI
import UniformTypeIdentifiers

struct GarageView: View {
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.fuelPersistentContainer) private var container
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \SharedVehicle.createdAt, ascending: true)])
    private var vehicles: FetchedResults<SharedVehicle>

    @State private var showingImporter = false
    @State private var showingAddVehicle = false
    @State private var newVehicleName = ""
    @State private var importResult: ImportResult?

    private enum ImportResult: Identifiable {
        case success(ImportSummary)
        case failure(String)

        var id: String {
            switch self {
            case .success(let summary): "success-\(summary.totalImported)-\(summary.duplicatesSkipped)"
            case .failure(let message): "failure-\(message)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Vehicles") {
                    ForEach(vehicles) { vehicle in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vehicle.name)
                                if let label = sharingLabel(for: vehicle) {
                                    Label(label, systemImage: "person.2.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .labelStyle(.titleAndIcon)
                                }
                            }
                            Spacer()
                            Text("\(vehicle.orderedFillUps.count) fill-ups")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: deleteVehicles)

                    Button {
                        newVehicleName = ""
                        showingAddVehicle = true
                    } label: {
                        Label("Add Vehicle", systemImage: "plus")
                    }
                }

                Section {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import from Fuelly", systemImage: "square.and.arrow.down")
                    }
                } footer: {
                    Text("Import a CSV exported from Fuelly. Fill-ups and service records are added for every vehicle in the file, and anything already imported is skipped.")
                }
            }
            .navigationTitle("Garage")
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.commaSeparatedText, .text],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .alert("Add Vehicle", isPresented: $showingAddVehicle) {
                TextField("Name", text: $newVehicleName)
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    let trimmed = newVehicleName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    _ = SharedVehicle(context: modelContext, name: trimmed)
                    try? modelContext.saveIfNeeded()
                }
            }
            .alert(item: $importResult) { result in
                switch result {
                case .success(let summary):
                    Alert(
                        title: Text("Import complete"),
                        message: Text(message(for: summary)),
                        dismissButton: .default(Text("OK"))
                    )
                case .failure(let message):
                    Alert(
                        title: Text("Import failed"),
                        message: Text(message),
                        dismissButton: .default(Text("OK"))
                    )
                }
            }
        }
    }

    private func message(for summary: ImportSummary) -> String {
        var lines: [String] = []
        if summary.fillUpsImported > 0 {
            lines.append("\(summary.fillUpsImported) fill-ups")
        }
        if summary.servicesImported > 0 {
            lines.append("\(summary.servicesImported) service records")
        }
        if lines.isEmpty {
            lines.append("Nothing new")
        }
        var message = "Added \(lines.joined(separator: " and "))."
        if !summary.vehicleNames.isEmpty {
            message += "\nNew vehicles: \(summary.vehicleNames.joined(separator: ", "))."
        }
        if summary.duplicatesSkipped > 0 {
            message += "\nSkipped \(summary.duplicatesSkipped) already imported."
        }
        if summary.rowsFailed > 0 {
            message += "\n\(summary.rowsFailed) rows could not be read."
        }
        return message
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let summary = try FuellyImporter.importCSV(at: url, into: modelContext)
                importResult = .success(summary)
            } catch {
                importResult = .failure(error.localizedDescription)
            }
        case .failure(let error):
            importResult = .failure(error.localizedDescription)
        }
    }

    private func deleteVehicles(at offsets: IndexSet) {
        // A read-only participant's swipe is silently dropped rather than
        // hidden — `onDelete` offers the same gesture to every row, so
        // filtering here (the same pattern `ArchivedTripsView` uses) is the
        // only per-row way to withhold it.
        for index in offsets where canEdit(vehicles[index]) {
            modelContext.delete(vehicles[index])
        }
        try? modelContext.saveIfNeeded()
    }

    private func sharingLabel(for vehicle: SharedVehicle) -> String? {
        guard let container else { return nil }
        return SharingStatusResolver.status(for: vehicle, in: container).vehicleBadgeLabel
    }

    private func canEdit(_ vehicle: SharedVehicle) -> Bool {
        guard let container else { return true }
        return SharingStatusResolver.canEdit(vehicle, in: container)
    }
}

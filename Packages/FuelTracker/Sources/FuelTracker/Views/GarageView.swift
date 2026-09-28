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
    @State private var confirmingMerge = false
    @State private var mergeResult: String?

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
                if !duplicates.isEmpty {
                    Section {
                        Button("Merge Duplicate Cars…", systemImage: "rectangle.stack.badge.minus") {
                            confirmingMerge = true
                        }
                    } footer: {
                        Text("\(duplicateSummary) — most likely copied again when the app was reinstalled. Merging keeps one of each, with every fill-up, and removes the copies.")
                    }
                }

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
            .refreshesFromCloud()
            .navigationTitle("Garage")
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.commaSeparatedText, .text],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
            }
            .textPrompt("Add Vehicle", isPresented: $showingAddVehicle, text: $newVehicleName, prompt: "Name") {
                let trimmed = newVehicleName.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return }
                _ = SharedVehicle(context: modelContext, name: trimmed)
                try? modelContext.saveIfNeeded()
            }
            .confirmationDialog("Merge Duplicate Cars?", isPresented: $confirmingMerge, titleVisibility: .visible) {
                Button("Merge \(counted(duplicates.extraCount, "Copy", plural: "Copies"))", role: .destructive, action: mergeDuplicates)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(duplicates.groups.map { group in
                    "\(group.name): \(group.extras.count + 1) copies → 1" + (group.entriesToMove > 0 ? ", \(counted(group.entriesToMove, "entry", plural: "entries")) moved" : "")
                }.joined(separator: "\n") + "\n\nThis removes the copies on every device.")
            }
            .alert("Duplicates Merged", isPresented: Binding(get: { mergeResult != nil }, set: { if !$0 { mergeResult = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(mergeResult ?? "")
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

    /// This person's own cars that appear more than once. See `FuelDuplicates`.
    private var duplicates: FuelDuplicates {
        FuelDuplicates(
            vehicles: Array(vehicles),
            isOwn: { vehicle in
                guard let container else { return true }
                return vehicle.objectID.persistentStore == container.privatePersistentStore
            },
            isShared: { vehicle in
                guard let container else { return false }
                if case .owned = SharingStatusResolver.badgeStatus(for: vehicle, in: container) { return true }
                return false
            }
        )
    }

    /// "My X3 appears 3 times", "2 cars appear more than once".
    private var duplicateSummary: String {
        let groups = duplicates.groups
        if groups.count == 1, let group = groups.first {
            return "\(group.name) appears \(group.extras.count + 1) times"
        }
        return "\(groups.count) cars appear more than once"
    }

    private func mergeDuplicates() {
        // Worked out again with the synchronous sharing lookup: whether a
        // copy is shared decides which one survives, and deleting a shared
        // car would delete it for the partner too — not a call to make on a
        // badge's cached, possibly not-yet-looked-up answer.
        let fresh = FuelDuplicates(
            vehicles: Array(vehicles),
            isOwn: { vehicle in
                guard let container else { return true }
                return vehicle.objectID.persistentStore == container.privatePersistentStore
            },
            isShared: { vehicle in
                guard let container else { return false }
                if case .owned = SharingStatusResolver.status(for: vehicle, in: container) { return true }
                return false
            }
        )
        let result = fresh.merge()
        do {
            try modelContext.saveIfNeeded()
            mergeResult = "Removed \(counted(result.carsRemoved, "copy", plural: "copies")) and moved \(counted(result.entriesMoved, "entry", plural: "entries")) onto the cars kept."
        } catch {
            modelContext.rollback()
            mergeResult = "Nothing was changed: \(error.localizedDescription)"
        }
    }

    private func sharingLabel(for vehicle: SharedVehicle) -> String? {
        guard let container else { return nil }
        return SharingStatusResolver.badgeStatus(for: vehicle, in: container).vehicleBadgeLabel
    }

    private func canEdit(_ vehicle: SharedVehicle) -> Bool {
        guard let container else { return true }
        return SharingStatusResolver.canEdit(vehicle, in: container)
    }
}

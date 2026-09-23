import Core
import CoreData
import SwiftUI

/// Adds a trip, or edits one when given it.
struct TripEditorView: View {
    let trip: SharedTrip?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.tripPersistentContainer) private var container

    @State private var title = ""
    @State private var destination = ""
    @State private var latitude: Double?
    @State private var longitude: Double?
    @State private var startDate = Calendar.current.startOfDay(for: .now)
    @State private var endDate = Calendar.current.date(byAdding: .day, value: 3, to: Calendar.current.startOfDay(for: .now)) ?? .now
    @State private var notes = ""
    @State private var search = PlaceSearch(kinds: .address)
    @State private var loaded = false

    // A new trip (`trip == nil`) has no share yet, so it's always editable —
    // only an existing, possibly-shared trip can be read-only.
    private var canEditShare: Bool {
        guard let trip, let container else { return true }
        return SharingStatusResolver.canEdit(trip, in: container)
    }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && canEditShare }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Trip name", text: $title)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    if destination.isEmpty {
                        PlaceSearchRows(prompt: "Search for a city or region", search: search) { place in
                            destination = [place.name, place.address].filter { !$0.isEmpty }.joined(separator: ", ")
                            latitude = place.latitude
                            longitude = place.longitude
                            if title.trimmingCharacters(in: .whitespaces).isEmpty {
                                title = place.name
                            }
                        }
                    } else {
                        HStack {
                            Label(destination, systemImage: latitude == nil ? "mappin.slash" : "mappin.and.ellipse")
                            Spacer()
                            Button("Change") {
                                destination = ""
                                latitude = nil
                                longitude = nil
                            }
                            .font(.subheadline)
                        }
                    }
                } header: {
                    Text("Destination")
                } footer: {
                    Text("Picking a place from the list gives the trip a location, which is what its weather comes from.")
                }

                Section {
                    DatePicker("First day", selection: $startDate, displayedComponents: .date)
                    DatePicker("Last day", selection: $endDate, in: startDate..., displayedComponents: .date)
                } footer: {
                    Text(counted(TripDates(start: startDate, end: endDate).dayCount, "day"))
                }

                Section("Notes") {
                    TextField("Anything worth remembering", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(trip == nil ? "New Trip" : "Edit Trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(trip == nil ? "Add" : "Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onChange(of: startDate) { _, start in
                if endDate < start { endDate = start }
            }
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded, let trip else { return }
        loaded = true
        title = trip.title
        destination = trip.destination
        latitude = trip.latitude
        longitude = trip.longitude
        startDate = trip.startDate
        endDate = trip.endDate
        notes = trip.notes
    }

    private func save() {
        let calendar = Calendar.current
        let target = trip ?? SharedTrip(context: modelContext, title: "", startDate: startDate, endDate: endDate)
        target.title = title.trimmingCharacters(in: .whitespaces)
        target.destination = destination
        target.latitude = latitude
        target.longitude = longitude
        target.startDate = calendar.startOfDay(for: startDate)
        target.endDate = calendar.startOfDay(for: max(startDate, endDate))
        target.notes = notes
        target.clampPlanToDates()
        try? modelContext.saveIfNeeded()
        dismiss()
    }
}

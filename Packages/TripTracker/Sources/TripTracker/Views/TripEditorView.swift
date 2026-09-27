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
    @State private var anchor: ItineraryReschedule.Anchor = .moveWithTrip
    @State private var stranded: ItineraryReschedule.Stranding?

    // A new trip (`trip == nil`) has no share yet, so it's always editable —
    // only an existing, possibly-shared trip can be read-only.
    private var canEditShare: Bool {
        guard let trip, let container else { return true }
        return SharingStatusResolver.canEdit(trip, in: container)
    }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && canEditShare }

    /// What the new dates do to an existing trip's plan. Nil for a new trip,
    /// which has none.
    private var reschedule: ItineraryReschedule? {
        guard let trip else { return nil }
        return ItineraryReschedule(from: trip.dates, to: TripDates(start: startDate, end: endDate), anchor: anchor)
    }

    private var hasPlan: Bool {
        guard let trip else { return false }
        return !(trip.items ?? []).isEmpty || !(trip.flights ?? []).isEmpty || !(trip.bookings ?? []).isEmpty
    }

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
                    // Moving the first day carries the last along, keeping the
                    // trip's length — see `TripDates.movingStart(to:)`. A
                    // binding rather than `onChange`, which also fired for
                    // `load()` filling in the saved dates.
                    DatePicker("First day", selection: Binding {
                        startDate
                    } set: { start in
                        endDate = TripDates(start: startDate, end: endDate).movingStart(to: start).end
                        startDate = start
                    }, displayedComponents: .date)
                    DatePicker("Last day", selection: $endDate, in: startDate..., displayedComponents: .date)
                } footer: {
                    Text(counted(TripDates(start: startDate, end: endDate).dayCount, "day"))
                }

                // Only once the first day has actually moved: until then the
                // two choices do the same thing.
                if let reschedule, reschedule.startMoved, hasPlan {
                    Section {
                        Picker("Plan", selection: $anchor) {
                            ForEach(ItineraryReschedule.Anchor.allCases) { anchor in
                                Text(anchor.title).tag(anchor)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("The Plan")
                    } footer: {
                        Text(planFooter(reschedule))
                    }
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
            .onAppear(perform: load)
            // Shortening a trip used to pull whatever fell off its end onto the
            // last day without a word, which read as the plan rearranging
            // itself; anything before the start (keeping calendar dates) had
            // nowhere sensible to go at all.
            .confirmationDialog(
                stranded?.title ?? "",
                isPresented: Binding { stranded != nil } set: { if !$0 { stranded = nil } },
                titleVisibility: .visible,
                presenting: stranded
            ) { stranding in
                Button(stranding.nearestDayTitle) { write(overflow: .nearestDay) }
                if DayChoice.offersUnassigned, stranding.items > 0 {
                    Button(stranding.ideasTitle) { write(overflow: .unassigned) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { stranding in
                if DayChoice.offersUnassigned, stranding.items > 0, stranding.flights > 0 {
                    Text("Flights always stay on a day of the trip.")
                }
            }
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

    private func planFooter(_ reschedule: ItineraryReschedule) -> String {
        guard let trip else { return reschedule.effect }
        let stranding = reschedule.stranding(of: trip)
        guard !stranding.isEmpty else { return reschedule.effect }
        return "\(reschedule.effect) \(stranding.title), so saving asks where to put them."
    }

    private func save() {
        // Asked before anything is written: Cancel leaves the trip as it was.
        if let trip, let reschedule {
            let stranding = reschedule.stranding(of: trip)
            if !stranding.isEmpty {
                stranded = stranding
                return
            }
        }
        write(overflow: .nearestDay)
    }

    private func write(overflow: ItineraryReschedule.Overflow) {
        let calendar = Calendar.current
        // Read before the trip's dates change underneath it.
        let reschedule = reschedule
        let target = trip ?? SharedTrip(context: modelContext, title: "", startDate: startDate, endDate: endDate)
        target.title = title.trimmingCharacters(in: .whitespaces)
        target.destination = destination
        target.latitude = latitude
        target.longitude = longitude
        target.startDate = calendar.startOfDay(for: startDate)
        target.endDate = calendar.startOfDay(for: max(startDate, endDate))
        target.notes = notes
        reschedule?.apply(to: target, overflow: overflow)
        target.clampPlanToDates()
        try? modelContext.saveIfNeeded()
        dismiss()
    }
}

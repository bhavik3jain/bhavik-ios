import Core // Only reached on macOS, where Core stands in for the iOS-only SwiftUI API below.
import CoreData
import MapKit
import SwiftUI

/// Adds something to a day of the plan, or edits it.
struct ItemEditorView: View {
    let trip: Trip
    let item: ItineraryItem?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var modelContext

    @State private var title = ""
    @State private var kind: ItemKind = .sight
    @State private var day: Int
    @State private var hasTime = false
    @State private var time = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now) ?? .now
    @State private var durationMinutes = 0
    @State private var detail = ""
    @State private var place: PickedPlace?
    @State private var search: PlaceSearch
    @State private var confirmingDelete = false

    init(trip: Trip, item: ItineraryItem?, day: Int) {
        self.trip = trip
        self.item = item
        _day = State(initialValue: day)
        let center = trip.latitude.flatMap { latitude in
            trip.longitude.map { CLLocationCoordinate2D(latitude: latitude, longitude: $0) }
        }
        _search = State(initialValue: PlaceSearch(kinds: [.pointOfInterest, .address], near: center))
        if let item {
            _title = State(initialValue: item.title)
            _kind = State(initialValue: item.kind)
            _hasTime = State(initialValue: item.startTime != nil)
            if let start = item.startTime { _time = State(initialValue: start) }
            _durationMinutes = State(initialValue: item.durationMinutes)
            _detail = State(initialValue: item.detail)
            if item.hasCoordinate || !item.address.isEmpty {
                _place = State(initialValue: PickedPlace(name: item.title, address: item.address, latitude: item.latitude, longitude: item.longitude))
            }
        }
    }

    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(ItemKind.allCases, id: \.self) { kind in
                            Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                        }
                    }
                    TextField("What is it?", text: $title)
                        .textInputAutocapitalization(.words)
                }

                Section {
                    if let place {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Label(place.name, systemImage: place.latitude == nil ? "mappin.slash" : "mappin.and.ellipse")
                                if !place.address.isEmpty {
                                    Text(place.address)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { self.place = nil }
                                .font(.subheadline)
                        }
                    } else {
                        PlaceSearchRows(prompt: "Search for a place", search: search) { picked in
                            place = picked
                            if title.trimmingCharacters(in: .whitespaces).isEmpty {
                                title = picked.name
                            }
                        }
                    }
                } header: {
                    Text("Place")
                } footer: {
                    if place == nil {
                        Text("A place from the search gets a pin on the trip's map and directions.")
                    }
                }

                Section {
                    Picker("Day", selection: $day) {
                        ForEach(0..<trip.dates.dayCount, id: \.self) { index in
                            Text("Day \(index + 1) · \(trip.dates.date(forDay: index).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))")
                                .tag(index)
                        }
                    }
                    Toggle("Set a time", isOn: $hasTime.animation())
                    if hasTime {
                        DatePicker("Starts", selection: $time, displayedComponents: .hourAndMinute)
                        Picker("Length", selection: $durationMinutes) {
                            Text("Not set").tag(0)
                            ForEach([15, 30, 45, 60, 90, 120, 180, 240, 360], id: \.self) { minutes in
                                Text(ItineraryFormat.duration(minutes: minutes)).tag(minutes)
                            }
                            if ![0, 15, 30, 45, 60, 90, 120, 180, 240, 360].contains(durationMinutes) {
                                Text(ItineraryFormat.duration(minutes: durationMinutes)).tag(durationMinutes)
                            }
                        }
                    }
                } header: {
                    Text("When")
                } footer: {
                    if !hasTime {
                        Text("Without a time it goes under Anytime for that day.")
                    }
                }

                Section("Notes") {
                    TextField("Booking needed, what to order…", text: $detail, axis: .vertical)
                        .lineLimit(2...6)
                }

                if let item {
                    Section {
                        Button(item.isDone ? "Mark as Not Done" : "Mark as Done") {
                            item.toggleDone()
                            try? modelContext.saveIfNeeded()
                            dismiss()
                        }
                        Button("Delete", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(item == nil ? "Add to Plan" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(item == nil ? "Add" : "Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .confirmationDialog("Delete \(title)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let item {
                        modelContext.delete(item)
                        try? modelContext.saveIfNeeded()
                    }
                    dismiss()
                }
            }
        }
    }

    private func save() {
        let target = item ?? ItineraryItem(context: modelContext, title: "", dayIndex: day)
        if item == nil {
            // After everything already on the day, so a new untimed item joins
            // the end of Anytime rather than jumping the queue.
            let existing = (trip.items ?? []).filter { $0.dayIndex == day }.map(\.sortOrder)
            target.sortOrder = (existing.max() ?? -1) + 1
        }
        target.title = title.trimmingCharacters(in: .whitespaces)
        target.kind = kind
        target.dayIndex = day
        target.startTime = hasTime ? time : nil
        target.durationMinutes = hasTime ? durationMinutes : 0
        target.detail = detail
        target.address = place?.address ?? ""
        target.latitude = place?.latitude
        target.longitude = place?.longitude
        if item == nil {
            target.trip = trip
        }
        try? modelContext.saveIfNeeded()
        dismiss()
    }
}

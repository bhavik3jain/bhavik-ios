import Core
import CoreData
import SwiftUI

/// Adds a booking — a stay, a car, tickets — or edits one.
struct BookingEditorView: View {
    let trip: SharedTrip
    let booking: SharedBooking?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.tripPersistentContainer) private var container

    @State private var title = ""
    @State private var kind: BookingKind = .lodging
    @State private var provider = ""
    @State private var code = ""
    @State private var hasStart = false
    @State private var startsAt: Date
    @State private var hasEnd = false
    @State private var endsAt: Date
    @State private var contactPhone = ""
    @State private var notes = ""
    @State private var secureNote = ""
    @State private var confirmingDelete = false

    init(trip: SharedTrip, booking: SharedBooking?) {
        self.trip = trip
        self.booking = booking
        _startsAt = State(initialValue: booking?.startsAt ?? trip.startDate)
        _endsAt = State(initialValue: booking?.endsAt ?? trip.endDate)
        if let booking {
            _title = State(initialValue: booking.title)
            _kind = State(initialValue: booking.kind)
            _provider = State(initialValue: booking.provider)
            _code = State(initialValue: booking.code)
            _hasStart = State(initialValue: booking.startsAt != nil)
            _hasEnd = State(initialValue: booking.endsAt != nil)
            _contactPhone = State(initialValue: booking.contactPhone)
            _notes = State(initialValue: booking.notes)
            _secureNote = State(initialValue: booking.secureNote)
        }
    }

    // Gated on the trip, the share's root object — see ItemEditorView's own
    // comment on this same pattern.
    private var canEditShare: Bool {
        guard let container else { return true }
        return SharingStatusResolver.canEdit(trip, in: container)
    }
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty && canEditShare }

    private var words: (start: String, end: String) {
        switch kind {
        case .lodging: ("Check in", "Check out")
        case .car: ("Pick up", "Drop off")
        default: ("Starts", "Ends")
        }
    }

    var body: some View {
        SheetStack {
            Form {
                Section {
                    Picker("Kind", selection: $kind) {
                        ForEach(BookingKind.allCases, id: \.self) { kind in
                            Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                        }
                    }
                    TextField("Name (Hotel de Russie)", text: $title)
                        .textInputAutocapitalization(.words)
                    TextField("With (Avis, Booking.com)", text: $provider)
                        .textInputAutocapitalization(.words)
                }

                Section("Confirmation") {
                    TextField("Code", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }

                Section {
                    Toggle(words.start, isOn: $hasStart.animation())
                    if hasStart {
                        DatePicker(words.start, selection: $startsAt)
                            .labelsHidden()
                    }
                    Toggle(words.end, isOn: $hasEnd.animation())
                    if hasEnd {
                        DatePicker(words.end, selection: $endsAt, in: (hasStart ? startsAt : .distantPast)...)
                            .labelsHidden()
                    }
                } header: {
                    Text("When")
                } footer: {
                    // A booking has real dates and no day of its own; this says
                    // which day of the trip they fall on, the way the item and
                    // flight editors' Day rows do.
                    if hasStart || hasEnd {
                        VStack(alignment: .leading) {
                            if hasStart { Text("\(words.start): \(DayChoice.label(for: startsAt, in: trip.dates))") }
                            if hasEnd { Text("\(words.end): \(DayChoice.label(for: endsAt, in: trip.dates))") }
                        }
                    }
                }

                Section("Details") {
                    TextField("Phone", text: $contactPhone)
                        .keyboardType(.phonePad)
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    SecureField("Door code, key safe PIN", text: $secureNote)
                        .font(.body.monospaced())
                } header: {
                    Text("Private")
                } footer: {
                    Text("Encrypted in iCloud, hidden until you tap Show, and never written into the shared PDF.")
                }

                if booking != nil, canEditShare {
                    Section {
                        Button("Delete Booking", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(booking == nil ? "Add Booking" : "Edit Booking")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(booking == nil ? "Add" : "Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onChange(of: startsAt) { old, new in
                // Keep the stay's length when check-in moves, as the flight
                // editor does for a departure: the usual edit is moving the
                // whole booking, and a check-out left behind could end up
                // before its own check-in.
                guard hasEnd else { return }
                endsAt = endsAt.addingTimeInterval(new.timeIntervalSince(old))
            }
            .confirmationDialog("Delete \(title)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let booking {
                        modelContext.delete(booking)
                        try? modelContext.saveIfNeeded()
                    }
                    dismiss()
                }
            }
        }
    }

    private func save() {
        let target = booking ?? SharedBooking(context: modelContext, title: "", kind: kind)
        if booking == nil {
            target.sortOrder = ((trip.bookings ?? []).map(\.sortOrder).max() ?? -1) + 1
        }
        target.title = title.trimmingCharacters(in: .whitespaces)
        target.kind = kind
        target.provider = provider.trimmingCharacters(in: .whitespaces)
        target.code = code.trimmingCharacters(in: .whitespaces)
        target.startsAt = hasStart ? startsAt : nil
        target.endsAt = hasEnd ? endsAt : nil
        target.contactPhone = contactPhone
        target.notes = notes
        target.secureNote = secureNote
        if booking == nil {
            target.trip = trip
        }
        try? modelContext.saveIfNeeded()
        dismiss()
    }
}

import Core
import CoreData
import SwiftUI

/// Adds a flight to the trip, or edits one. Entered by hand: no flight-status
/// service is wired in.
struct FlightEditorView: View {
    let trip: SharedTrip
    let flight: SharedFlight?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var modelContext
    @Environment(\.tripPersistentContainer) private var container

    @State private var airlineCode = ""
    @State private var number = ""
    @State private var originCode = ""
    @State private var destinationCode = ""
    @State private var hasTimes = false
    @State private var departsAt: Date
    @State private var arrivesAt: Date
    @State private var seat = ""
    @State private var terminal = ""
    @State private var confirmationCode = ""
    @State private var day: Int
    @State private var notes = ""
    @State private var confirmingDelete = false
    /// Set while the Day picker carries the times along, so the departure's
    /// own `onChange` doesn't take that for a hand edit and move the day again.
    @State private var movingWithDay = false

    init(trip: SharedTrip, flight: SharedFlight?, day: Int) {
        self.trip = trip
        self.flight = flight
        let dates = trip.dates
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: dates.date(forDay: day)) ?? dates.date(forDay: day)
        _day = State(initialValue: day)
        _departsAt = State(initialValue: flight?.departsAt ?? noon)
        _arrivesAt = State(initialValue: flight?.arrivesAt ?? flight?.departsAt?.addingTimeInterval(2 * 3600) ?? noon.addingTimeInterval(2 * 3600))
        if let flight {
            _airlineCode = State(initialValue: flight.airlineCode)
            _number = State(initialValue: flight.number)
            _originCode = State(initialValue: flight.originCode)
            _destinationCode = State(initialValue: flight.destinationCode)
            _hasTimes = State(initialValue: flight.departsAt != nil)
            _seat = State(initialValue: flight.seat)
            _terminal = State(initialValue: flight.terminal)
            _confirmationCode = State(initialValue: flight.confirmationCode)
            _notes = State(initialValue: flight.notes)
        }
    }

    // Gated on the trip, the share's root object — see ItemEditorView's own
    // comment on this same pattern.
    private var canEditShare: Bool {
        guard let container else { return true }
        return SharingStatusResolver.canEdit(trip, in: container)
    }
    private var canSave: Bool {
        !(airlineCode + number + originCode + destinationCode).trimmingCharacters(in: .whitespaces).isEmpty && canEditShare
    }

    var body: some View {
        SheetStack {
            Form {
                Section("Flight") {
                    HStack {
                        TextField("Airline (BA)", text: $airlineCode)
                        TextField("Number (286)", text: $number)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    HStack {
                        TextField("From (FCO)", text: $originCode)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        TextField("To (LHR)", text: $destinationCode)
                    }
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                }

                Section {
                    // A flight is always on a day: it has no Unassigned.
                    DayPicker(
                        dates: trip.dates,
                        selection: Binding { DayChoice.day(day) } set: { moveTimes(toDay: $0.dayIndex) },
                        includesUnassigned: false
                    )
                    Toggle("Set times", isOn: $hasTimes.animation())
                    if hasTimes {
                        DatePicker("Departs", selection: $departsAt)
                        DatePicker("Arrives", selection: $arrivesAt, in: departsAt...)
                    }
                } header: {
                    Text("When")
                } footer: {
                    Text("Times are as printed on the booking, in the phone's time zone.")
                }

                Section("Booking") {
                    TextField("Confirmation code", text: $confirmationCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    TextField("Seat", text: $seat)
                        .textInputAutocapitalization(.characters)
                    TextField("Terminal", text: $terminal)
                        .textInputAutocapitalization(.characters)
                    TextField("Notes", text: $notes, axis: .vertical)
                }

                if flight != nil, canEditShare {
                    Section {
                        Button("Delete Flight", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(flight == nil ? "Add Flight" : "Edit Flight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(flight == nil ? "Add" : "Save", action: save)
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onChange(of: departsAt) { old, new in
                if movingWithDay {
                    movingWithDay = false
                    return
                }
                // Keep the flight's length when the departure moves, and follow
                // it onto its day — the usual edit is fixing the date.
                arrivesAt = arrivesAt.addingTimeInterval(new.timeIntervalSince(old))
                if let index = trip.dates.dayIndex(of: new) { day = index }
            }
            .confirmationDialog("Delete this flight?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let flight {
                        modelContext.delete(flight)
                        try? modelContext.saveIfNeeded()
                    }
                    dismiss()
                }
            }
        }
    }

    /// Picking another day moves the times by as many days. Changing only the
    /// day used to leave `departsAt` on the old date, so the timeline and the
    /// next-flight card, Codes and the PDF disagreed about when the flight was.
    /// A shift rather than a snap, for the reason on `SharedFlight.move(toDay:shiftingTimesBy:calendar:)`.
    private func moveTimes(toDay index: Int) {
        let days = index - day
        day = index
        guard days != 0 else { return }
        let calendar = trip.dates.calendar
        movingWithDay = true
        departsAt = calendar.date(byAdding: .day, value: days, to: departsAt) ?? departsAt
        arrivesAt = calendar.date(byAdding: .day, value: days, to: arrivesAt) ?? arrivesAt
    }

    private func save() {
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces).uppercased() }
        let target = flight ?? SharedFlight(context: modelContext, airlineCode: "", number: "", originCode: "", destinationCode: "", dayIndex: day)
        target.airlineCode = clean(airlineCode)
        target.number = number.trimmingCharacters(in: .whitespaces)
        target.originCode = clean(originCode)
        target.destinationCode = clean(destinationCode)
        target.departsAt = hasTimes ? departsAt : nil
        target.arrivesAt = hasTimes ? arrivesAt : nil
        target.seat = clean(seat)
        target.terminal = terminal.trimmingCharacters(in: .whitespaces)
        target.confirmationCode = clean(confirmationCode)
        target.dayIndex = day
        target.notes = notes
        if flight == nil {
            target.trip = trip
        }
        try? modelContext.saveIfNeeded()
        dismiss()
    }
}

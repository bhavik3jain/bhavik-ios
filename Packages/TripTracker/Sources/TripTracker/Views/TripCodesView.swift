import Core // Only reached on macOS, where Core stands in for the iOS-only UIPasteboard below.
import CoreData
import SwiftUI

/// Every confirmation code this trip holds, one tap from the clipboard.
struct TripCodesView: View {
    let trip: Trip
    let present: (TripSheet) -> Void

    @Environment(\.managedObjectContext) private var modelContext
    /// The code last copied, so its row can say so for a moment.
    @State private var copied: String?
    @State private var revealed: Set<NSManagedObjectID> = []

    private var flights: [Flight] {
        let dates = trip.dates
        return (trip.flights ?? []).sorted {
            ($0.departsAt ?? dates.date(forDay: $0.dayIndex)) < ($1.departsAt ?? dates.date(forDay: $1.dayIndex))
        }
    }

    private var groups: [BookingGroups.Group] {
        BookingGroups.ordered(Array(trip.bookings ?? []))
    }

    private var secured: [Booking] {
        groups.flatMap(\.bookings).filter { !$0.secureNote.isEmpty }
    }

    var body: some View {
        if flights.isEmpty && groups.isEmpty {
            ContentUnavailableView {
                Label("No codes yet", systemImage: "ticket")
            } description: {
                Text("Booking references for this trip's flights, stays and cars live here, one tap from the clipboard.")
            } actions: {
                Button("Add Booking") { present(.newBooking) }
                Button("Add Flight") { present(.newFlight(day: 0)) }
            }
        } else {
            List {
                if !flights.isEmpty {
                    Section("Flights") {
                        ForEach(flights) { flight in
                            CodeRow(
                                title: flight.headline,
                                detail: ItineraryFormat.flightWhen(flight, dates: trip.dates) + " · Day \(flight.dayIndex + 1)",
                                code: flight.confirmationCode,
                                symbolName: "airplane",
                                isCopied: copied == flight.confirmationCode && !flight.confirmationCode.isEmpty,
                                copy: { copy(flight.confirmationCode) }
                            )
                            .contextMenu {
                                editButton { present(.flight(flight)) }
                                deleteButton { delete(flight) }
                            }
                            .swipeActions {
                                deleteButton { delete(flight) }
                                editButton { present(.flight(flight)) }
                            }
                        }
                    }
                }

                ForEach(groups, id: \.kind) { group in
                    Section(group.kind.displayName) {
                        ForEach(group.bookings) { booking in
                            CodeRow(
                                title: booking.title,
                                detail: ItineraryFormat.bookingDetail(booking),
                                code: booking.code,
                                symbolName: booking.kind.symbolName,
                                isCopied: copied == booking.code && !booking.code.isEmpty,
                                copy: { copy(booking.code) }
                            )
                            .contextMenu {
                                editButton { present(.booking(booking)) }
                                deleteButton { delete(booking) }
                            }
                            .swipeActions {
                                deleteButton { delete(booking) }
                                editButton { present(.booking(booking)) }
                            }
                        }
                    }
                }

                ForEach(secured) { booking in
                    Section {
                        secureRow(booking)
                    } header: {
                        Text("\(booking.kind == .lodging ? "Door code" : "Private") · \(booking.title)")
                    } footer: {
                        Text("Encrypted in iCloud, and never written into the shared PDF.")
                    }
                }
            }
        }
    }

    private func secureRow(_ booking: Booking) -> some View {
        let isRevealed = revealed.contains(booking.objectID)
        return HStack {
            Text(isRevealed ? booking.secureNote : String(repeating: "•", count: 6))
                .font(.body.monospaced())
                .fontWeight(.semibold)
                .textSelection(.enabled)
            Spacer()
            Button(isRevealed ? "Hide" : "Show") {
                if isRevealed {
                    revealed.remove(booking.objectID)
                } else {
                    revealed.insert(booking.objectID)
                }
            }
            .buttonStyle(.bordered)
            if isRevealed {
                Button {
                    copy(booking.secureNote)
                } label: {
                    Image(systemName: copied == booking.secureNote ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Copy")
            }
        }
    }

    private func editButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Edit", systemImage: "pencil")
        }
        .tint(.gray)
    }

    private func deleteButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Label("Delete", systemImage: "trash")
        }
    }

    private func delete(_ object: NSManagedObject) {
        modelContext.delete(object)
        try? modelContext.saveIfNeeded()
    }

    private func copy(_ code: String) {
        guard !code.isEmpty else { return }
        UIPasteboard.general.string = code
        withAnimation { copied = code }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == code {
                withAnimation { copied = nil }
            }
        }
    }
}

struct CodeRow: View {
    let title: String
    let detail: String
    let code: String
    let symbolName: String
    let isCopied: Bool
    let copy: () -> Void

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 12) {
                Image(systemName: symbolName)
                    .foregroundStyle(TripTrackerModule.accent.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fontWeight(.semibold)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(code.isEmpty ? "No code" : code)
                        .font(.body.monospaced())
                        .fontWeight(.semibold)
                        .foregroundStyle(code.isEmpty ? .secondary : .primary)
                    if !code.isEmpty {
                        Text(isCopied ? "Copied" : "Copy")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(isCopied ? AnyShapeStyle(.green) : AnyShapeStyle(TripTrackerModule.accent.color))
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(code.isEmpty)
        .accessibilityHint(code.isEmpty ? "" : "Copies the code")
    }
}

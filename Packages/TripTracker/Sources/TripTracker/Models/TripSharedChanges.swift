import Core
import CoreData
import Foundation

public extension TripTrackerModule {
    /// Trips' wording for Core's shared-change notifications — see
    /// `SharedChangeNotifier`, which `BhavikApp` hands this to. The root is
    /// always the trip; `nil` for anything that has come loose from one.
    static func describeSharedChange(_ object: NSManagedObject, _ change: SharedObjectChange) -> SharedChangeDescription? {
        let inserted = change.kind == .inserted
        switch object {
        case let trip as SharedTrip:
            // The first expense on a trip with no currency sets the trip's
            // too, and the partner got "updated Rome" beside "added Dinner
            // (€236.40)" for a change they never made. A switch from Split's
            // Trip Currency menu only steers new expenses, so it says nothing
            // either.
            if !inserted, !change.updatedProperties.isEmpty, change.updatedProperties.isSubset(of: ["currencyCode"]) {
                return nil
            }
            let action: String
            if inserted {
                action = "shared \(TripSharedChangeWording.title(of: trip))"
            } else if change.updatedProperties.contains("startDate") || change.updatedProperties.contains("endDate") {
                action = "changed the dates of \(TripSharedChangeWording.title(of: trip))"
            } else if change.updatedProperties.contains("title") {
                action = "renamed a trip to \(TripSharedChangeWording.title(of: trip))"
            } else {
                action = "updated \(TripSharedChangeWording.title(of: trip))"
            }
            return TripSharedChangeWording.description(trip, action)

        case let item as SharedItineraryItem:
            guard let trip = item.trip else { return nil }
            let name = TripSharedChangeWording.name(item.title, fallback: "a plan")
            let day = TripSharedChangeWording.day(item.dayIndex)
            let action: String
            if inserted {
                action = "added \(name)\(day.map { " to \($0)" } ?? "")"
            } else if change.updatedProperties.contains("isDone") {
                action = item.isDone ? "ticked off \(name)" : "unticked \(name)"
            } else if change.updatedProperties.contains("dayIndex"), let day {
                action = "moved \(name) to \(day)"
            } else {
                action = "changed \(name)"
            }
            return TripSharedChangeWording.description(trip, action)

        case let flight as SharedFlight:
            guard let trip = flight.trip else { return nil }
            let designator = "\(flight.airlineCode)\(flight.number)"
            let name = designator.isEmpty ? "a flight" : "flight \(designator)"
            return TripSharedChangeWording.description(trip, inserted ? "added \(name)" : "changed \(name)")

        case let booking as SharedBooking:
            guard let trip = booking.trip else { return nil }
            // The title only — never the notes or the secure note, which may
            // hold a door code.
            let name = TripSharedChangeWording.name(booking.title, fallback: "a booking")
            return TripSharedChangeWording.description(trip, inserted ? "added \(name)" : "changed \(name)")

        case let expense as SharedTripExpense:
            guard let trip = expense.trip else { return nil }
            return TripSharedChangeWording.description(trip, TripSharedChangeWording.action(for: expense, change))

        case let person as SharedTripPerson:
            // A participant's snapshot row is bookkeeping (written the first
            // time they're in an expense); a manual person's later edits —
            // hiding, linking — say nothing either.
            guard let trip = person.trip, inserted, person.kind == .manual else { return nil }
            let name = TripSharedChangeWording.name(person.name, fallback: "someone")
            return TripSharedChangeWording.description(trip, "added \(name) to the split")

        default:
            return nil
        }
    }
}

enum TripSharedChangeWording {
    static func description(_ trip: SharedTrip, _ action: String) -> SharedChangeDescription {
        SharedChangeDescription(rootID: trip.objectID, rootTitle: title(of: trip), action: action)
    }

    static func title(of trip: SharedTrip) -> String {
        name(trip.title, fallback: name(trip.destination, fallback: "a trip"))
    }

    static func name(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// An expense's or payment's wording. The title and amount only — never
    /// the note, and never who owes whom.
    static func action(for expense: SharedTripExpense, _ change: SharedObjectChange) -> String {
        let amount = TripMoney.format(expense.amountMinor, code: expense.resolvedCurrencyCode())
        let amountChanged = !change.updatedProperties.isDisjoint(with: ["amountMinor", "currencyCode"])
        if expense.isPayment {
            switch change.kind {
            case .inserted: return "recorded a \(amount) payment"
            case .deleted: return "deleted a \(amount) payment"
            case .updated: return amountChanged ? "changed a payment to \(amount)" : "changed a \(amount) payment"
            }
        }
        let name = TripSharedChangeWording.name(expense.title, fallback: "an expense")
        switch change.kind {
        case .inserted: return "added \(name) (\(amount))"
        case .deleted: return "deleted \(name)"
        case .updated: return amountChanged ? "changed \(name) to \(amount)" : "changed \(name)"
        }
    }

    /// "Day 3" for the third day. Nothing for an item on no day at all.
    static func day(_ index: Int) -> String? {
        index >= 0 ? "Day \(index + 1)" : nil
    }
}

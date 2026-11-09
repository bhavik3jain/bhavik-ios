import CoreData
import Foundation

public extension SharedTrip {
    /// The Split face's currency for new expenses: the trip's, else the
    /// locale's.
    func defaultCurrencyCode(locale: Locale = .current) -> String {
        TripMoney.resolvedCode(currencyCode, locale: locale)
    }

    var personRecords: [PersonRecord] {
        (people ?? []).map(\.record)
    }

    func expenseRecords(locale: Locale = .current) -> [ExpenseRecord] {
        (expenses ?? []).map { $0.record(locale: locale) }
    }

    /// The ledger for this trip as `people` resolves names and links.
    func ledger(people: TripPeople, locale: Locale = .current) -> TripLedger {
        TripLedger(expenses: expenseRecords(locale: locale), people: people)
    }

    /// Writes the participant snapshot rows a saved expense calls for (see
    /// `TripPeople.participantRowChanges`) — only for someone with edit
    /// access, whose save goes through anyway; a view-only participant never
    /// writes, and their roster still names everyone from the cached share.
    /// The caller saves. Returns how many rows it touched.
    @discardableResult
    func recordParticipants(of expense: SharedTripExpense, share: ShareSnapshot?, asOf now: Date = .now) -> Int {
        let keys = [expense.payer] + expense.split.keys
        let changes = TripPeople.participantRowChanges(for: keys, share: share, rows: personRecords)
        applyParticipantRowChanges(changes, asOf: now)
        return changes.count
    }

    func applyParticipantRowChanges(_ changes: [TripPeople.ParticipantRowChange], asOf now: Date = .now) {
        guard let context = managedObjectContext, !changes.isEmpty else { return }
        for change in changes {
            if change.isNew {
                let row = SharedTripPerson(context: context, key: change.key, name: change.name, kind: .participant, asOf: now)
                row.trip = self
            } else {
                // Every copy, in case two devices each wrote one.
                for row in people ?? [] where row.key == change.key {
                    row.name = change.name
                    row.updatedAt = now
                }
            }
        }
    }
}

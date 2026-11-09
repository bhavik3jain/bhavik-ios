import CoreData
import Foundation

/// An expense on a trip, or a payment between two of its people
/// (`kindRaw == "payment"`). Backed by Core Data like every other trip child,
/// so a shared trip carries it; created with `expense.trip = trip`, which puts
/// it in the trip's own store. See `TripModel.swift` for why initializers go
/// through `NSEntityDescription.entity(forEntityName:in:)`.
///
/// Money is `Int64` minor units in `currencyCode` — never a `Double`, which
/// can't hold 0.10 exactly and drifted a cent across a split. Only the split's
/// *rule* is stored (`splitModeRaw` + `splitEncoded`); each person's cents are
/// recomputed by `ExpenseSplit.allocate(total:)` every time, so stored data can
/// never disagree with itself.
@objc(SharedTripExpense)
public final class SharedTripExpense: NSManagedObject, Identifiable {
    /// "Dinner at Ramiro".
    @NSManaged public var title: String
    @NSManaged public var amountMinor: Int64
    /// ISO code. "" means the trip's own (`SharedTrip.currencyCode`).
    @NSManaged public var currencyCode: String
    /// A `PersonKey`'s raw value.
    @NSManaged public var payerKey: String
    @NSManaged public var kindRaw: String
    @NSManaged public var categoryRaw: String
    @NSManaged public var splitModeRaw: String
    /// `ExpenseSplit.encoded`: `[{"k":"owner","v":1},…]`.
    @NSManaged public var splitEncoded: String
    /// Encrypted end to end (`TripModel.make()`), and never in a notification.
    @NSManaged public var note: String
    /// When it was spent. Nil reads as `createdAt` — see `date`.
    @NSManaged public var spentAt: Date?
    @NSManaged public var createdAt: Date?
    @NSManaged public var updatedAt: Date?

    @NSManaged public var trip: SharedTrip?

    public convenience init(
        context: NSManagedObjectContext,
        title: String,
        amountMinor: Int64,
        currencyCode: String,
        payer: PersonKey,
        split: ExpenseSplit,
        kind: ExpenseKind = .expense,
        category: ExpenseCategory = .other,
        spentAt: Date = .now,
        asOf now: Date = .now
    ) {
        let entity = NSEntityDescription.entity(forEntityName: TripModel.EntityName.expense, in: context)!
        self.init(entity: entity, insertInto: context)
        self.title = title
        self.amountMinor = amountMinor
        self.currencyCode = currencyCode
        self.payerKey = payer.raw
        self.kindRaw = kind.rawValue
        self.categoryRaw = category.rawValue
        self.split = split
        self.spentAt = spentAt
        self.createdAt = now
        self.updatedAt = now
    }

    @nonobjc public static func fetchRequest(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = []
    ) -> NSFetchRequest<SharedTripExpense> {
        let request = NSFetchRequest<SharedTripExpense>(entityName: TripModel.EntityName.expense)
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        return request
    }
}

public extension SharedTripExpense {
    var id: NSManagedObjectID { objectID }

    var kind: ExpenseKind {
        get { ExpenseKind(rawValue: kindRaw) ?? .expense }
        set { kindRaw = newValue.rawValue }
    }

    var isPayment: Bool { kind == .payment }

    var category: ExpenseCategory {
        get { ExpenseCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var payer: PersonKey {
        get { PersonKey(payerKey) }
        set { payerKey = newValue.raw }
    }

    /// The stored rule, decoded defensively: garbage reads as an equal split
    /// over whatever keys could be read. Setting it writes mode and entries
    /// together.
    var split: ExpenseSplit {
        get { ExpenseSplit.decode(splitEncoded, mode: ExpenseSplitMode(rawValue: splitModeRaw) ?? .equal) }
        set {
            splitModeRaw = newValue.mode.rawValue
            splitEncoded = newValue.encoded
        }
    }

    /// When it counts: `spentAt`, else when it was entered.
    var date: Date { spentAt ?? createdAt ?? .distantPast }

    /// This expense's currency, falling back to the trip's, then the locale's.
    func resolvedCurrencyCode(locale: Locale = .current) -> String {
        TripMoney.resolvedCode(currencyCode, tripCode: trip?.currencyCode ?? "", locale: locale)
    }

    /// The plain value the ledger and the rows work from.
    func record(locale: Locale = .current) -> ExpenseRecord {
        ExpenseRecord(
            id: objectID.uriRepresentation().absoluteString,
            title: title,
            amountMinor: amountMinor,
            currencyCode: resolvedCurrencyCode(locale: locale),
            payer: payer,
            kind: kind,
            category: category,
            split: split,
            date: date
        )
    }
}

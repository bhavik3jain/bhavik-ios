import CloudKit
import Core
import CoreData
import Observation
import SwiftUI

/// The Split face's fetches. Fetched rather than read off `trip.expenses`:
/// editing an expense's amount changes the expense, which the trip — the only
/// object the face would otherwise watch — never hears about, the same reason
/// Ideas fetches its items.
enum SplitFetch {
    static func expenses(of trip: SharedTrip) -> NSFetchRequest<SharedTripExpense> {
        SharedTripExpense.fetchRequest(
            predicate: NSPredicate(format: "trip == %@", trip),
            sortDescriptors: [NSSortDescriptor(keyPath: \SharedTripExpense.spentAt, ascending: false)]
        )
    }

    static func people(of trip: SharedTrip) -> NSFetchRequest<SharedTripPerson> {
        SharedTripPerson.fetchRequest(
            predicate: NSPredicate(format: "trip == %@", trip),
            sortDescriptors: [NSSortDescriptor(keyPath: \SharedTripPerson.sortOrder, ascending: true)]
        )
    }
}

/// Everything the Split face draws from, worked out once per redraw: the
/// share as this device knows it, who's who, and the ledger.
@MainActor
struct SplitSnapshot {
    let share: TripShareState
    let people: TripPeople
    let records: [ExpenseRecord]
    let ledger: TripLedger
    /// Each record's object, by `ExpenseRecord.id`.
    let objects: [String: SharedTripExpense]
    var wording: SplitWording { SplitWording(people: people) }

    static func make(
        trip: SharedTrip,
        container: NSPersistentCloudKitContainer?,
        expenses: some Sequence<SharedTripExpense>,
        rows: some Sequence<SharedTripPerson>
    ) -> SplitSnapshot {
        let (share, people) = people(of: trip, in: container, rows: rows.map(\.record))
        var objects: [String: SharedTripExpense] = [:]
        var records: [ExpenseRecord] = []
        // An orphan (its trip deleted on an older build) is already filtered
        // by the fetch's predicate; a deleted object can linger in a fetch
        // result for a pass, and reading it would fault.
        for expense in expenses where !expense.isDeleted && expense.managedObjectContext != nil {
            let record = expense.record()
            records.append(record)
            objects[record.id] = expense
        }
        return SplitSnapshot(
            share: share,
            people: people,
            records: records,
            ledger: TripLedger(expenses: records, people: people),
            objects: objects
        )
    }

    /// The share as this device knows it, and the trip's people from it and
    /// `rows`.
    static func people(
        of trip: SharedTrip,
        in container: NSPersistentCloudKitContainer?,
        rows: [PersonRecord]
    ) -> (TripShareState, TripPeople) {
        let share = shareState(of: trip, in: container)
        let me: PersonKey? = container.map {
            TripPeople.currentUserKey(share, isInSharedStore: TripShareState.isInSharedStore(trip, in: $0))
        } ?? .owner
        return (share, TripPeople(share: share, rows: rows, me: me))
    }

    /// The share from `SharingStatusCache`, never a lookup on the main thread:
    /// a synchronous `fetchShares` waits on the container's executor, which
    /// is how TestFlight build 16 deadlocked on Share. The cache starts its
    /// own lookup off the main thread when one is due, and the face redraws
    /// when it lands.
    static func shareState(of trip: SharedTrip, in container: NSPersistentCloudKitContainer?) -> TripShareState {
        guard let container else { return .notShared }
        let name = TripShareState.isInSharedStore(trip, in: container) ? CurrentUserRecord.shared.recordName(for: container) : nil
        return TripShareState.current(for: trip, in: container, currentUserRecordName: name)
    }
}

/// This device's iCloud user record name, for telling who "you" are on a
/// trip someone else shared (spec R1): CloudKit may name a participant's own
/// record `__defaultOwner__` on their own device, and then only this answer
/// gives them their `ck:` key. Never needed for the owner, who is `owner` by
/// role. Kept in UserDefaults once known, so it's there offline and at once
/// on the next launch; until it is, the face shows no "you" figures rather
/// than guess.
@MainActor
@Observable
final class CurrentUserRecord {
    static let shared = CurrentUserRecord()

    private var names: [String: String] = UserDefaults.standard.dictionary(forKey: CurrentUserRecord.defaultsKey) as? [String: String] ?? [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    /// When each container's last ask failed. With no iCloud account, a
    /// restricted one or no network, a failed ask used to be forgotten, so
    /// every redraw of the Split face, its Mac subtitle, the editor or the
    /// People sheet fired another CloudKit request, with no backoff.
    @ObservationIgnored private var failedAt: [String: Date] = [:]
    static let retryAfter: TimeInterval = 60

    static let defaultsKey = "TripSplit.currentUserRecordName"

    /// The answer for `container`'s iCloud container, if known; otherwise
    /// starts asking (a CloudKit call, not one of the persistent container's
    /// sharing calls, so it never waits on its executor) and the view
    /// redraws when it lands.
    func recordName(for container: NSPersistentCloudKitContainer) -> String? {
        guard let identifier = container.persistentStoreDescriptions
            .lazy.compactMap({ $0.cloudKitContainerOptions?.containerIdentifier }).first
        else { return nil }
        if let name = names[identifier] { return name }
        if let failed = failedAt[identifier], Date.now.timeIntervalSince(failed) < Self.retryAfter { return nil }
        guard inFlight.insert(identifier).inserted else { return nil }
        Task { @MainActor in
            let name = try? await CKContainer(identifier: identifier).userRecordID().recordName
            self.inFlight.remove(identifier)
            guard let name, !name.isEmpty, name != CKCurrentUserDefaultName else {
                self.failedAt[identifier] = .now
                return
            }
            self.failedAt[identifier] = nil
            self.names[identifier] = name
            UserDefaults.standard.set(self.names, forKey: Self.defaultsKey)
        }
        return nil
    }
}

/// What the Record Payment form opens with — a suggested transfer, or
/// nothing filled in.
struct PaymentPrefill: Hashable {
    var from: PersonKey?
    var to: PersonKey?
    var amountMinor: Int64 = 0
    var currencyCode: String = ""

    init(from: PersonKey? = nil, to: PersonKey? = nil, amountMinor: Int64 = 0, currencyCode: String = "") {
        self.from = from
        self.to = to
        self.amountMinor = amountMinor
        self.currencyCode = currencyCode
    }

    init(_ transfer: SettleUp.Transfer) {
        self.init(from: transfer.from, to: transfer.to, amountMinor: transfer.amountMinor, currencyCode: transfer.currencyCode)
    }

    var id: String { "\(from?.raw ?? "")>\(to?.raw ?? ""):\(amountMinor)\(currencyCode)" }
}

/// A small "iCloud" / "Left" / "Hidden" mark beside a person's name.
struct PersonBadge: View {
    let person: TripPerson

    var body: some View {
        switch person.source {
        case .iCloud:
            Image(systemName: "icloud")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("On iCloud")
        case .left:
            tag("Left")
        case .manual where person.isHidden:
            tag("Hidden")
        case .manual, .pending:
            EmptyView()
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.secondary.opacity(0.15), in: Capsule())
    }
}

/// A money field: the figure as typed, a decimal pad, and the currency menu
/// beside it.
struct MoneyField: View {
    let title: String
    @Binding var text: String
    @Binding var currencyCode: String
    var allowsCurrencyChange = true

    var body: some View {
        HStack {
            TextField(title, text: $text)
                .keyboardType(.decimalPad)
                .font(.title2.weight(.semibold).monospacedDigit())
            if allowsCurrencyChange {
                Picker("Currency", selection: $currencyCode) {
                    ForEach(codes, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                Text(currencyCode).foregroundStyle(.secondary)
            }
        }
    }

    /// The menu's codes, with the one in use kept even if it isn't common.
    private var codes: [String] {
        let menu = TripMoney.menuCodes()
        return menu.contains(currencyCode) ? menu : [currencyCode] + menu
    }
}

import CoreData
import Foundation

/// Folds together the duplicates CloudKit sync leaves behind, and merges one
/// household into another.
///
/// Nothing in CloudKit is unique, so two devices can each make "the same"
/// thing before either has seen the other's:
///
/// - **Two private households.** A second device that opened Finance before
///   its first iCloud import minted a household of its own. Once the first
///   device's arrived, `FinanceHouseholdResolver` showed the oldest and the
///   newer one — with whatever had been typed into it — was hidden for good.
/// - **Two months of one `yearMonth`.** Both devices tapped + for October
///   while offline. The Months list then had two rows with the same ID, and
///   each held half of what had been typed.
///
/// Every fold keeps the **oldest** (by `createdAt`) and moves what the newer
/// one holds onto it, so two devices folding at once reach the same answer:
/// both keep the same survivor, both re-point the same children at it, and
/// both delete the same emptied duplicate — CloudKit sees the same edits
/// twice rather than two competing ones. Children that collide on their
/// natural key (a balance for the same account, a budget for the same
/// category) are resolved by their content first and then by `Tiebreak`,
/// which is the same on every device. Were each device to keep a different
/// one of an identical pair, each would delete the other's keeper and the
/// pair would vanish.
///
/// Every function is idempotent: run twice, the second run finds nothing to
/// do and returns `false`, so the caller only saves when something moved.
public enum FinanceFold {
    // MARK: - Ordering

    /// Tells apart two rows that are otherwise alike, the same way on every
    /// device. Local object IDs can't: each device numbers the rows it
    /// imports in its own order.
    public struct Tiebreak {
        let recordName: (NSManagedObject) -> String?

        public init(recordName: @escaping (NSManagedObject) -> String?) {
            self.recordName = recordName
        }

        /// Local object IDs only — for tests and in-memory stores, which
        /// have no CloudKit records and only ever one device.
        public static var local: Tiebreak { Tiebreak { _ in nil } }

        /// Each row's CloudKit record name, which every device shares,
        /// falling back to the local object ID for a row not yet exported.
        @MainActor
        public static func cloudKit(_ container: NSPersistentCloudKitContainer?) -> Tiebreak {
            guard let container else { return .local }
            return Tiebreak { container.recordID(for: $0.objectID)?.recordName }
        }

        func key(_ object: NSManagedObject) -> String {
            recordName(object) ?? object.objectID.uriRepresentation().absoluteString
        }

        /// Oldest first — the order every fold keeps the first of. `createdAt`
        /// ties would need two devices to create a row in the same millisecond
        /// — or a merge to have copied one row twice (see `sameInstant`).
        func survivorOrder(_ lhs: NSManagedObject, _ lhsCreated: Date, _ rhs: NSManagedObject, _ rhsCreated: Date) -> Bool {
            if !FinanceFold.sameInstant(lhsCreated, rhsCreated) { return lhsCreated < rhsCreated }
            return key(lhs) < key(rhs)
        }

        func months(_ lhs: SharedFinanceMonth, _ rhs: SharedFinanceMonth) -> Bool {
            survivorOrder(lhs, lhs.createdAt, rhs, rhs.createdAt)
        }

        func households(_ lhs: SharedFinanceHousehold, _ rhs: SharedFinanceHousehold) -> Bool {
            survivorOrder(lhs, lhs.createdAt, rhs, rhs.createdAt)
        }

        /// By account, then a typed-in figure before a copied-forward one,
        /// then the larger amount, then the record — the first is kept.
        func balances(_ lhs: SharedFinanceBalance, _ rhs: SharedFinanceBalance) -> Bool {
            let left = lhs.account.map(FinanceFold.accountKey) ?? ""
            let right = rhs.account.map(FinanceFold.accountKey) ?? ""
            if left != right { return left < right }
            if lhs.edited != rhs.edited { return lhs.edited }
            if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
            return key(lhs) < key(rhs)
        }

        /// By category, then the larger limit, then the record.
        func budgets(_ lhs: SharedFinanceBudget, _ rhs: SharedFinanceBudget) -> Bool {
            let left = SpendingSummary.key(lhs.category)
            let right = SpendingSummary.key(rhs.category)
            if left != right { return left < right }
            if lhs.limit != rhs.limit { return lhs.limit > rhs.limit }
            return key(lhs) < key(rhs)
        }
    }

    /// One month per `yearMonth` — the one a fold would keep — oldest period
    /// first. What the screens list, so a duplicate that hasn't been folded
    /// yet (or can't be, in a view-only share) never shows twice.
    public static func distinctMonths(_ months: [SharedFinanceMonth], tiebreak: Tiebreak = .local) -> [SharedFinanceMonth] {
        Dictionary(grouping: months, by: \.yearMonth)
            .compactMap { _, group in group.min(by: tiebreak.months) }
            .sorted { $0.yearMonth < $1.yearMonth }
    }

    /// Whether two `createdAt` stamps are one moment. CloudKit keeps dates to
    /// the millisecond, so a row made on this device and its copy synced in
    /// from another differ by up to a millisecond here and not at all there.
    /// Compared exactly, the two devices ordered such a pair differently —
    /// each keeping the one the other deleted.
    static func sameInstant(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 0.001
    }

    // MARK: - Whole store

    /// Whether `tidy` has anything to do: more than one household in the
    /// private store (unless more than one of them is shared, which `tidy`
    /// leaves alone), or an editable household with duplicate people,
    /// accounts or copied items, two months of one `yearMonth`, or a month
    /// with colliding balances or budgets. Cheap enough to work out on every
    /// change, so the root view can fold as soon as a sync brings a
    /// duplicate in.
    @MainActor
    public static func needsTidying(
        households: [SharedFinanceHousehold],
        privateStore: NSPersistentStore?,
        canEdit: (SharedFinanceHousehold) -> Bool = { _ in true },
        isShared: (SharedFinanceHousehold) -> Bool = { _ in false }
    ) -> Bool {
        let present = households.filter { !$0.isDeleted }
        let own = present.filter { privateStore == nil || $0.objectID.persistentStore == privateStore }
        if own.count > 1, own.filter(isShared).count <= 1 { return true }
        return present.contains { household in
            guard canEdit(household) else { return false }
            if hasDuplicateEntities(household) { return true }
            let months = live(household.months)
            return Set(months.map(\.yearMonth)).count != months.count || months.contains(where: hasCollidingChildren)
        }
    }

    /// Folds every newer private household into the oldest, then every
    /// household's duplicate people, accounts, copied items and months.
    /// Households shared with this device are never folded into each other —
    /// they're different people's — and a view-only one is left alone, since
    /// this device can't write to it. Doesn't save. Returns whether anything
    /// changed.
    ///
    /// A private household this person has shared (`isShared`) is always the
    /// one kept, whatever its age: folding it into another deletes the share
    /// root, which ends the share — the partner's copy vanishes, with
    /// anything they hadn't synced yet. That happened when an offline Mac made
    /// a household first and the iPhone then made and shared its own. With
    /// two shared, neither can go, so the households aren't folded at all.
    @MainActor
    @discardableResult
    public static func tidy(
        in context: NSManagedObjectContext,
        privateStore: NSPersistentStore?,
        canEdit: (SharedFinanceHousehold) -> Bool = { _ in true },
        isShared: (SharedFinanceHousehold) -> Bool = { _ in false },
        tiebreak: Tiebreak = .local
    ) -> Bool {
        var changed = false
        let households = ((try? context.fetch(SharedFinanceHousehold.fetchRequest())) ?? [])
            .filter { !$0.isDeleted }
            .sorted(by: tiebreak.households)
        let own = households.filter { privateStore == nil || $0.objectID.persistentStore == privateStore }
        let sharedOwn = Set(own.filter(isShared).map(\.objectID))
        if own.count > 1, sharedOwn.count <= 1 {
            let ordered = own.sorted { lhs, rhs in
                let left = sharedOwn.contains(lhs.objectID), right = sharedOwn.contains(rhs.objectID)
                return left != right ? left : tiebreak.households(lhs, rhs)
            }
            for newer in ordered.dropFirst() {
                merge(newer, into: ordered[0], tiebreak: tiebreak)
                changed = true
            }
        }
        for household in households where !household.isDeleted && canEdit(household) {
            if foldDuplicateEntities(in: household, tiebreak: tiebreak) { changed = true }
            if foldDuplicateMonths(in: household, tiebreak: tiebreak) { changed = true }
        }
        return changed
    }

    // MARK: - People, accounts, items

    /// Folds duplicates within one household: people of one name, accounts
    /// of one display name, category and owner, and gold, silver and charges
    /// that are copies of one another. Returns whether anything changed.
    ///
    /// Merging into a share copies records across stores, and nothing made
    /// that converge: a second device of the same person could merge before
    /// the first one's copies arrived, copying everything again under new
    /// record names; and a merge offered while the share was still importing
    /// copied the default people and same-named accounts beside the
    /// partner's, which then landed too — two "Chase Checking" for one
    /// person, each with a balance, counted twice in net worth.
    ///
    /// People and accounts fold on the merge's own keys (and the importer
    /// already treats same-named ones as one). Gold and silver and charges
    /// fold only when they're also the same moment, which a copy keeps from
    /// its original: two identical coins, or two identical coffees on one
    /// card on one day, typed in by hand are real, and folding those would
    /// silently delete one.
    ///
    /// Each keeps the first in `survivorOrder`, the same on every device.
    /// Balances moved onto a kept account can collide with its own;
    /// `foldDuplicateMonths` resolves those after this.
    @discardableResult
    public static func foldDuplicateEntities(in household: SharedFinanceHousehold, tiebreak: Tiebreak = .local) -> Bool {
        var changed = false

        var ownersByKey: [String: SharedFinanceOwner] = [:]
        for owner in live(household.owners).sorted(by: { tiebreak.survivorOrder($0, $0.createdAt, $1, $1.createdAt) }) {
            let key = FinanceMonthExchange.nameKey(owner.name)
            guard let kept = ownersByKey[key] else {
                ownersByKey[key] = owner
                continue
            }
            // Owner → accounts and metals nullify, so re-point before deleting.
            for account in live(owner.accounts) { account.owner = kept }
            for item in live(owner.metalItems) { item.owner = kept }
            owner.managedObjectContext?.delete(owner)
            changed = true
        }

        var accountsByKey: [String: SharedFinanceAccount] = [:]
        for account in live(household.accounts).sorted(by: { tiebreak.survivorOrder($0, $0.createdAt, $1, $1.createdAt) }) {
            let key = accountKey(account)
            guard let kept = accountsByKey[key] else {
                accountsByKey[key] = account
                continue
            }
            if kept.limit == 0 { kept.limit = account.limit }
            if kept.annualFee == 0 { kept.annualFee = account.annualFee }
            // Account → balances and charges cascade: re-point them first.
            for balance in live(account.balances) { balance.account = kept }
            for transaction in live(account.transactions) { transaction.card = kept }
            account.managedObjectContext?.delete(account)
            changed = true
        }

        let copies = copiedTwice(live(household.metalItems), createdAt: \.createdAt, tiebreak: tiebreak) {
            metalKey($0.name, owner: $0.owner)
        } + copiedTwice(live(household.transactions), createdAt: \.createdAt, tiebreak: tiebreak, key: transactionKey)
        for copy in copies {
            copy.managedObjectContext?.delete(copy)
            changed = true
        }
        return changed
    }

    /// People or accounts that share a key, or items copied twice.
    static func hasDuplicateEntities(_ household: SharedFinanceHousehold) -> Bool {
        let owners = live(household.owners).map { FinanceMonthExchange.nameKey($0.name) }
        if Set(owners).count != owners.count { return true }
        let accounts = live(household.accounts).map(accountKey)
        if Set(accounts).count != accounts.count { return true }
        return !copiedTwice(live(household.metalItems), createdAt: \.createdAt, tiebreak: .local) {
            metalKey($0.name, owner: $0.owner)
        }.isEmpty || !copiedTwice(live(household.transactions), createdAt: \.createdAt, tiebreak: .local, key: transactionKey).isEmpty
    }

    /// The objects to delete so each set sharing `key` and one `createdAt`
    /// moment keeps only its first in `survivorOrder`.
    ///
    /// Scans by time rather than grouping by key, so the key — a date
    /// formatted per charge — is only worked out for objects made within a
    /// millisecond of another, which `needsTidying` can afford on every
    /// render with thousands of charges.
    static func copiedTwice<T: NSManagedObject>(
        _ objects: [T],
        createdAt: (T) -> Date,
        tiebreak: Tiebreak,
        key: (T) -> String
    ) -> [T] {
        let ordered = objects.sorted { createdAt($0) < createdAt($1) }
        var keys: [Int: String] = [:]
        func keyAt(_ index: Int) -> String {
            if let known = keys[index] { return known }
            let made = key(ordered[index])
            keys[index] = made
            return made
        }
        var losers: [T] = []
        var lost = Set<Int>()
        for index in ordered.indices {
            var next = index + 1
            while next < ordered.count, sameInstant(createdAt(ordered[index]), createdAt(ordered[next])) {
                if keyAt(index) == keyAt(next) {
                    let (left, right) = (ordered[index], ordered[next])
                    let loser = tiebreak.survivorOrder(left, createdAt(left), right, createdAt(right)) ? next : index
                    if lost.insert(loser).inserted { losers.append(ordered[loser]) }
                }
                next += 1
            }
        }
        return losers
    }

    // MARK: - Months

    /// Folds each set of months sharing a `yearMonth` into its oldest, then
    /// any month left with two balances for one account or two budgets for
    /// one category. Returns whether anything changed.
    ///
    /// The second half matters because a fold can run before sync has
    /// finished: the kept month's own balances can arrive after the
    /// duplicate's were moved onto it, and a month holding two balances for
    /// one account counts that account twice in net worth. Two devices
    /// typing the first balance for a newly added account do the same.
    @discardableResult
    public static func foldDuplicateMonths(in household: SharedFinanceHousehold, tiebreak: Tiebreak = .local) -> Bool {
        var changed = false
        let groups = Dictionary(grouping: live(household.months), by: \.yearMonth)
        for (_, group) in groups.sorted(by: { $0.key < $1.key }) where group.count > 1 {
            let ordered = group.sorted(by: tiebreak.months)
            let kept = ordered[0]
            for duplicate in ordered.dropFirst() {
                fold(duplicate, into: kept, sameStore: true, tiebreak: tiebreak, account: { $0 })
                duplicate.managedObjectContext?.delete(duplicate)
                changed = true
            }
        }
        for month in live(household.months) where hasCollidingChildren(month) {
            fold(month, into: month, sameStore: true, tiebreak: tiebreak, account: { $0 })
            changed = true
        }
        return changed
    }

    /// Two balances for one account, or two budgets for one category.
    static func hasCollidingChildren(_ month: SharedFinanceMonth) -> Bool {
        let accounts = live(month.balances).compactMap { $0.account?.objectID }
        let categories = live(month.budgets).map { SpendingSummary.key($0.category) }
        return Set(accounts).count != accounts.count || Set(categories).count != categories.count
    }

    /// Moves (or, across stores, copies) `source`'s balances and budgets onto
    /// `target`, and fills in whatever `target` is missing. `source` is left
    /// for the caller to delete.
    ///
    /// Where both have a balance for one account, `target`'s is kept, taking
    /// `source`'s figure only if just that one was typed in — a figure
    /// someone entered beats one copied forward from last month. Where both
    /// have a budget for one category, `target`'s is kept.
    ///
    /// Folding a month into itself is allowed: it's how a month moved
    /// wholesale into another household has its balances re-pointed at the
    /// accounts they were matched to, and how colliding children within one
    /// month are resolved — keeping the first in `Tiebreak` order.
    static func fold(
        _ source: SharedFinanceMonth,
        into target: SharedFinanceMonth,
        sameStore: Bool,
        tiebreak: Tiebreak,
        account mapped: (SharedFinanceAccount) -> SharedFinanceAccount?
    ) {
        if target.goldPricePerOz == 0 { target.goldPricePerOz = source.goldPricePerOz }
        if target.silverPricePerOz == 0 { target.silverPricePerOz = source.silverPricePerOz }
        if target.closedAt == nil { target.closedAt = source.closedAt }

        let isSelf = source == target
        // Processed last-to-first in a self-fold, so each one checked against
        // is still live and the first — the keeper — is never the one
        // deleted. A deleted object stays in its relationships until the
        // context processes changes, which is why every lookup is `live`.
        let balances = live(source.balances).sorted(by: tiebreak.balances)
        for balance in isSelf ? balances.reversed() : balances {
            guard let account = balance.account.flatMap(mapped) else { continue }
            let existing = live(target.balances)
                .filter { $0 != balance && $0.account == account }
                .sorted(by: tiebreak.balances)
                .first
            if let existing, !isSelf || tiebreak.balances(existing, balance) {
                if balance.edited && !existing.edited {
                    existing.amount = balance.amount
                    existing.edited = true
                }
                if sameStore { balance.managedObjectContext?.delete(balance) }
            } else if sameStore {
                balance.account = account
                balance.month = target
            } else {
                _ = SharedFinanceBalance(account: account, month: target, amount: balance.amount, edited: balance.edited)
            }
        }

        let budgets = live(source.budgets).sorted(by: tiebreak.budgets)
        for budget in isSelf ? budgets.reversed() : budgets {
            let key = SpendingSummary.key(budget.category)
            let existing = live(target.budgets)
                .filter { $0 != budget && SpendingSummary.key($0.category) == key }
                .sorted(by: tiebreak.budgets)
                .first
            if let existing, !isSelf || tiebreak.budgets(existing, budget) {
                if sameStore { budget.managedObjectContext?.delete(budget) }
            } else if sameStore {
                budget.month = target
            } else {
                _ = SharedFinanceBudget(category: budget.category, limit: budget.limit, month: target)
            }
        }
    }

    // MARK: - Households

    /// Moves everything in `source` into `target`, then deletes `source`.
    /// Doesn't save.
    ///
    /// Within one store, children are re-pointed rather than copied, so two
    /// devices folding the same pair make the same edits. Across stores —
    /// this person's own household into a partner's share — Core Data can't
    /// move an object, so each one is copied into `target`'s store and the
    /// original goes with `source`.
    ///
    /// Anything `target` already has is matched rather than duplicated, on
    /// the same keys the JSON import uses: people by name; accounts by
    /// display name, category **and owner** (the seed's two "Online
    /// Brokerage - Taxable" accounts are Bhavik's and Saloni's, and folding
    /// them would lose one's balance); metals by name and owner; months by
    /// `yearMonth`; transactions by date, merchant, cost and card — so two
    /// identical charges on one card on one day are kept once, the price the
    /// importer already pays for making re-imports safe.
    public static func merge(_ source: SharedFinanceHousehold, into target: SharedFinanceHousehold, tiebreak: Tiebreak = .local) {
        guard source != target, let context = target.managedObjectContext else { return }
        let temporary = [source, target].filter(\.objectID.isTemporaryID)
        if !temporary.isEmpty { try? context.obtainPermanentIDs(for: temporary) }
        let sameStore = source.objectID.persistentStore == target.objectID.persistentStore

        // People.
        var ownersByKey: [String: SharedFinanceOwner] = [:]
        for owner in target.sortedOwners {
            let key = FinanceMonthExchange.nameKey(owner.name)
            ownersByKey[key] = ownersByKey[key] ?? owner
        }
        var ownerMap: [NSManagedObjectID: SharedFinanceOwner] = [:]
        var nextOwnerSort = ((target.owners ?? []).map(\.sortOrder).max() ?? -1) + 1
        for owner in source.sortedOwners {
            let key = FinanceMonthExchange.nameKey(owner.name)
            if let match = ownersByKey[key] {
                ownerMap[owner.objectID] = match
                continue
            }
            let moved: SharedFinanceOwner
            if sameStore {
                owner.household = target
                moved = owner
            } else {
                moved = SharedFinanceOwner(name: owner.name, kind: owner.kind, household: target)
                moved.createdAt = owner.createdAt
            }
            moved.sortOrder = nextOwnerSort
            nextOwnerSort += 1
            ownersByKey[key] = moved
            ownerMap[owner.objectID] = moved
        }
        func mappedOwner(_ owner: SharedFinanceOwner?) -> SharedFinanceOwner? {
            owner.flatMap { ownerMap[$0.objectID] }
        }

        // Accounts and cards.
        var accountsByKey: [String: SharedFinanceAccount] = [:]
        for account in target.sortedAccounts {
            accountsByKey[accountKey(account)] = accountsByKey[accountKey(account)] ?? account
        }
        var accountMap: [NSManagedObjectID: SharedFinanceAccount] = [:]
        var nextAccountSort = ((target.accounts ?? []).map(\.sortOrder).max() ?? -1) + 1
        for account in source.sortedAccounts {
            let owner = mappedOwner(account.owner)
            let key = accountKey(account.displayName, account.category, owner: owner)
            if let match = accountsByKey[key] {
                if match.limit == 0 { match.limit = account.limit }
                if match.annualFee == 0 { match.annualFee = account.annualFee }
                accountMap[account.objectID] = match
                continue
            }
            let moved: SharedFinanceAccount
            if sameStore {
                account.household = target
                account.owner = owner
                moved = account
            } else {
                moved = SharedFinanceAccount(
                    institution: account.institution,
                    name: account.name,
                    category: account.category,
                    household: target,
                    owner: owner
                )
                moved.limit = account.limit
                moved.annualFee = account.annualFee
                moved.isArchived = account.isArchived
                moved.createdAt = account.createdAt
            }
            moved.sortOrder = nextAccountSort
            nextAccountSort += 1
            accountsByKey[key] = moved
            accountMap[account.objectID] = moved
        }
        // Within one store a balance (or, below, a charge) on an account
        // that wasn't in `source` — which nothing writes — keeps it rather
        // than being dropped; across stores there'd be nothing in `target`
        // to point it at.
        let mappedAccount: (SharedFinanceAccount) -> SharedFinanceAccount? = { account in
            accountMap[account.objectID] ?? (sameStore ? account : nil)
        }

        // Months, with their balances and budgets.
        let months = live(source.months).sorted { lhs, rhs in
            if lhs.yearMonth != rhs.yearMonth { return lhs.yearMonth < rhs.yearMonth }
            return tiebreak.months(lhs, rhs)
        }
        for month in months {
            if let match = live(target.months).filter({ $0.yearMonth == month.yearMonth }).min(by: tiebreak.months) {
                fold(month, into: match, sameStore: sameStore, tiebreak: tiebreak, account: mappedAccount)
            } else if sameStore {
                month.household = target
                fold(month, into: month, sameStore: true, tiebreak: tiebreak, account: mappedAccount)
            } else if let period = month.period {
                let copy = SharedFinanceMonth(period: period, household: target)
                copy.createdAt = month.createdAt
                fold(month, into: copy, sameStore: false, tiebreak: tiebreak, account: mappedAccount)
            }
        }

        // Gold and silver.
        var metalsByKey: [String: SharedFinanceMetalItem] = [:]
        for item in target.sortedMetals {
            let key = metalKey(item.name, owner: item.owner)
            metalsByKey[key] = metalsByKey[key] ?? item
        }
        var nextMetalSort = ((target.metalItems ?? []).map(\.sortOrder).max() ?? -1) + 1
        for item in source.sortedMetals {
            let owner = mappedOwner(item.owner)
            let key = metalKey(item.name, owner: owner)
            guard metalsByKey[key] == nil else { continue }
            let moved: SharedFinanceMetalItem
            if sameStore {
                item.household = target
                item.owner = owner
                moved = item
            } else {
                moved = SharedFinanceMetalItem(name: item.name, metal: item.metal, grams: item.grams, household: target, owner: owner)
                moved.location = item.location
                moved.pricePaidPerOz = item.pricePaidPerOz
                moved.purchaseValue = item.purchaseValue
                moved.manualValue = item.manualValue
                moved.hasManualValue = item.hasManualValue
                moved.createdAt = item.createdAt
            }
            moved.sortOrder = nextMetalSort
            nextMetalSort += 1
            metalsByKey[key] = moved
        }

        // Transactions.
        var seen = Set(live(target.transactions).map(transactionKey))
        for transaction in live(source.transactions).sorted(by: FinanceMonthExchange.exportOrder) {
            let card = transaction.card.flatMap(mappedAccount)
            let key = FinanceMonthExchange.transactionKey(
                day: FinanceCalendar.dayString(transaction.date),
                merchant: transaction.merchant,
                cost: transaction.cost,
                card: card?.displayName ?? ""
            )
            guard seen.insert(key).inserted else { continue }
            if sameStore {
                transaction.household = target
                transaction.card = card
            } else {
                let copy = SharedFinanceTransaction(
                    date: transaction.date,
                    cost: transaction.cost,
                    merchant: transaction.merchant,
                    household: target,
                    card: card
                )
                copy.actualCost = transaction.actualCost
                copy.category = transaction.category
                copy.expense = transaction.expense
                copy.breakDown = transaction.breakDown
                copy.createdAt = transaction.createdAt
            }
        }

        // Everything still in `source` is a duplicate of something in
        // `target` (or, across stores, has been copied there): the cascade
        // takes it all.
        context.delete(source)
    }

    // MARK: - Helpers

    /// The members of a to-many relationship not yet deleted.
    static func live<T: NSManagedObject>(_ set: Set<T>?) -> [T] {
        (set ?? []).filter { !$0.isDeleted }
    }

    static func accountKey(_ account: SharedFinanceAccount) -> String {
        accountKey(account.displayName, account.category, owner: account.owner)
    }

    static func accountKey(_ displayName: String, _ category: AccountCategory, owner: SharedFinanceOwner?) -> String {
        "\(FinanceMonthExchange.accountKey(displayName, category))|\(FinanceMonthExchange.nameKey(owner?.name ?? ""))"
    }

    static func metalKey(_ name: String, owner: SharedFinanceOwner?) -> String {
        "\(FinanceMonthExchange.nameKey(name))|\(FinanceMonthExchange.nameKey(owner?.name ?? ""))"
    }

    static func transactionKey(_ transaction: SharedFinanceTransaction) -> String {
        FinanceMonthExchange.transactionKey(
            day: FinanceCalendar.dayString(transaction.date),
            merchant: transaction.merchant,
            cost: transaction.cost,
            card: transaction.card?.displayName ?? ""
        )
    }
}

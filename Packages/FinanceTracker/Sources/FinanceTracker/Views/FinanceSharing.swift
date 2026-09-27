import Core
import CoreData
import SwiftUI

/// Sharing-status text for the household, shown on the Holdings people row.
/// `nil` means say nothing: an unshared household shows no badge.
extension SharingStatus {
    var householdBadgeLabel: String? {
        switch self {
        case .notShared:
            return nil
        case .owned(let participantCount):
            // `participantCount` includes this device's own user.
            let others = max(participantCount - 1, 0)
            return others == 0 ? "Shared" : "Shared with \(counted(others, "person", plural: "people"))"
        case .sharedWithMe(_, let permission):
            return permission == .readOnly ? "Shared with you · View only" : "Shared with you"
        }
    }
}

/// Whether the reader can change `object`. A view-only participant in a
/// partner's household can look but not touch; everything else — including
/// nothing at all yet — is editable.
@MainActor
func canEdit(_ object: NSManagedObject?, in container: NSPersistentCloudKitContainer?) -> Bool {
    guard let object, let container else { return true }
    return SharingStatusResolver.canEdit(object, in: container)
}

extension EnvironmentValues {
    /// False while `FinanceRootView` waits for this launch's first iCloud
    /// import. Until then nothing may create a household: a device that
    /// added something before the first sync arrived minted a second private
    /// household, and the resolver hid it — with what was typed into it —
    /// behind the older one. Only matters while there's no household at all;
    /// `FinanceFold.tidy` folds one made after a timeout anyway.
    @Entry var financeCanCreateHousehold = true
}

/// Opens the system sharing UI for this person's own household — creating
/// (and saving) it first if nothing has been added yet, since a CKShare needs
/// a saved record to hang off. Deliberately not the household new things go
/// into, which after accepting a partner's share is theirs — see
/// `FinanceHouseholdResolver.own`.
struct ShareHouseholdButton: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.financePersistentContainer) private var container
    @Environment(\.presentShareSheet) private var presentShareSheet
    @Environment(\.financeCanCreateHousehold) private var canCreateHousehold

    var body: some View {
        Button {
            guard let container else { return }
            let household = FinanceHouseholdResolver.own(in: context, container: container)
            try? context.saveIfNeeded()
            presentShareSheet(ShareSheetRequest(object: household, container: container))
        } label: {
            Label("Share with Partner", systemImage: "person.crop.circle.badge.plus")
        }
        // `own` may create the household, so it waits for iCloud too.
        .disabled(container == nil || !canCreateHousehold)
    }
}

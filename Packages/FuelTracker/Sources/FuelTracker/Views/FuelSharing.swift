import Core

/// Small, honest sharing-status text for a vehicle — shared between
/// `VehicleLogView`'s header and `GarageView`'s rows so the wording can't
/// drift between the two. `nil` means "say nothing", per CLAUDE.md's brief:
/// an unshared vehicle shows no badge at all.
extension SharingStatus {
    var vehicleBadgeLabel: String? {
        switch self {
        case .notShared:
            return nil
        case .owned(let participantCount):
            // `participantCount` includes the owner (this device) — see
            // `SharingStatusResolver`'s own doc comment — so it's the others
            // that are worth saying.
            let others = max(participantCount - 1, 0)
            return others == 0 ? "Shared" : "Shared · \(counted(others, "person", plural: "people"))"
        case .sharedWithMe(_, let permission):
            // No inviter name is available from `SharingStatusResolver` (it
            // only resolves this device's own participant, not the share's
            // owner) — "Shared with me" stays honest rather than guessing one.
            return permission == .readOnly ? "Shared with me · View only" : "Shared with me"
        }
    }
}

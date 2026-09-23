import CloudKit
import Core
import CoreData
import SwiftUI

#if os(iOS)
import UIKit
#endif

// The real, per-platform CKShare sharing UI. Feature packages never see this
// file — they call `\.presentShareSheet` (Core's `ShareSheetPresenting.swift`),
// which `HomeView` wires to `ShareSheetHostView` below via
// `.presentsShareSheets()` on each module's content. See CLAUDE.md's macOS section for why this split
// lives here rather than behind a `MacCompat.swift` shim: iOS has
// `UICloudSharingController`; macOS has nothing, so the two platforms
// genuinely need different UI, not the same call site with a stand-in.

/// Answers `\.presentShareSheet` for everything inside a module. It has to sit
/// on the module's own content, not the WindowGroup: on iPhone a module is a
/// fullScreenCover, and a sheet attached underneath it can't present while the
/// cover is up — SwiftUI queues it ("only presenting a single sheet is
/// supported") until the module closes, so every Share button did nothing.
private struct PresentsShareSheets: ViewModifier {
    @State private var request: ShareSheetRequest?

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .environment(\.presentShareSheet) { CloudSharingPresenter.present($0) }
        #else
        content
            .environment(\.presentShareSheet) { request = $0 }
            .sheet(item: $request) { MacShareSheet(request: $0) }
        #endif
    }
}

extension View {
    func presentsShareSheets() -> some View {
        modifier(PresentsShareSheets())
    }
}

// MARK: - iOS: UICloudSharingController

#if os(iOS)
/// Presents `UICloudSharingController` the way UIKit documents it: presented
/// directly by the top view controller. It used to be wrapped in a
/// `UIViewControllerRepresentable` inside a SwiftUI `.sheet`, which showed an
/// empty sheet — the controller presents its own UI and doesn't work as a
/// sheet's embedded content.
///
/// An object that's already shared opens its existing `CKShare`, so the owner
/// can manage participants; only an unshared one goes through the
/// preparation-handler initializer, which creates the share on demand.
/// `share(_:to:)` on an object that's already in a share fails.
///
/// The preparation-handler initializer is deprecated in iOS 17 toward
/// `UIActivityViewController`'s `activityItemsConfiguration`, but
/// `NSPersistentCloudKitContainer.share(_:to:completion:)`'s own header names
/// it as the intended pairing, and nothing replaces it one for one.
@MainActor
enum CloudSharingPresenter {
    /// `UICloudSharingController.delegate` is weak and this delegate holds no
    /// state, so one shared instance keeps it alive.
    private static let delegate = Delegate()

    static func present(_ request: ShareSheetRequest) {
        guard let presenter = topViewController() else { return }
        let object = request.object
        let container = request.container

        let title = displayTitle(of: object)

        let controller: UICloudSharingController
        if let share = try? container.fetchShares(matching: [object.objectID])[object.objectID],
           let identifier = container.persistentStoreDescriptions.first?.cloudKitContainerOptions?.containerIdentifier {
            controller = UICloudSharingController(share: share, container: CKContainer(identifier: identifier))
        } else {
            controller = UICloudSharingController { _, preparationCompletionHandler in
                container.share([object], to: nil) { _, share, ckContainer, error in
                    // Without a title the invitation names nothing — the
                    // person receiving it can't tell which trip it is.
                    share?[CKShare.SystemFieldKey.title] = title
                    preparationCompletionHandler(share, ckContainer, error)
                }
            }
        }
        controller.availablePermissions = [.allowReadWrite, .allowReadOnly, .allowPrivate]
        controller.delegate = delegate
        presenter.present(controller, animated: true)
    }

    /// A trip has a `title`; a vehicle and a guide have a `name`.
    private static func displayTitle(of object: NSManagedObject) -> String? {
        let attributes = object.entity.attributesByName
        for key in ["title", "name"] where attributes[key] != nil {
            if let value = object.value(forKey: key) as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// The module is itself a fullScreenCover, so present from whatever is
    /// frontmost, not the window's root.
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    private final class Delegate: NSObject, UICloudSharingControllerDelegate {
        // The controller shows its own error for a failed save.
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {}

        // Required by the protocol; CloudKit uses a default title when nil.
        func itemTitle(for csc: UICloudSharingController) -> String? { nil }
    }
}
#endif

// MARK: - macOS: a small custom CKShare sheet

#if os(macOS)
/// The one piece of sharing UI macOS has no system equivalent for. Built
/// directly against `CKShare`/`NSPersistentCloudKitContainer`'s sharing
/// category because nothing else exists on this platform. Deliberately
/// narrow — CLAUDE.md's brief is "share with one specific partner", not a
/// general audience-management screen — so this shows participants and their
/// permission, one add-by-email-or-phone field, and a link to hand the other
/// person, and nothing else.
struct MacShareSheet: View {
    let request: ShareSheetRequest
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator: ShareCoordinator
    @State private var newParticipantHandle = ""
    @State private var newParticipantPermission: CKShare.ParticipantPermission = .readWrite

    init(request: ShareSheetRequest) {
        self.request = request
        _coordinator = StateObject(wrappedValue: ShareCoordinator(request: request))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let errorMessage = coordinator.errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
                if let share = coordinator.share {
                    Section("Participants") {
                        ForEach(Array(share.participants.enumerated()), id: \.offset) { _, participant in
                            participantRow(participant)
                        }
                    }
                    Section("Invite") {
                        TextField("Email or phone number", text: $newParticipantHandle)
                        Picker("Permission", selection: $newParticipantPermission) {
                            Text("Can edit").tag(CKShare.ParticipantPermission.readWrite)
                            Text("Read only").tag(CKShare.ParticipantPermission.readOnly)
                        }
                        Button("Add") {
                            coordinator.addParticipant(handle: newParticipantHandle, permission: newParticipantPermission)
                            newParticipantHandle = ""
                        }
                        .disabled(newParticipantHandle.trimmingCharacters(in: .whitespaces).isEmpty || coordinator.isAddingParticipant)
                    }
                    Section {
                        if let url = share.url {
                            ShareLink("Share Link", item: url)
                            Button("Copy Link") {
                                UIPasteboard.general.string = url.absoluteString
                            }
                        } else {
                            HStack {
                                ProgressView()
                                Text("Preparing the link…")
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                } else if coordinator.isLoading {
                    ProgressView("Preparing to share…")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .task { await coordinator.prepare() }
    }

    @ViewBuilder
    private func participantRow(_ participant: CKShare.Participant) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(displayName(for: participant))
                Text(roleLabel(participant.role))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if participant.role == .owner {
                Text("Owner").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker(
                    "Permission",
                    selection: Binding(
                        get: { participant.permission },
                        set: { coordinator.setPermission($0, for: participant) }
                    )
                ) {
                    Text("Can edit").tag(CKShare.ParticipantPermission.readWrite)
                    Text("Read only").tag(CKShare.ParticipantPermission.readOnly)
                }
                .labelsHidden()
                .frame(width: 130)
            }
        }
    }

    private func displayName(for participant: CKShare.Participant) -> String {
        if let components = participant.userIdentity.nameComponents {
            return PersonNameComponentsFormatter.localizedString(from: components, style: .default)
        }
        if let email = participant.userIdentity.lookupInfo?.emailAddress {
            return email
        }
        if let phone = participant.userIdentity.lookupInfo?.phoneNumber {
            return phone
        }
        return "Pending invite"
    }

    private func roleLabel(_ role: CKShare.ParticipantRole) -> String {
        switch role {
        case .owner: "Owner"
        case .administrator: "Administrator"
        case .privateUser: "Participant"
        case .publicUser: "Public participant"
        case .unknown: "Unknown"
        @unknown default: "Unknown"
        }
    }
}

/// Owns every mutable and asynchronous piece of `MacShareSheet` — a class
/// (not `@State` on the view struct) so CKShare/Core Data completion handlers,
/// which fire on their own background queues, have one stable, `@MainActor`
/// place to hop back into before touching anything the view reads.
@MainActor
private final class ShareCoordinator: ObservableObject {
    @Published var share: CKShare?
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var isAddingParticipant = false

    private let request: ShareSheetRequest

    init(request: ShareSheetRequest) {
        self.request = request
    }

    func prepare() async {
        guard request.object.objectID.persistentStore != nil else {
            errorMessage = "Save this item before sharing it."
            isLoading = false
            return
        }
        // Reuse an existing share for this object rather than creating a
        // second one — `share(_:to:completion:)`'s own header comment says it
        // fails outright if any of the objects are already shared.
        if let existingShares = try? request.container.fetchShares(matching: [request.object.objectID]),
           let existing = existingShares[request.object.objectID] {
            share = existing
            isLoading = false
            if existing.url == nil {
                persist(existing)
            }
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // `store` isn't captured here — `persist(_:)` re-derives it itself,
            // on the MainActor, once this hops back below. `NSPersistentStore`
            // isn't `Sendable`, and this completion runs on CloudKit's own
            // background queue, so a captured `store` can't safely ride along
            // into the `Task { @MainActor in }` below with it.
            request.container.share([request.object], to: nil) { [weak self] _, newShare, _, error in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    self.isLoading = false
                    if let error {
                        self.errorMessage = error.localizedDescription
                    } else if let newShare {
                        self.share = newShare
                        self.persist(newShare)
                    }
                    continuation.resume()
                }
            }
        }
    }

    func setPermission(_ permission: CKShare.ParticipantPermission, for participant: CKShare.Participant) {
        guard let share else { return }
        participant.permission = permission
        persist(share)
    }

    func addParticipant(handle: String, permission: CKShare.ParticipantPermission) {
        guard let share, let store = request.object.objectID.persistentStore else { return }
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lookupInfo = trimmed.contains("@")
            ? CKUserIdentity.LookupInfo(emailAddress: trimmed)
            : CKUserIdentity.LookupInfo(phoneNumber: trimmed)
        isAddingParticipant = true
        // `store` is only a plain argument to fetchParticipants itself here,
        // never captured inside the completion closure below — see the same
        // Sendable reasoning in `prepare()` above.
        request.container.fetchParticipants(matching: [lookupInfo], into: store) { [weak self] participants, error in
            Task { @MainActor in
                guard let self else { return }
                self.isAddingParticipant = false
                guard let participant = participants?.first else {
                    self.errorMessage = error?.localizedDescription
                        ?? "Couldn't find anyone on iCloud with that email or phone number."
                    return
                }
                participant.permission = permission
                share.addParticipant(participant)
                self.persist(share)
            }
        }
    }

    /// Re-derives the object's persistent store itself rather than taking one
    /// as a parameter — see the Sendable reasoning in `prepare()` above for
    /// why callers don't hand this a `store` they got from a background
    /// completion closure.
    private func persist(_ share: CKShare) {
        guard let store = request.object.objectID.persistentStore else { return }
        request.container.persistUpdatedShare(share, in: store) { [weak self] updatedShare, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.errorMessage = error.localizedDescription
                } else if let updatedShare {
                    self.share = updatedShare
                }
            }
        }
    }
}
#endif

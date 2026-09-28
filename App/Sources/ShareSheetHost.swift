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
            .environment(\.presentShareSheet, PresentShareSheetAction { CloudSharingPresenter.present($0) })
        #else
        content
            .environment(\.presentShareSheet, PresentShareSheetAction { request = $0 })
            .sheet(item: $request) { MacShareSheet(request: $0) }
        #endif
    }
}

extension View {
    func presentsShareSheets() -> some View {
        modifier(PresentsShareSheets())
            .showsShareAcceptOutcome()
    }

    /// Says whether a tapped invitation was accepted. On the home screen and
    /// again inside each module, since an alert under a fullScreenCover can't
    /// show while the cover is up.
    func showsShareAcceptOutcome() -> some View {
        modifier(ShareAcceptOutcomeAlert())
    }
}

private struct ShareAcceptOutcomeAlert: ViewModifier {
    @ObservedObject private var router = ShareAcceptRouter.shared

    func body(content: Content) -> some View {
        content.alert(
            router.outcome?.title ?? "",
            isPresented: Binding(get: { router.outcome != nil }, set: { if !$0 { router.outcome = nil } })
        ) {
            Button("OK") { router.outcome = nil }
        } message: {
            Text(router.outcome?.message ?? "")
        }
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
        guard topViewController() != nil else { return }
        let object = request.object
        let container = request.container
        let title = displayTitle(of: object)

        // Looking the share up, and re-saving it when it needs a stamp, both
        // happen off the main thread, and the controller is presented once
        // they're done. The stamp's `persistUpdatedShare` used to run right
        // here on the main thread, and it waits synchronously on the
        // container's executor — see CloudShareCalls.swift: Share hung the
        // app until iOS killed it (watchdog 0x8BADF00D, TestFlight build 16).
        nonisolated(unsafe) let sharedObject = object
        container.fetchShareInBackground(for: object.objectID) { existing in
            guard let existing else {
                Task { @MainActor in show(object: sharedObject, container: container, existing: nil, title: title) }
                return
            }
            // A share made before shares were stamped can't be accepted;
            // stamping it here fixes every invitation already sent for it.
            // Saved before the controller gets the share, so the two never
            // hold different versions of it.
            guard ShareAcceptRouter.stamp(existing, for: sharedObject),
                  let store = sharedObject.objectID.persistentStore else {
                Task { @MainActor in show(object: sharedObject, container: container, existing: existing, title: title) }
                return
            }
            container.persistUpdatedShareInBackground(existing, in: store) { saved, _ in
                let share = saved ?? existing
                Task { @MainActor in show(object: sharedObject, container: container, existing: share, title: title) }
            }
        }
    }

    private static func show(
        object: NSManagedObject,
        container: NSPersistentCloudKitContainer,
        existing: CKShare?,
        title: String?
    ) {
        // Looked up again: the lookup took a moment, and whatever was on top
        // when Share was tapped may have gone.
        guard let presenter = topViewController() else { return }
        let controller: UICloudSharingController
        if let existing,
           let identifier = container.persistentStoreDescriptions.first?.cloudKitContainerOptions?.containerIdentifier {
            controller = UICloudSharingController(share: existing, container: CKContainer(identifier: identifier))
        } else {
            // Deprecated, and the one warning left on purpose: this works end
            // to end, and a replacement can only be proven on two devices.
            controller = UICloudSharingController { _, preparationCompletionHandler in
                // share(_:to:)'s completion is `@Sendable` and runs on
                // CloudKit's queue, which Swift 6 won't let the non-`Sendable`
                // object or UIKit's handler be captured into. Both were
                // always used from that queue, and still are, unchanged: the
                // object only for its entity and its object ID, and the
                // handler, which UIKit accepts from any queue.
                nonisolated(unsafe) let object = object
                nonisolated(unsafe) let preparationCompletionHandler = preparationCompletionHandler
                container.shareInBackground(object) { share, ckContainer, error in
                    guard let share, let store = object.objectID.persistentStore else {
                        preparationCompletionHandler(share, ckContainer, error)
                        return
                    }
                    // Without a title the invitation names nothing, and
                    // without the stamp the other person's app can't tell
                    // which tracker it belongs to. Saved before handing it
                    // over, since share(_:to:) already saved the share.
                    share[CKShare.SystemFieldKey.title] = title
                    ShareAcceptRouter.stamp(share, for: object)
                    container.persistUpdatedShareInBackground(share, in: store) { saved, saveError in
                        preparationCompletionHandler(saved ?? share, ckContainer, saveError)
                    }
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

        // Sharing has started: the moment notifications about the other
        // person's changes start to matter. See SharedChangeNotifications.
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            Task { @MainActor in SharingStatusCache.shared.invalidateAll() }
            Task {
                await SharedChangeNotifications.requestAuthorizationIfUndetermined()
                SharedChangeServerAlerts.shared.sync(force: true)
            }
        }

        // The owner stopped sharing, or a participant left: that share's
        // iCloud alert goes with it.
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            Task { @MainActor in
                SharingStatusCache.shared.invalidateAll()
                SharedChangeServerAlerts.shared.sync(force: true)
            }
        }
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
        .task {
            await coordinator.prepare()
            // Sharing has started — see the iOS delegate's
            // cloudSharingControllerDidSaveShare above.
            if coordinator.share != nil {
                await SharedChangeNotifications.requestAuthorizationIfUndetermined()
            }
        }
        // Participants may have been added, so this share may now want its
        // iCloud alert.
        .onDisappear {
            SharedChangeServerAlerts.shared.sync(force: true)
        }
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
        // fails outright if any of the objects are already shared. Every
        // container call in this coordinator goes through its `…InBackground`
        // form, since each waits synchronously on the container's executor
        // and hung the main thread on iOS — see CloudShareCalls.swift.
        let objectID = request.object.objectID
        let existingShare: CKShare? = await withCheckedContinuation { continuation in
            request.container.fetchShareInBackground(for: objectID) { share in
                continuation.resume(returning: share)
            }
        }
        if let existing = existingShare {
            share = existing
            isLoading = false
            // Stamped so the other person's app can route it; see
            // ShareAcceptRouter.stamp.
            let stamped = ShareAcceptRouter.stamp(existing, for: request.object)
            if existing.url == nil || stamped {
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
            request.container.shareInBackground(request.object) { [weak self] newShare, _, error in
                Task { @MainActor in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    self.isLoading = false
                    if let error {
                        self.errorMessage = error.localizedDescription
                    } else if let newShare {
                        ShareAcceptRouter.stamp(newShare, for: self.request.object)
                        self.share = newShare
                        SharingStatusCache.shared.invalidateAll()
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
        request.container.fetchParticipantsInBackground(matching: [lookupInfo], into: store) { [weak self] participants, error in
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
        request.container.persistUpdatedShareInBackground(share, in: store) { [weak self] updatedShare, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.errorMessage = error.localizedDescription
                } else if let updatedShare {
                    self.share = updatedShare
                    SharingStatusCache.shared.invalidateAll()
                }
            }
        }
    }
}
#endif

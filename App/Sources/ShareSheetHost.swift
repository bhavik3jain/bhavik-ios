import CloudKit
import Core
import CoreData
import SwiftUI

#if os(iOS)
import UIKit
#endif

// The real, per-platform CKShare sharing UI. Feature packages never see this
// file — they call `\.presentShareSheet` (Core's `ShareSheetPresenting.swift`),
// which `HomeView` answers with `PresentsShareSheets` below, through
// `.presentsShareSheets()` on each module's content. See CLAUDE.md's macOS section for why this split
// lives here rather than behind a `MacCompat.swift` shim: iOS has
// `UICloudSharingController`; macOS has nothing, so the two platforms
// genuinely need different UI, not the same call site with a stand-in.
//
// Both platforms get the share the same way first: Core's `SharePreparer`
// finds or makes it in the app's own UI — what it's doing, Cancel, and
// iCloud's own error with Try Again — with every wait bounded. Only a saved
// share with a link goes on to the sharing UI. See `SharePreparationPlan` for
// why: Fuel's Share spun on "generating a link" for as long as Core Data
// wanted, and every retry made another share zone.

/// Answers `\.presentShareSheet` for everything inside a module. It has to sit
/// on the module's own content, not the WindowGroup: on iPhone a module is a
/// fullScreenCover, and a sheet attached underneath it can't present while the
/// cover is up — SwiftUI queues it ("only presenting a single sheet is
/// supported") until the module closes, so every Share button did nothing.
private struct PresentsShareSheets: ViewModifier {
    #if os(iOS)
    @Environment(CloudSyncMonitor.self) private var monitor: CloudSyncMonitor?
    @State private var preparer: SharePreparer?
    @State private var showsProgress = false
    #else
    @State private var request: ShareSheetRequest?
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .environment(\.presentShareSheet, PresentShareSheetAction { begin($0) })
            .sheet(isPresented: $showsProgress, onDismiss: progressDismissed) {
                if let preparer {
                    SharePreparationSheet(preparer: preparer) { showsProgress = false }
                }
            }
            .onChange(of: preparer?.step) { _, step in
                guard let preparer, let step else { return }
                switch step {
                case .ready:
                    // Handed over once the sheet has gone (`progressDismissed`):
                    // UIKit won't present over a sheet that's leaving.
                    if showsProgress {
                        showsProgress = false
                    } else {
                        handOver(preparer)
                    }
                case .failed:
                    showsProgress = true
                default:
                    break
                }
            }
        #else
        content
            .environment(\.presentShareSheet, PresentShareSheetAction { request = $0 })
            .sheet(item: $request) { MacShareSheet(request: $0) }
        #endif
    }

    #if os(iOS)
    private func begin(_ request: ShareSheetRequest) {
        // One at a time. The button stays live while a share is prepared, and
        // every extra tap used to queue another lookup and stack another
        // sharing sheet on top of the first once they finished.
        guard preparer == nil else { return }
        let new = SharePreparer(request: request, monitor: monitor)
        preparer = new
        new.start()
        // The progress sheet only when it takes a moment: an existing share's
        // lookup usually answers at once, and a sheet that flashed up and
        // away before the sharing controller would read as a glitch.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if preparer === new, new.step.isWorking { showsProgress = true }
        }
    }

    /// Closing the sheet before the share is ready is Cancel.
    private func progressDismissed() {
        guard let preparer else { return }
        if preparer.step == .ready {
            handOver(preparer)
        } else {
            preparer.cancel()
            self.preparer = nil
        }
    }

    private func handOver(_ preparer: SharePreparer) {
        self.preparer = nil
        guard let share = preparer.share else { return }
        CloudSharingPresenter.present(share, container: preparer.container)
        if preparer.madeShare { CloudSharingPresenter.sharingStarted() }
    }
    #endif
}

extension View {
    func presentsShareSheets() -> some View {
        modifier(PresentsShareSheets())
            .showsShareAcceptOutcome()
    }

    /// The Mac's: on the split view, without the accept-outcome alert, which
    /// `HomeView` already shows on its root. On the module's content (as on
    /// the phone) it missed every screen a module pushes — a guide, a past
    /// trip — whose navigation the split view hosts: their Share buttons
    /// called the do-nothing default.
    func presentsShareSheetsWithoutOutcome() -> some View {
        modifier(PresentsShareSheets())
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

/// What a preparation is doing, or how it failed with Try Again. The same on
/// both platforms: the phone's progress sheet and the Mac's share sheet.
private struct SharePreparationStatus: View {
    let preparer: SharePreparer

    var body: some View {
        if let failure = preparer.failure {
            VStack(alignment: .leading, spacing: 10) {
                Label(failure.title, systemImage: "exclamationmark.icloud")
                    .font(.headline)
                Text(failure.message(busyFor: preparer.busyFor))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if failure.offersShareAnyway {
                    HStack {
                        Button("Share Anyway") { preparer.start(ignoringEarlierTries: true) }
                            .buttonStyle(.borderedProminent)
                        Button("Check Again") { preparer.start() }
                    }
                } else {
                    Button("Try Again") { preparer.start() }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(preparer.step.statusText)
                }
                if let detail = preparer.step.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - iOS: UICloudSharingController

#if os(iOS)
/// The phone's progress sheet: shown only while a share takes more than a
/// moment to find or make, or when it failed.
private struct SharePreparationSheet: View {
    let preparer: SharePreparer
    let close: () -> Void

    var body: some View {
        NavigationStack {
            SharePreparationStatus(preparer: preparer)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .navigationTitle("Share")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(preparer.step.isWorking ? "Cancel" : "Close", action: close)
                    }
                }
        }
        .presentationDetents([.medium])
    }
}

/// Presents `UICloudSharingController` the way UIKit documents it: presented
/// directly by the top view controller. It used to be wrapped in a
/// `UIViewControllerRepresentable` inside a SwiftUI `.sheet`, which showed an
/// empty sheet — the controller presents its own UI and doesn't work as a
/// sheet's embedded content.
///
/// Always with a saved share that has a link, from `SharePreparer`. An
/// unshared object used to go through the preparation-handler initializer
/// (deprecated in iOS 17), which ran `share(_:to:)` inside the controller:
/// the controller showed its own "generating a link" for as long as Core Data
/// took — after a mirroring reset, until Core Data's own Share-Export request
/// gave up a minute and a half later — with no way to say why, and each
/// retry made another share zone.
@MainActor
enum CloudSharingPresenter {
    /// `UICloudSharingController.delegate` is weak and this delegate holds no
    /// state, so one shared instance keeps it alive.
    private static let delegate = Delegate()

    static func present(_ share: CKShare, container: NSPersistentCloudKitContainer) {
        // Looked up now, not when Share was tapped: preparing took a moment,
        // and whatever was on top then may have gone. Never a second sharing
        // sheet over one that's already up.
        guard let presenter = topViewController(), !(presenter is UICloudSharingController),
              let identifier = container.cloudKitContainerIdentifier else {
            ShareLog.logger.error("\(container.name, privacy: .public) no view controller or iCloud container to present the share from")
            return
        }
        let controller = UICloudSharingController(share: share, container: CKContainer(identifier: identifier))
        controller.availablePermissions = [.allowReadWrite, .allowReadOnly, .allowPrivate]
        controller.delegate = delegate
        presenter.present(controller, animated: true)
    }

    /// Sharing has started: the moment notifications about the other
    /// person's changes start to matter. See SharedChangeNotifications.
    static func sharingStarted() {
        SharingStatusCache.shared.invalidateAll()
        Task {
            await SharedChangeNotifications.requestAuthorizationIfUndetermined()
            SharedChangeServerAlerts.shared.sync(force: true)
        }
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
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            let code = ShareError(error).codeLabel
            ShareLog.logger.error("sharing controller failed to save the share: \(code, privacy: .public)")
        }

        // Required by the protocol; the share carries its own title.
        func itemTitle(for csc: UICloudSharingController) -> String? { nil }

        // People were added or changed.
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            Task { @MainActor in CloudSharingPresenter.sharingStarted() }
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
    @Environment(CloudSyncMonitor.self) private var monitor: CloudSyncMonitor?
    @State private var coordinator: ShareCoordinator
    @State private var newParticipantHandle = ""
    @State private var newParticipantPermission: CKShare.ParticipantPermission = .readWrite

    init(request: ShareSheetRequest) {
        self.request = request
        _coordinator = State(initialValue: ShareCoordinator(request: request))
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
                            // Never a spinner: the preparer only hands over a
                            // share with a link, so this is a later save that
                            // came back without one.
                            Text("iCloud hasn't sent this share's link yet. Close Share and open it again in a minute.")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if let preparer = coordinator.preparer {
                    Section {
                        SharePreparationStatus(preparer: preparer)
                    }
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
            coordinator.start(monitor: monitor)
        }
        .onChange(of: coordinator.preparer?.step) { _, step in
            coordinator.preparationChanged()
            // Sharing has started — see the iOS presenter's sharingStarted.
            if step == .ready, coordinator.preparer?.madeShare == true {
                SharingStatusCache.shared.invalidateAll()
                Task { await SharedChangeNotifications.requestAuthorizationIfUndetermined() }
            }
        }
        // Participants may have been added, so this share may now want its
        // iCloud alert. Closing mid-way stops the waiting, not the call.
        .onDisappear {
            coordinator.preparer?.cancel()
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
/// (not `@State` values on the view struct) so CKShare/Core Data completion
/// handlers, which fire on their own background queues, have one stable,
/// `@MainActor` place to hop back into before touching anything the view reads.
@MainActor
@Observable
private final class ShareCoordinator {
    /// The share the sheet shows: the badge cache's while the preparer looks
    /// it up, then the prepared one, then each version saved after it.
    var share: CKShare?
    var errorMessage: String?
    var isAddingParticipant = false
    private(set) var preparer: SharePreparer?

    @ObservationIgnored private let request: ShareSheetRequest
    /// A participant edit waits this long for iCloud before saying so. It
    /// used to wait for ever: "Add" stayed disabled behind a stuck sync.
    @ObservationIgnored private let editLimit: Duration = .seconds(30)

    init(request: ShareSheetRequest) {
        self.request = request
    }

    func start(monitor: CloudSyncMonitor?) {
        guard preparer == nil else { return }
        // An existing share's people and link at once, from the badge
        // lookups' cache, while the preparer checks it's still current. The
        // lookup waits its turn on the container's executor behind iCloud's
        // imports and exports, and on the Mac that was most of the time
        // Share took.
        if let cached = SharingStatusCache.shared.cachedShare(for: request.object.objectID), cached.url != nil {
            share = cached
        }
        let preparer = SharePreparer(request: request, monitor: monitor)
        self.preparer = preparer
        preparer.start()
    }

    func preparationChanged() {
        guard let preparer else { return }
        switch preparer.step {
        case .ready:
            share = preparer.share
        case .lookingUp, .saving, .fetchingLink:
            // Keep the cached share up while the lookup runs, and while the
            // share it found gets its stamp or its link.
            break
        default:
            // Not shared after all (the cache was stale), or failed: the
            // preparer's own status shows instead.
            share = nil
        }
    }

    func setPermission(_ permission: CKShare.ParticipantPermission, for participant: CKShare.Participant) {
        guard let share else { return }
        participant.permission = permission
        Task { await persist(share) }
    }

    func addParticipant(handle: String, permission: CKShare.ParticipantPermission) {
        guard let share, let store = request.object.objectID.persistentStore else { return }
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let lookupInfo = trimmed.contains("@")
            ? CKUserIdentity.LookupInfo(emailAddress: trimmed)
            : CKUserIdentity.LookupInfo(phoneNumber: trimmed)
        isAddingParticipant = true
        errorMessage = nil
        let container = request.container
        let name = container.name
        Task {
            // Every container call goes through its `…InBackground` form,
            // since each waits synchronously on the container's executor and
            // hung the main thread on iOS — see CloudShareCalls.swift.
            let found: Result<CKShare.Participant, ShareError>? = await Bounded.wait(editLimit) { done in
                container.fetchParticipantsInBackground(matching: [lookupInfo], into: store) { participants, error in
                    if let participant = participants?.first {
                        done(.success(participant))
                    } else {
                        done(.failure(error.map(ShareError.init) ?? .noResult))
                    }
                }
            }
            isAddingParticipant = false
            switch found {
            case .success(let participant)?:
                participant.permission = permission
                share.addParticipant(participant)
                ShareLog.logger.notice("\(name, privacy: .public) added a participant (\(share.participants.count, privacy: .public) now)")
                await persist(share)
            case .failure(let error)?:
                ShareLog.logger.error("\(name, privacy: .public) participant lookup failed: \(error.codeLabel, privacy: .public)")
                errorMessage = error == .noResult
                    ? "Couldn't find anyone on iCloud with that email or phone number."
                    : error.message
            case nil:
                ShareLog.logger.error("\(name, privacy: .public) participant lookup: no answer in 30 s")
                errorMessage = "iCloud didn't answer within 30 seconds. It's usually busy syncing; try again in a minute."
            }
        }
    }

    /// Re-derives the object's persistent store itself rather than taking one
    /// as a parameter: `NSPersistentStore` isn't `Sendable`, and callers that
    /// got one from a background completion can't hand it across.
    private func persist(_ share: CKShare) async {
        guard let store = request.object.objectID.persistentStore else { return }
        let container = request.container
        let saved: Result<CKShare, ShareError>? = await Bounded.wait(editLimit) { done in
            container.persistUpdatedShareInBackground(share, in: store) { updated, error in
                done(updated.map { .success($0) } ?? .failure(error.map(ShareError.init) ?? .noResult))
            }
        }
        switch saved {
        case .success(let updated)?:
            self.share = updated
            SharingStatusCache.shared.invalidateAll()
        case .failure(let error)?:
            ShareLog.logger.error("\(container.name, privacy: .public) saving the share failed: \(error.codeLabel, privacy: .public)")
            errorMessage = error.message
        case nil:
            ShareLog.logger.error("\(container.name, privacy: .public) saving the share: no answer in 30 s")
            errorMessage = "iCloud didn't save the change within 30 seconds. It may still arrive; close Share and open it again to check."
        }
    }
}
#endif

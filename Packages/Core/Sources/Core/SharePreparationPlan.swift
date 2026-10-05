import CloudKit
import Foundation

/// How a Share button gets from a tap to a share with a link, as plain values:
/// which step comes next, how long each may take, and what to say when one
/// doesn't come back. `SharePreparer` carries the steps out against a real
/// container; this decides them, so every decision is tested without one.
///
/// Fuel's Share got stuck on generating a link (October 2026), and each try
/// made things worse. What the Mac's log and iCloud showed:
///
/// - Both stuck shares came in a TestFlight launch whose mirroring had just
///   reset (CKError 2 › 21, change token expired) and was re-importing
///   everything — 11 minutes and 11 hours before. Mac Debug builds then
///   still had the release bundle id, so they opened the same stores against
///   Development, and each switch between the two expired the other's
///   tokens. `share()` waits on the container's executor, so it queued
///   behind that import.
/// - The share UI had no bound of its own. iOS handed `share(_:to:)` to
///   `UICloudSharingController`'s preparation handler and the Mac's sheet
///   waited on its completion, which Core Data only called when its own
///   request gave up ("timed out waiting for request: Share-Export", ~98 s
///   after the tap) — or, with the container's executor wedged, not at all: a
///   thread sat in "Wait timed out during call to recordForManagedObjectID"
///   every ten minutes for three hours.
/// - A lookup that failed read as "not shared": `fetchShares(matching:)`'s
///   error went through `try?` to nil, and nil meant call `share()`.
/// - A `share()` Core Data gave up on still reached iCloud: the new zone and
///   a copy of the car and its fill-ups landed, but this device never
///   recorded the move, and the car's record stayed in the default zone too.
///   `fetchShares` went on answering "not shared", so every retry called
///   `share()` again: four Fuel share zones on the server, each with a copy
///   of one car and its ~80 fill-ups.
///
/// So: a lookup that *answers* "not shared" is the only way to `share()`;
/// before making one, iCloud itself is asked whether an earlier try left a
/// share zone holding this record, and if one did nothing is made without
/// the person saying Share Anyway; `share()` runs at most once per
/// preparation (and `SharePreparer` joins one still running from an earlier
/// try); when it fails or times out, the export it started may still land,
/// so the plan waits for the next upload and looks again instead of making
/// another; and every step has a limit, so the worst case is a message with
/// iCloud's own error and Try Again — never a spinner.
public struct SharePreparationPlan: Sendable, Equatable {
    /// What the screen says while a step runs.
    public enum Step: Sendable, Equatable {
        case lookingUp
        case waitingForSync
        case checkingEarlierTries
        case creating
        case saving
        case waitingForUpload
        case fetchingLink
        case ready
        case failed(Failure)

        public var statusText: String {
            switch self {
            case .lookingUp: "Checking whether it's already shared…"
            case .waitingForSync: "Waiting for iCloud to finish syncing…"
            case .checkingEarlierTries: "Checking iCloud for an earlier try…"
            case .creating: "Creating the share in iCloud…"
            case .saving: "Saving the share…"
            case .waitingForUpload: "Waiting for iCloud to finish uploading…"
            case .fetchingLink: "Getting the link from iCloud…"
            case .ready: "Ready"
            case .failed(let failure): failure.title
            }
        }

        /// A second line, where the wait needs explaining.
        public var detail: String? {
            switch self {
            // Making a share uploads the whole item to a zone of its own, so
            // a first share takes seconds, not a moment; say so rather than
            // look stuck.
            case .creating: "The first time, this uploads everything in it to iCloud and can take a little while."
            case .waitingForSync: "Making a share while iCloud is still syncing this tracker can stall, so it gets a moment to finish first."
            case .waitingForUpload: "iCloud may still be finishing the share in the background."
            case .checkingEarlierTries: "A share that didn't finish before can leave a copy in iCloud; this makes sure Share doesn't add another."
            default: nil
            }
        }

        public var isWorking: Bool {
            switch self {
            case .ready, .failed: false
            default: true
            }
        }
    }

    /// What `SharePreparer` does next.
    public enum Action: Sendable, Equatable {
        case lookUp
        case waitForSync
        case checkEarlierTries
        case create
        case save
        case waitForUpload
        case fetchLink
        case present
        case fail(Failure)
    }

    /// What a step found.
    public enum Event: Sendable, Equatable {
        case lookedUp(Lookup)
        case syncSettled(timedOut: Bool)
        /// The share zones an earlier `share()` left holding a copy of this
        /// object's record, read from iCloud (`LeftoverShareZones`).
        case earlierTriesChecked(EarlierTries)
        /// `share(_:to:)`, or the call still running from an earlier try.
        case created(Outcome)
        /// `persistUpdatedShare`, with the title and the tracker stamp.
        case saved(Outcome)
        case uploadFinished(timedOut: Bool)
        /// The share's own record, fetched from CloudKit for its link.
        case linkFetched(Outcome)
    }

    public enum Lookup: Sendable, Equatable {
        /// `needsSave`: missing its title or its tracker stamp.
        case shared(hasLink: Bool, needsSave: Bool)
        /// `isSyncing`: an import or export of this container is under way.
        case notShared(isSyncing: Bool)
        /// Including a lookup that ran out of time: either way nobody knows
        /// whether a share exists, so nothing may make one.
        case failed(ShareError)
    }

    public enum EarlierTries: Sendable, Equatable {
        case none
        /// Zone names, for the log; the count, for the message.
        case found([String])
        /// Including a check that ran out of time. Treated like a failed
        /// lookup: not knowing is no reason to make another zone.
        case failed(ShareError)
    }

    public enum Outcome: Sendable, Equatable {
        case share(hasLink: Bool)
        case failed(ShareError)
    }

    /// How a preparation ended when it couldn't hand over a share.
    public enum Failure: Sendable, Equatable {
        /// Couldn't tell whether it's shared, so nothing was made.
        case lookupFailed(ShareError)
        /// Earlier tries left copies in share zones of their own (how many);
        /// another `share()` only adds one, so it waits for Share Anyway.
        case earlierTriesLeftCopies(Int)
        /// `share()` failed or ran out of time, and iCloud had no share after
        /// the upload that followed.
        case notCreated(ShareError?)
        /// A share exists, but its link never arrived.
        case noLink(ShareError?)

        public var title: String {
            switch self {
            case .lookupFailed: "Couldn't Check Sharing"
            case .earlierTriesLeftCopies: "An Earlier Share Didn't Finish"
            case .notCreated: "Couldn't Create the Share"
            case .noLink: "The Link Isn't Ready"
            }
        }

        /// Only for copies left by earlier tries: the one failure where making
        /// a share is the person's call, not a retry's.
        public var offersShareAnyway: Bool {
            if case .earlierTriesLeftCopies = self { return true }
            return false
        }

        public var error: ShareError? {
            switch self {
            case .lookupFailed(let error): error
            case .earlierTriesLeftCopies: nil
            case .notCreated(let error), .noLink(let error): error
            }
        }

        /// What happened, what it means for the data, and iCloud's own words.
        /// `busyFor`: how long the container's oldest unfinished sync has been
        /// running, when it's long enough to be the reason.
        public func message(busyFor: TimeInterval? = nil) -> String {
            var text: String
            switch self {
            case .lookupFailed(let error) where error.isTimeout:
                text = "iCloud didn't answer \(error.limitPhrase), so nothing was shared or changed. It's usually busy syncing; try again in a minute."
            case .lookupFailed(let error):
                text = "iCloud couldn't say whether this is already shared, so nothing was shared or changed. \(error.saying)"
            case .earlierTriesLeftCopies(1):
                text = "An earlier try at sharing this didn't finish: iCloud holds a copy of it in a share this device never switched to, so it isn't shared yet. Nothing new was made. Share Anyway makes a fresh share, which usually goes through once iCloud isn't busy; the old copy stays in iCloud, unused."
            case .earlierTriesLeftCopies(let count):
                text = "Earlier tries at sharing this didn't finish: iCloud holds \(count) copies of it, each in a share this device never switched to, so it isn't shared yet. Nothing new was made. Share Anyway makes a fresh share, which usually goes through once iCloud isn't busy; the old copies stay in iCloud, unused."
            case .notCreated(let error?) where error.isTimeout:
                text = "iCloud didn't finish making the share \(error.limitPhrase), and it hadn't arrived after the upload that followed. It may still finish on its own: Try Again opens it if it has, without making a second one."
            case .notCreated(let error):
                text = "iCloud couldn't make the share. \(error?.saying ?? "")"
            case .noLink(let error):
                text = "The share was made, but iCloud hasn't sent its link yet. Try again in a minute. \(error?.saying ?? "")"
            }
            if let busyFor, busyFor >= SharePreparationPlan.longSync {
                // Both stuck shares on the Mac came after a sync that never
                // finished, and only a relaunch got a fresh one.
                text += " iCloud has been syncing this tracker for \(counted(Int(busyFor / 60), "minute")); if this keeps happening, quit and reopen the app."
            }
            return text.trimmingCharacters(in: .whitespaces)
        }
    }

    /// How long each step may take. A limit only ends the wait: the call
    /// itself carries on, and a later Try Again picks up what it did.
    public struct Limits: Sendable, Equatable {
        public var lookup: Duration
        public var sync: Duration
        public var earlierTries: Duration
        public var create: Duration
        public var save: Duration
        public var upload: Duration
        public var fetchLink: Duration

        public init(
            lookup: Duration = .seconds(15),
            sync: Duration = .seconds(30),
            earlierTries: Duration = .seconds(20),
            create: Duration = .seconds(60),
            save: Duration = .seconds(15),
            upload: Duration = .seconds(40),
            fetchLink: Duration = .seconds(15)
        ) {
            self.lookup = lookup
            self.sync = sync
            self.earlierTries = earlierTries
            self.create = create
            self.save = save
            self.upload = upload
            self.fetchLink = fetchLink
        }

        public static let standard = Limits()

        /// The longest a preparation can run with every step waiting out its
        /// limit: three lookups (first, after the sync, after the upload),
        /// one sync wait, one check for earlier tries, one `share()`, one
        /// save, every upload wait, and a link fetch after each.
        public var worstCase: Duration {
            lookup * 3 + sync + earlierTries + create + save
                + upload * SharePreparationPlan.maxUploadWaits
                + fetchLink * (SharePreparationPlan.maxUploadWaits + 1)
        }
    }

    /// Uploads waited for in one preparation: one after a failed `share()`,
    /// one more if the share then arrives without its link.
    public static let maxUploadWaits = 2
    /// A sync older than this is worth mentioning in a failure (seconds).
    public static let longSync: TimeInterval = 5 * 60

    public private(set) var step: Step = .lookingUp
    /// A share with a link this device already knew about. Shown when the
    /// lookup can't answer, rather than nothing; never a reason to skip it.
    public let hasCachedLink: Bool
    /// Share Anyway: the person has been told an earlier try left copies,
    /// and wants a fresh share regardless.
    public let ignoresEarlierTries: Bool
    public private(set) var didWaitForSync = false
    public private(set) var didCheckEarlierTries = false
    public private(set) var didCreate = false
    public private(set) var uploadWaits = 0
    private var createError: ShareError?
    private var hasShare = false
    private var hasLink = false
    private var didSave = false

    public init(hasCachedLink: Bool = false, ignoresEarlierTries: Bool = false) {
        self.hasCachedLink = hasCachedLink
        self.ignoresEarlierTries = ignoresEarlierTries
    }

    /// Every preparation starts by asking whether it's shared already.
    public mutating func start() -> Action {
        step = .lookingUp
        return .lookUp
    }

    public mutating func handle(_ event: Event) -> Action {
        let action = decide(event)
        step = Self.step(for: action)
        return action
    }

    private mutating func decide(_ event: Event) -> Action {
        switch event {
        case .lookedUp(.shared(let link, let needsSave)):
            hasShare = true
            hasLink = link
            if needsSave && !didSave { return .save }
            return link ? .present : .fetchLink

        case .lookedUp(.notShared(let isSyncing)):
            // Already called, and after waiting for the upload iCloud has
            // nothing: calling it again is what made four zones.
            if didCreate { return .fail(.notCreated(createError)) }
            // A sync under way may be the import bringing back a share this
            // device forgot; and a share queued behind it is what timed out.
            if isSyncing && !didWaitForSync { return .waitForSync }
            // fetchShares only knows what this device recorded; a share zone
            // an abandoned `share()` filled is invisible to it.
            if !ignoresEarlierTries && !didCheckEarlierTries { return .checkEarlierTries }
            return .create

        case .lookedUp(.failed(let error)):
            if didCreate { return .fail(.notCreated(createError ?? error)) }
            if hasCachedLink { return .present }
            return .fail(.lookupFailed(error))

        case .earlierTriesChecked(let earlier):
            didCheckEarlierTries = true
            switch earlier {
            case .none: return .create
            case .found(let zones): return .fail(.earlierTriesLeftCopies(zones.count))
            case .failed(let error): return .fail(.lookupFailed(error))
            }

        case .syncSettled:
            didWaitForSync = true
            // Settled or not, look again: the import may have brought the
            // share back.
            return .lookUp

        case .created(.share(let link)):
            didCreate = true
            hasShare = true
            hasLink = link
            // Its title and tracker stamp, before anyone is handed it.
            return .save

        case .created(.failed(let error)):
            didCreate = true
            createError = error
            // The export the call queued carries on without it.
            return .waitForUpload

        case .saved(let outcome):
            didSave = true
            if case .share(hasLink: true) = outcome { hasLink = true }
            // An unsaved title or stamp isn't worth withholding a share
            // with a link: opening Share again saves them.
            return hasLink ? .present : .fetchLink

        case .linkFetched(.share(hasLink: true)):
            hasLink = true
            return .present

        case .linkFetched(let outcome):
            if uploadWaits < Self.maxUploadWaits { return .waitForUpload }
            if case .failed(let error) = outcome { return .fail(.noLink(error)) }
            return .fail(.noLink(nil))

        case .uploadFinished:
            uploadWaits += 1
            // With a share in hand only its link is missing; without one,
            // ask Core Data whether the upload made it after all.
            return hasShare ? .fetchLink : .lookUp
        }
    }

    static func step(for action: Action) -> Step {
        switch action {
        case .lookUp: .lookingUp
        case .waitForSync: .waitingForSync
        case .checkEarlierTries: .checkingEarlierTries
        case .create: .creating
        case .save: .saving
        case .waitForUpload: .waitingForUpload
        case .fetchLink: .fetchingLink
        case .present: .ready
        case .fail(let failure): .failed(failure)
        }
    }
}

/// An error from a sharing call, reduced to what the screen and the log say:
/// the domain and code (and, for a CloudKit partial failure, the first item's
/// code, which is the real cause), CloudKit's own sentence, or a timeout.
public struct ShareError: Error, Sendable, Equatable {
    public var domain: String
    public var code: Int
    public var underlyingCode: Int?
    public var message: String
    /// Set for a step that ran out of time; `limit` says how long it had.
    public var limit: Duration?

    public var isTimeout: Bool { limit != nil }

    public init(domain: String, code: Int, underlyingCode: Int? = nil, message: String) {
        self.domain = domain
        self.code = code
        self.underlyingCode = underlyingCode
        self.message = message
    }

    public init(_ error: any Error) {
        let error = error as NSError
        var underlying: Int?
        if error.domain == CKError.errorDomain, error.code == CKError.partialFailure.rawValue,
           let partial = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error] {
            // The item errors are the cause; the outer one only says some
            // items failed. Lowest code first, so the log reads the same each
            // time for the same failure.
            underlying = partial.values.map { ($0 as NSError).code }.min()
        } else if let inner = error.userInfo[NSUnderlyingErrorKey] as? NSError, inner.domain == CKError.errorDomain {
            // Core Data wraps CloudKit's error in its own.
            underlying = inner.code
        }
        self.init(domain: error.domain, code: error.code, underlyingCode: underlying, message: error.localizedDescription)
    }

    public static func timedOut(after limit: Duration) -> ShareError {
        var error = ShareError(domain: "Timeout", code: 0, message: "No answer \(phrase(for: limit)).")
        error.limit = limit
        return error
    }

    /// A call that finished with neither a result nor an error.
    public static let noResult = ShareError(domain: "Sharing", code: 0, message: "iCloud returned no share and no error.")

    /// For logs and the end of the message: "CKError 2 › 14", "Core Data 134419".
    public var codeLabel: String {
        if let limit { return "timed out after \(Self.seconds(limit)) s" }
        let base = switch domain {
        case CKError.errorDomain: "CKError \(code)"
        case NSCocoaErrorDomain: "Core Data \(code)"
        default: "\(domain) \(code)"
        }
        return underlyingCode.map { "\(base) › CKError \($0)" } ?? base
    }

    /// "iCloud said: “…” (CKError 2 › 14)."
    var saying: String {
        let quote = message.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return "iCloud said: “\(quote)” (\(codeLabel))."
    }

    var limitPhrase: String { limit.map(Self.phrase(for:)) ?? "" }

    static func phrase(for limit: Duration) -> String {
        let seconds = Self.seconds(limit)
        return seconds % 60 == 0 && seconds >= 60
            ? "within \(counted(seconds / 60, "minute"))"
            : "within \(seconds) seconds"
    }

    static func seconds(_ limit: Duration) -> Int {
        Int(limit.components.seconds)
    }
}

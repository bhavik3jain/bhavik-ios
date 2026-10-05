import CloudKit
import CoreData
import Foundation
import Testing
@testable import Core

// MARK: - SharePreparationPlan

private let ckError = ShareError(domain: CKError.errorDomain, code: CKError.networkFailure.rawValue, message: "Network failure")
private let timeout = ShareError.timedOut(after: .seconds(15))

/// Feeds `events` to a fresh plan and returns every action it chose, the
/// first (the lookup) included.
private func actions(
    _ events: [SharePreparationPlan.Event],
    cachedLink: Bool = false,
    shareAnyway: Bool = false
) -> [SharePreparationPlan.Action] {
    var plan = SharePreparationPlan(hasCachedLink: cachedLink, ignoresEarlierTries: shareAnyway)
    var chosen = [plan.start()]
    for event in events {
        chosen.append(plan.handle(event))
    }
    return chosen
}

@Test func anExistingShareWithItsLinkIsPresentedStraightAfterTheLookup() {
    #expect(actions([.lookedUp(.shared(hasLink: true, needsSave: false))]) == [.lookUp, .present])
}

@Test func anExistingShareMissingItsStampIsSavedBeforeAnyoneSeesIt() {
    #expect(actions([
        .lookedUp(.shared(hasLink: true, needsSave: true)),
        .saved(.share(hasLink: true)),
    ]) == [.lookUp, .save, .present])
}

@Test func anExistingShareWithoutItsLinkFetchesTheLinkAndNeverMakesAnother() {
    #expect(actions([
        .lookedUp(.shared(hasLink: false, needsSave: false)),
        .linkFetched(.share(hasLink: true)),
    ]) == [.lookUp, .fetchLink, .present])
}

/// The defect behind four Fuel share zones: `try?` turned a failed
/// `fetchShares` into "no share", and that meant call `share()`.
@Test func aLookupThatFailsNeverMakesAShare() {
    #expect(actions([.lookedUp(.failed(ckError))]) == [.lookUp, .fail(.lookupFailed(ckError))])
    #expect(actions([.lookedUp(.failed(timeout))]) == [.lookUp, .fail(.lookupFailed(timeout))])
}

@Test func aLookupThatFailsShowsTheShareThisDeviceAlreadyKnew() {
    #expect(actions([.lookedUp(.failed(timeout))], cachedLink: true) == [.lookUp, .present])
}

@Test func anUnsharedObjectIsSharedThenTitledAndStampedBeforeItsHandedOver() {
    #expect(actions([
        .lookedUp(.notShared(isSyncing: false)),
        .earlierTriesChecked(.none),
        .created(.share(hasLink: true)),
        .saved(.share(hasLink: true)),
    ]) == [.lookUp, .checkEarlierTries, .create, .save, .present])
}

/// The four Fuel zones: each abandoned `share()` left a zone holding the car,
/// `fetchShares` still said "not shared", and the next try made another.
@Test func copiesLeftByEarlierTriesStopTheShareUntilThePersonSaysShareAnyway() {
    let zones = ["com.apple.coredata.cloudkit.share.201B73FA", "com.apple.coredata.cloudkit.share.97DF1E0E"]
    #expect(actions([
        .lookedUp(.notShared(isSyncing: false)),
        .earlierTriesChecked(.found(zones)),
    ]) == [.lookUp, .checkEarlierTries, .fail(.earlierTriesLeftCopies(2))])
    #expect(actions([
        .lookedUp(.notShared(isSyncing: false)),
        .created(.share(hasLink: true)),
        .saved(.share(hasLink: true)),
    ], shareAnyway: true) == [.lookUp, .create, .save, .present])
}

/// Share Anyway skips only the check: a share found by the lookup is still
/// opened, never replaced.
@Test func shareAnywayStillOpensAShareTheLookupFinds() {
    #expect(actions([.lookedUp(.shared(hasLink: true, needsSave: false))], shareAnyway: true) == [.lookUp, .present])
    #expect(actions([.lookedUp(.failed(timeout))], shareAnyway: true) == [.lookUp, .fail(.lookupFailed(timeout))])
}

@Test func aCheckForEarlierTriesThatFailsMakesNothing() {
    #expect(actions([
        .lookedUp(.notShared(isSyncing: false)),
        .earlierTriesChecked(.failed(ckError)),
    ]) == [.lookUp, .checkEarlierTries, .fail(.lookupFailed(ckError))])
}

@Test func onlyCopiesLeftByEarlierTriesOfferShareAnyway() {
    #expect(SharePreparationPlan.Failure.earlierTriesLeftCopies(1).offersShareAnyway)
    #expect(!SharePreparationPlan.Failure.lookupFailed(ckError).offersShareAnyway)
    #expect(!SharePreparationPlan.Failure.notCreated(nil).offersShareAnyway)
    #expect(!SharePreparationPlan.Failure.noLink(nil).offersShareAnyway)
}

/// After a reset an import can bring back the share this device forgot, and
/// a share queued behind a sync is what timed out on the Mac.
@Test func aSyncUnderWayIsWaitedForAndTheLookupRunAgainBeforeSharing() {
    #expect(actions([
        .lookedUp(.notShared(isSyncing: true)),
        .syncSettled(timedOut: false),
        .lookedUp(.shared(hasLink: true, needsSave: false)),
    ]) == [.lookUp, .waitForSync, .lookUp, .present])
}

@Test func theSyncIsWaitedForOnceThenTheShareIsMadeAnyway() {
    #expect(actions([
        .lookedUp(.notShared(isSyncing: true)),
        .syncSettled(timedOut: true),
        .lookedUp(.notShared(isSyncing: true)),
        .earlierTriesChecked(.none),
    ]) == [.lookUp, .waitForSync, .lookUp, .checkEarlierTries, .create])
}

@Test func aShareThatTimedOutIsLookedForAgainAfterTheUploadNotMadeAgain() {
    #expect(actions([
        .lookedUp(.notShared(isSyncing: false)),
        .earlierTriesChecked(.none),
        .created(.failed(.timedOut(after: .seconds(60)))),
        .uploadFinished(timedOut: false),
        .lookedUp(.shared(hasLink: false, needsSave: true)),
        .saved(.failed(ckError)),
        .linkFetched(.share(hasLink: true)),
    ]) == [.lookUp, .checkEarlierTries, .create, .waitForUpload, .lookUp, .save, .fetchLink, .present])
}

@Test func aShareThatNeverArrivesEndsWithTheShareCallsOwnError() {
    let shareError = ShareError(domain: NSCocoaErrorDomain, code: 134_419, message: "Request timed out")
    #expect(actions([
        .lookedUp(.notShared(isSyncing: false)),
        .earlierTriesChecked(.none),
        .created(.failed(shareError)),
        .uploadFinished(timedOut: true),
        .lookedUp(.notShared(isSyncing: false)),
    ]) == [.lookUp, .checkEarlierTries, .create, .waitForUpload, .lookUp, .fail(.notCreated(shareError))])
}

@Test func aLinkThatNeverArrivesIsWaitedForTwiceThenSaidSo() {
    let chosen = actions([
        .lookedUp(.notShared(isSyncing: false)),
        .earlierTriesChecked(.none),
        .created(.share(hasLink: false)),
        .saved(.share(hasLink: false)),
        .linkFetched(.share(hasLink: false)),
        .uploadFinished(timedOut: false),
        .linkFetched(.share(hasLink: false)),
        .uploadFinished(timedOut: true),
        .linkFetched(.failed(ckError)),
    ])
    #expect(chosen.last == .fail(.noLink(ckError)))
    #expect(chosen.filter { $0 == .waitForUpload }.count == SharePreparationPlan.maxUploadWaits)
}

/// Every answer every step can give, in every order: each path ends in a
/// share or a message within a few steps, and none calls `share()` twice.
@Test func everyPathEndsAndNoneMakesTwoShares() {
    let lookups: [SharePreparationPlan.Event] = [
        .lookedUp(.shared(hasLink: true, needsSave: false)), .lookedUp(.shared(hasLink: true, needsSave: true)),
        .lookedUp(.shared(hasLink: false, needsSave: false)), .lookedUp(.shared(hasLink: false, needsSave: true)),
        .lookedUp(.notShared(isSyncing: true)), .lookedUp(.notShared(isSyncing: false)),
        .lookedUp(.failed(ckError)), .lookedUp(.failed(timeout)),
    ]
    let outcomes: [SharePreparationPlan.Outcome] = [.share(hasLink: true), .share(hasLink: false), .failed(ckError), .failed(timeout)]

    func answers(to action: SharePreparationPlan.Action) -> [SharePreparationPlan.Event] {
        switch action {
        case .lookUp: lookups
        case .waitForSync: [.syncSettled(timedOut: true), .syncSettled(timedOut: false)]
        case .checkEarlierTries: [.earlierTriesChecked(.none), .earlierTriesChecked(.found(["z"])), .earlierTriesChecked(.failed(timeout))]
        case .create: outcomes.map { .created($0) }
        case .save: outcomes.map { .saved($0) }
        case .waitForUpload: [.uploadFinished(timedOut: true), .uploadFinished(timedOut: false)]
        case .fetchLink: outcomes.map { .linkFetched($0) }
        case .present, .fail: []
        }
    }

    var paths = 0
    var longest = 0
    func walk(_ plan: SharePreparationPlan, _ action: SharePreparationPlan.Action, depth: Int, creates: Int) {
        let creates = creates + (action == .create ? 1 : 0)
        #expect(creates <= 1, "share() called twice")
        guard depth < 20 else {
            Issue.record("a path ran past 20 steps")
            return
        }
        let next = answers(to: action)
        if next.isEmpty {
            paths += 1
            longest = max(longest, depth)
            return
        }
        for event in next {
            var copy = plan
            let chosen = copy.handle(event)
            walk(copy, chosen, depth: depth + 1, creates: creates)
        }
    }
    for cached in [false, true] {
        for anyway in [false, true] {
            var plan = SharePreparationPlan(hasCachedLink: cached, ignoresEarlierTries: anyway)
            let first = plan.start()
            walk(plan, first, depth: 0, creates: 0)
        }
    }
    #expect(paths > 1000)
    #expect(longest <= 12)
}

@Test func theStepNamesTheWait() {
    var plan = SharePreparationPlan()
    #expect(plan.start() == .lookUp)
    #expect(plan.step == .lookingUp)
    _ = plan.handle(.lookedUp(.notShared(isSyncing: true)))
    #expect(plan.step == .waitingForSync)
    #expect(plan.step.statusText == "Waiting for iCloud to finish syncing…")
    #expect(plan.step.isWorking)
    _ = plan.handle(.syncSettled(timedOut: false))
    _ = plan.handle(.lookedUp(.failed(timeout)))
    #expect(plan.step == .failed(.lookupFailed(timeout)))
    #expect(!plan.step.isWorking)
}

/// "Never an endless spinner", in seconds.
@Test func theWorstCaseIsBoundedAndAddsUpEveryWait() {
    let limits = SharePreparationPlan.Limits.standard
    let expected = limits.lookup * 3 + limits.sync + limits.earlierTries + limits.create + limits.save
        + limits.upload * 2 + limits.fetchLink * 3
    #expect(limits.worstCase == expected)
    #expect(limits.worstCase <= .seconds(300))
}

// MARK: - Messages

@Test func aLookupFailureSaysNothingWasChangedAndQuotesICloud() {
    let message = SharePreparationPlan.Failure.lookupFailed(ckError).message()
    #expect(message.contains("nothing was shared or changed"))
    #expect(message.contains("“Network failure”"))
    #expect(message.contains("(CKError 4)"))
}

@Test func aTimeoutSaysHowLongItWaited() {
    #expect(SharePreparationPlan.Failure.lookupFailed(timeout).message().contains("within 15 seconds"))
    let create = SharePreparationPlan.Failure.notCreated(.timedOut(after: .seconds(60))).message()
    #expect(create.contains("within 1 minute"))
    #expect(create.contains("without making a second one"))
}

@Test func copiesLeftBehindAreCountedAndNothingIsSaidToHaveBeenMade() {
    let one = SharePreparationPlan.Failure.earlierTriesLeftCopies(1).message()
    #expect(one.contains("a copy of it"))
    #expect(one.contains("Nothing new was made"))
    let four = SharePreparationPlan.Failure.earlierTriesLeftCopies(4).message()
    #expect(four.contains("4 copies"))
    #expect(four.contains("Share Anyway"))
}

@Test func aLongSyncIsMentionedAndAShortOneIsNot() {
    let failure = SharePreparationPlan.Failure.notCreated(timeout)
    #expect(failure.message(busyFor: 12 * 60).contains("syncing this tracker for 12 minutes"))
    #expect(!failure.message(busyFor: 40).contains("syncing this tracker"))
    #expect(!failure.message().contains("syncing this tracker"))
}

@Test func aPartialFailureIsLabelledByItsFirstItemsCode() {
    let partial = NSError(
        domain: CKError.errorDomain,
        code: CKError.partialFailure.rawValue,
        userInfo: [
            CKPartialErrorsByItemIDKey: [
                "b": NSError(domain: CKError.errorDomain, code: CKError.changeTokenExpired.rawValue),
                "a": NSError(domain: CKError.errorDomain, code: CKError.zoneNotFound.rawValue),
            ] as [AnyHashable: any Error],
        ]
    )
    let error = ShareError(partial)
    #expect(error.code == 2)
    #expect(error.underlyingCode == CKError.changeTokenExpired.rawValue)
    #expect(error.codeLabel == "CKError 2 › CKError 21")
}

@Test func aCoreDataErrorWrappingCloudKitsCarriesBothCodes() {
    let wrapped = NSError(
        domain: NSCocoaErrorDomain,
        code: 134_400,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: CKError.errorDomain, code: CKError.notAuthenticated.rawValue)]
    )
    #expect(ShareError(wrapped).codeLabel == "Core Data 134400 › CKError 9")
    #expect(ShareError.timedOut(after: .seconds(20)).codeLabel == "timed out after 20 s")
    #expect(ShareError.timedOut(after: .seconds(20)).isTimeout)
    #expect(!ShareError(wrapped).isTimeout)
}

// MARK: - Leftover share zones

@Test func onlyOtherCoreDataShareZonesAreAskedAbout() {
    let owner = CKCurrentUserDefaultName
    let defaultZone = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.zone", ownerName: owner)
    let current = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.share.A8636796", ownerName: owner)
    let leftover = CKRecordZone.ID(zoneName: "com.apple.coredata.cloudkit.share.F5B240CC", ownerName: owner)
    let unrelated = CKRecordZone.ID(zoneName: "SomethingElse", ownerName: owner)
    let zones = [defaultZone, current, leftover, unrelated]
    // A car still in the default zone: every share zone is a leftover.
    #expect(LeftoverShareZones.candidates(zones, besides: defaultZone) == [current, leftover])
    // A car whose share was stopped stays in its zone; that zone isn't one.
    #expect(LeftoverShareZones.candidates(zones, besides: current) == [leftover])
    #expect(LeftoverShareZones.candidates([defaultZone, unrelated], besides: defaultZone).isEmpty)
}

// MARK: - share() bookkeeping

@Test func aSecondShareCallForTheSameObjectJoinsTheFirst() {
    var ledger = ShareCallLedger<String>()
    #expect(ledger.begin("car") == .call)
    #expect(ledger.begin("car") == .join)
    #expect(ledger.begin("other car") == .call)
    ledger.end("car")
    #expect(ledger.begin("car") == .call)
}

// MARK: - Bounded

@Test func aBoundedWaitReturnsTheAnswer() async {
    let answer: Int? = await Bounded.wait(.seconds(5)) { done in
        DispatchQueue.global().async { done(42) }
    }
    #expect(answer == 42)
}

@Test func aBoundedWaitGivesUpAtItsLimitAndDropsALateAnswer() async {
    let late = DispatchSemaphore(value: 0)
    let answer: Int? = await Bounded.wait(.milliseconds(100)) { done in
        DispatchQueue.global().async {
            late.wait()
            done(1) // after the limit: must neither resume twice nor crash
        }
    }
    #expect(answer == nil)
    late.signal()
    try? await Task.sleep(for: .milliseconds(50))
}

@Test func aBoundedWaitThatNeverHearsBackEndsWhenCancelled() async {
    let task = Task {
        let answer: Int? = await Bounded.wait(.seconds(60)) { _ in }
        return answer
    }
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    #expect(await task.value == nil)
}

@Test func aBoundedWaitStartedAfterCancellationEndsAtOnce() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        let answer: Int? = await Bounded.wait(.seconds(60)) { _ in }
        return answer
    }
    #expect(await task.value == nil)
}

// MARK: - One container's sync

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Test func syncingIsScopedToOneContainersStores() {
    var ledger = CloudSyncLedger()
    let id = UUID()
    ledger.record(CloudSyncEvent(id: id, storeIdentifier: "trips", kind: .import, startDate: t0))
    #expect(ledger.isSyncing(in: ["trips"]))
    #expect(!ledger.isSyncing(in: ["fuel", "fuel-shared"]))
    #expect(ledger.oldestInFlightStart(in: ["trips", "fuel"]) == t0)
    #expect(ledger.oldestInFlightStart(in: ["fuel"]) == nil)
    ledger.record(CloudSyncEvent(id: id, storeIdentifier: "trips", kind: .import, startDate: t0, endDate: t0 + 5, succeeded: true))
    #expect(!ledger.isSyncing(in: ["trips"]))
}

@Test func aFailedExportStillCountsAsTheUploadEnding() {
    var ledger = CloudSyncLedger()
    ledger.record(CloudSyncEvent(storeIdentifier: "fuel", kind: .export, startDate: t0, endDate: t0 + 3, succeeded: false, errorDescription: "quota"))
    #expect(ledger.stores["fuel"]?.lastExportEndedAt == t0 + 3)
    #expect(ledger.stores["fuel"]?.lastExportAt == nil)
    #expect(ledger.exportEnded(after: t0 + 1, in: ["fuel"]))
    #expect(!ledger.exportEnded(after: t0 + 3, in: ["fuel"]))
    #expect(!ledger.exportEnded(after: t0, in: ["trips"]))
    // An import is not an upload.
    ledger.record(CloudSyncEvent(storeIdentifier: "trips", kind: .import, startDate: t0, endDate: t0 + 9, succeeded: true))
    #expect(!ledger.exportEnded(after: t0, in: ["trips"]))
}

@MainActor
@Test func waitingForIdleEndsWhenTheSyncEnds() async {
    let monitor = CloudSyncMonitor(containerID: nil, nudge: {}, center: NotificationCenter())
    let id = UUID()
    monitor.ingest(CloudSyncEvent(id: id, storeIdentifier: "fuel", kind: .import, startDate: .now))
    #expect(monitor.isSyncing(["fuel"]))
    Task {
        try? await Task.sleep(for: .milliseconds(300))
        monitor.ingest(CloudSyncEvent(id: id, storeIdentifier: "fuel", kind: .import, startDate: .now, endDate: .now, succeeded: true))
    }
    #expect(await monitor.waitUntilIdle(["fuel"], timeout: .seconds(10)))
    #expect(!monitor.isSyncing(["fuel"]))
}

@MainActor
@Test func waitingForIdleGivesUpOnASyncThatNeverEnds() async {
    let monitor = CloudSyncMonitor(containerID: nil, nudge: {}, center: NotificationCenter())
    monitor.ingest(CloudSyncEvent(storeIdentifier: "fuel", kind: .setup, startDate: .now))
    #expect(await !monitor.waitUntilIdle(["fuel"], timeout: .milliseconds(300)))
    #expect(monitor.syncingSince(["fuel"]) != nil)
}

@MainActor
@Test func waitingForAnExportCountsOnlyOneEndingAfterTheWaitBegan() async {
    let monitor = CloudSyncMonitor(containerID: nil, nudge: {}, center: NotificationCenter())
    let began = Date.now
    monitor.ingest(CloudSyncEvent(storeIdentifier: "fuel", kind: .export, startDate: t0, endDate: t0 + 1, succeeded: true))
    #expect(await !monitor.waitForExport(["fuel"], endingAfter: began, timeout: .milliseconds(300)))
    Task {
        try? await Task.sleep(for: .milliseconds(200))
        monitor.ingest(CloudSyncEvent(storeIdentifier: "fuel", kind: .export, startDate: .now, endDate: .now, succeeded: true))
    }
    #expect(await monitor.waitForExport(["fuel"], endingAfter: began, timeout: .seconds(10)))
}

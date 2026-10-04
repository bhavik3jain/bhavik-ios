import Foundation
import Testing
import UserNotifications
@testable import Core

private let tripZone = "com.apple.coredata.cloudkit.share.7A1C2D3E-0000-4000-8000-00000000A001"

/// A local notification as `SharedChangeNotifications.post` builds it.
private func localContent(module: String) -> UNNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = "Rome & Amalfi"
    content.userInfo = [
        SharedChangeNotifications.moduleUserInfoKey: module,
        SharedChangeNotifications.rootUserInfoKey: "x-coredata://store/SharedTrip/p1",
    ]
    return content
}

/// iCloud's alert as it's delivered: our category, and CloudKit's own "ck"
/// payload naming the subscription — no custom userInfo. CloudKit puts the
/// subscription ID inside the kind-specific dictionary, `fet` for a zone
/// subscription and `met` for a database one; at the top level of "ck"
/// `CKNotification` doesn't read it and the tap routes nowhere.
private func serverContent(zoneSubscriptionID subscriptionID: String) -> UNNotificationContent {
    serverContent(ck: ["fet": ["dbs": 2, "sid": subscriptionID, "zid": tripZone, "zoid": "_defaultOwner"]])
}

private func serverContent(databaseSubscriptionID subscriptionID: String) -> UNNotificationContent {
    serverContent(ck: ["met": ["dbs": 3, "sid": subscriptionID]])
}

private func serverContent(ck kind: [String: Any]) -> UNNotificationContent {
    let content = UNMutableNotificationContent()
    content.categoryIdentifier = SharedChangeServerAlertText.category
    var ck: [String: Any] = [
        "ce": 2,
        "cid": "iCloud.com.bhavikjain.trackers",
        "ckuserid": "_0123456789abcdef0123456789abcdef",
        "nid": "8d8b8a2e-0000-4000-8000-000000000001",
    ]
    ck.merge(kind) { _, new in new }
    content.userInfo = [
        "aps": ["alert": ["body": "Rome & Amalfi was updated"], "category": SharedChangeServerAlertText.category],
        "ck": ck,
    ]
    return content
}

// MARK: - Tap

@Test func tappingALocalNotificationOpensItsTracker() {
    let module = SharedChangeNotificationRouting.moduleToOpen(
        actionIdentifier: UNNotificationDefaultActionIdentifier,
        content: localContent(module: "trips"),
        participatingModuleIDs: []
    )
    #expect(module == "trips")
}

@Test func dismissingANotificationOpensNothing() {
    let module = SharedChangeNotificationRouting.moduleToOpen(
        actionIdentifier: UNNotificationDismissActionIdentifier,
        content: localContent(module: "trips"),
        participatingModuleIDs: []
    )
    #expect(module == nil)
}

@Test func tappingAnICloudAlertOpensTheTrackerItsSubscriptionNames() {
    let zoneAlert = serverContent(zoneSubscriptionID: SharedChangeServerAlertID.zone(moduleID: "trips", zoneName: tripZone))
    #expect(SharedChangeNotificationRouting.moduleToOpen(
        actionIdentifier: UNNotificationDefaultActionIdentifier,
        content: zoneAlert,
        participatingModuleIDs: []
    ) == "trips")

    let participantAlert = serverContent(databaseSubscriptionID: SharedChangeServerAlertID.shared)
    #expect(SharedChangeNotificationRouting.moduleToOpen(
        actionIdentifier: UNNotificationDefaultActionIdentifier,
        content: participantAlert,
        participatingModuleIDs: ["finance"]
    ) == "finance")
    #expect(SharedChangeNotificationRouting.moduleToOpen(
        actionIdentifier: UNNotificationDefaultActionIdentifier,
        content: participantAlert,
        participatingModuleIDs: ["finance", "trips"]
    ) == nil, "Can't tell which of two trackers changed, so the app just opens")
}

@Test func anICloudAlertNeverRoutesOnAModuleKey() {
    // Only the subscription says where an iCloud alert goes; a stray
    // "module" key in its payload is not ours.
    let content = UNMutableNotificationContent()
    content.categoryIdentifier = SharedChangeServerAlertText.category
    content.userInfo = [SharedChangeNotifications.moduleUserInfoKey: "trips"]
    #expect(SharedChangeNotificationRouting.moduleToOpen(
        actionIdentifier: UNNotificationDefaultActionIdentifier,
        content: content,
        participatingModuleIDs: []
    ) == nil)
}

/// Finance's "September's report is ready" opens the report, not just the
/// tracker: the tap carries the module's own destination through untouched.
@Test func aTapCarriesItsDestinationIntoTheTracker() {
    let content = UNMutableNotificationContent()
    content.userInfo = [
        SharedChangeNotifications.moduleUserInfoKey: "finance",
        SharedChangeNotifications.destinationUserInfoKey: "finance.report:2026-09",
    ]
    #expect(SharedChangeNotificationRouting.destinationToOpen(
        actionIdentifier: UNNotificationDefaultActionIdentifier,
        content: content
    ) == "finance.report:2026-09")
    #expect(SharedChangeNotificationRouting.destinationToOpen(
        actionIdentifier: UNNotificationDismissActionIdentifier,
        content: content
    ) == nil, "Dismissing it opens nothing")
    #expect(SharedChangeNotificationRouting.destinationToOpen(
        actionIdentifier: UNNotificationDefaultActionIdentifier,
        content: localContent(module: "trips")
    ) == nil, "A shared-change notification has no destination")

    let server = UNMutableNotificationContent()
    server.categoryIdentifier = SharedChangeServerAlertText.category
    server.userInfo = content.userInfo
    #expect(SharedChangeNotificationRouting.destinationToOpen(
        actionIdentifier: UNNotificationDefaultActionIdentifier,
        content: server
    ) == nil, "iCloud's alert is never ours to route")
}

// MARK: - While in front

@Test func aNotificationShowsUnlessItsTrackerIsOnScreen() {
    #expect(SharedChangeNotificationRouting.presentationOptions(
        categoryIdentifier: "", moduleID: "trips", onScreenModuleID: nil
    ) == [.banner, .list, .sound])
    #expect(SharedChangeNotificationRouting.presentationOptions(
        categoryIdentifier: "", moduleID: "trips", onScreenModuleID: "fuel"
    ) == [.banner, .list, .sound])
    #expect(SharedChangeNotificationRouting.presentationOptions(
        categoryIdentifier: "", moduleID: "trips", onScreenModuleID: "trips"
    ) == [], "The change is already on screen")
}

@Test func iCloudsAlertIsNeverShownWhileTheAppIsInFront() {
    #expect(SharedChangeNotificationRouting.presentationOptions(
        categoryIdentifier: SharedChangeServerAlertText.category, moduleID: nil, onScreenModuleID: nil
    ) == [])
}

// MARK: - The list a tap opens

@Test func aTappedBurstCarriesItsListOfChanges() throws {
    let content = UNMutableNotificationContent()
    content.title = "Household"
    content.body = "Saloni made 2 changes to Household\n• Updated Chase Checking\n• Added a transaction at Shell"
    content.userInfo = [
        SharedChangeNotifications.moduleUserInfoKey: "finance",
        SharedChangeNotifications.rootUserInfoKey: "x-coredata://store/SharedFinanceHousehold/p1",
        SharedChangeNotifications.changesUserInfoKey: ["Updated Chase Checking", "Added a transaction at Shell"],
    ]
    let digest = try #require(SharedChangeDigest(content: content))
    #expect(digest.moduleID == "finance")
    #expect(digest.title == "Household")
    #expect(digest.summary == "Saloni made 2 changes to Household", "The first line, without the bullets")
    #expect(digest.changes == ["Updated Chase Checking", "Added a transaction at Shell"])
}

@Test func aSingleChangeOrAnICloudAlertOpensNoList() {
    #expect(SharedChangeDigest(content: localContent(module: "trips")) == nil)
    #expect(SharedChangeDigest(content: serverContent(zoneSubscriptionID: "multitrack.alert.trips.\(tripZone)")) == nil)
}

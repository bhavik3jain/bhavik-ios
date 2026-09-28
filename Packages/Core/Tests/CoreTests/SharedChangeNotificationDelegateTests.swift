import Foundation
import Testing
import UserNotifications
@testable import Core

// The delegate's completion handlers must be called on the main thread.
// UIKit's handler for a tap updates the app-switcher snapshot, and that
// asserts it is on the main thread. When the delegate implemented the
// `async` forms, Swift ran them on its cooperative pool and called UIKit's
// handler from there, so tapping any notification crashed the app (TestFlight
// build 16: SIGABRT on `com.apple.root.user-initiated-qos.cooperative` in
// `-[UIApplication _performBlockAfterCATransactionCommitSynchronizes:]`).
// These tests reach the delegate the way UIKit does, from the main thread
// through its Objective-C completion-handler selectors. Against that build
// they fail.

/// `UNNotification` and `UNNotificationResponse` have no public initializers,
/// so these use the framework's own class constructors. If an SDK ever drops
/// them, `#require` fails the test by name instead of letting it pass.
private func delivered(_ content: UNNotificationContent) -> UNNotification? {
    let request = UNNotificationRequest(identifier: "test", content: content, trigger: nil)
    return (UNNotification.self as AnyObject)
        .perform(NSSelectorFromString("notificationWithRequest:date:"), with: request, with: Date())?
        .takeUnretainedValue() as? UNNotification
}

private func tapped(_ notification: UNNotification) -> UNNotificationResponse? {
    (UNNotificationResponse.self as AnyObject)
        .perform(
            NSSelectorFromString("responseWithNotification:actionIdentifier:"),
            with: notification,
            with: UNNotificationDefaultActionIdentifier
        )?
        .takeUnretainedValue() as? UNNotificationResponse
}

/// Passed along, never read by the delegate. `UNUserNotificationCenter.current()`
/// throws in a test runner, which has no app bundle, so this is an allocated,
/// uninitialized instance that is never sent a message. It is kept for the
/// life of the process so it is never deallocated.
private nonisolated(unsafe) let center: UNUserNotificationCenter = {
    let allocated = (UNUserNotificationCenter.self as AnyObject).perform(NSSelectorFromString("alloc"))
    return allocated!.takeRetainedValue() as! UNUserNotificationCenter
}()

/// No tracker named, so a tap changes no shared state.
private func plainContent() -> UNNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = "Rome & Amalfi"
    return content
}

@MainActor
@Test func aTapIsAnsweredOnTheMainThread() async throws {
    let notification = try #require(delivered(plainContent()))
    let response = try #require(tapped(notification))
    let delegate: any UNUserNotificationCenterDelegate = SharedChangeNotificationDelegate.shared
    let answeredOnMain = await withCheckedContinuation { continuation in
        delegate.userNotificationCenter?(center, didReceive: response) {
            continuation.resume(returning: Thread.isMainThread)
        }
    }
    #expect(answeredOnMain, "UIKit's tap handler asserts it's on the main thread")
}

@MainActor
@Test func aNotificationInFrontIsAnsweredOnTheMainThread() async throws {
    let notification = try #require(delivered(plainContent()))
    let delegate: any UNUserNotificationCenterDelegate = SharedChangeNotificationDelegate.shared
    let answeredOnMain = await withCheckedContinuation { continuation in
        delegate.userNotificationCenter?(center, willPresent: notification) { _ in
            continuation.resume(returning: Thread.isMainThread)
        }
    }
    #expect(answeredOnMain)
}

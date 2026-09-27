import CloudKit
import Core

// Tapping a CloudKit share-invitation link (email, Messages) has to land
// somewhere. On a scene-based app the non-deprecated entry point is a
// UIWindowSceneDelegate method, which only exists if something supplies scene
// configuration — hence the UIApplicationDelegate below as well. Neither of
// these APIs has a SwiftUI-native equivalent, so App/Sources (the composition
// root, exempt from the "no #if os" rule — see CLAUDE.md) is where they live.
//
// Both platforms forward straight to ShareAcceptRouter.shared, which is what
// actually knows how to accept a share into the right module's store. There
// is deliberately no per-module logic here.

#if os(iOS)
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    // CloudKit's silent pushes are what make mirroring import a partner's
    // change within seconds instead of at the next foreground. The container
    // is widely reported to register on its own, but Apple documents no such
    // promise; registering here costs nothing if it's redundant, and needs the
    // aps-environment entitlement to get a token at all.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    // Supplying scene configuration is the only way to name a custom
    // UIWindowSceneDelegate — without it there is nowhere for
    // windowScene(_:userDidAcceptCloudKitShareWith:) to be called.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    // When the tap launches the app rather than bringing it forward, the
    // invitation arrives here and the callback below is never called. This
    // path wasn't wired up at first, so an invite opened with the app closed
    // opened the app and did nothing.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            ShareAcceptRouter.shared.accept(metadata)
        }
    }

    // The app was already running when the invitation was accepted.
    func windowScene(
        _ windowScene: UIWindowScene,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        ShareAcceptRouter.shared.accept(cloudKitShareMetadata)
    }
}
#endif

#if os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Same reason as the iOS delegate's registration: CloudKit's pushes, so a
    // partner's change imports within seconds while the app is running.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.registerForRemoteNotifications()
    }

    // macOS has no scene layer to thread this through — the app delegate
    // gets the callback directly, whether or not the app was running.
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        ShareAcceptRouter.shared.accept(metadata)
    }
}
#endif

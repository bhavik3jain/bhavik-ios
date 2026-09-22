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
    // Called after the user taps "Accept" on a share invitation while the app
    // is already running. (The not-running case arrives via
    // scene(_:willConnectTo:options:)'s connectionOptions instead — not
    // wired up here, since nothing in this app can currently be shared yet.)
    // NB for whoever registers the first container with ShareAcceptRouter:
    // its own doc comment notes `accept` keys off `metadata.rootRecord`, but
    // the metadata the OS hands this callback only has that populated if
    // something asked for it with CKFetchShareMetadataOperation's
    // shouldFetchRootRecord — which nothing has, at this stage. Passing it
    // straight through (as here) will read as unroutable until a re-fetch
    // step is added once there's a real container to route to.
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
    // macOS has no scene layer to thread this through — the app delegate
    // gets the callback directly. Same rootRecord caveat as the iOS side
    // above.
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        ShareAcceptRouter.shared.accept(metadata)
    }
}
#endif

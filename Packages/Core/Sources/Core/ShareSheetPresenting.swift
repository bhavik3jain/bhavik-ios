import CoreData
import SwiftUI

/// What a feature package hands up when it wants to show this platform's real
/// CKShare sharing UI for one object — `UICloudSharingController` on iOS, a
/// custom SwiftUI sheet on macOS (no AppKit equivalent exists). Neither type
/// is visible from here; this struct is the only vocabulary a feature package
/// needs.
public struct ShareSheetRequest: Identifiable {
    public let id = UUID()
    public let object: NSManagedObject
    public let container: NSPersistentCloudKitContainer

    public init(object: NSManagedObject, container: NSPersistentCloudKitContainer) {
        self.object = object
        self.container = container
    }
}

public extension EnvironmentValues {
    /// Set once, at the App-shell composition root (`App/Sources/ShareSheetHost.swift`,
    /// via `BhavikApp`'s own `@State`), to whatever this platform's real
    /// sharing UI is. A feature package's Share button calls this instead of
    /// importing `UICloudSharingController` or any AppKit equivalent — see
    /// CLAUDE.md's macOS section for why that UI lives in `App/Sources` rather
    /// than behind a `MacCompat.swift` shim: the two platforms genuinely want
    /// different sharing UI, not the same call site with a no-op stand-in.
    ///
    /// `@Entry` (the same macro `ModuleManagedObjectContexts.swift` uses for
    /// its own per-module context keys) rather than a hand-written
    /// `EnvironmentKey`: a manually written `static let defaultValue` closure
    /// here hits Swift 6 strict concurrency's conformance-isolation check —
    /// `EnvironmentKey.defaultValue` is a `nonisolated` protocol requirement,
    /// so a witness that's `@MainActor`-isolated (needed here, since the real
    /// closures this carries mutate a `@MainActor` `@State` var) can't satisfy
    /// it by hand. The macro generates a conformance that does.
    @Entry var presentShareSheet: (ShareSheetRequest) -> Void = { _ in }
}

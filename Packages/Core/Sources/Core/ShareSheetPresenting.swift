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
    ///
    /// The value is a `PresentShareSheetAction`, not the bare closure it used
    /// to be: a closure isn't comparable, so SwiftUI treated every update of
    /// the host as a new value and invalidated every view reading this key,
    /// `TripDetailView` among them (Xcode 27 warns "Storing a closure in
    /// '@Entry' may invalidate dependents on every update").
    @Entry var presentShareSheet = PresentShareSheetAction { _ in }
}

/// `\.presentShareSheet`'s value, shaped like SwiftUI's own `DismissAction`:
/// call it as a function — `presentShareSheet(request)` — and it compares
/// equal to any other, so re-setting it never invalidates its readers.
///
/// Always-equal is safe because a host never changes what its action means
/// over its lifetime. On both platforms it writes the host's own `@State` —
/// the `SharePreparer` on iOS, the sheet's request on macOS — whose storage
/// belongs to the host's identity, not to the closure value. A reader sits
/// under exactly one host, and a new host brings new readers with it.
public struct PresentShareSheetAction: Equatable {
    private let action: (ShareSheetRequest) -> Void

    public init(_ action: @escaping (ShareSheetRequest) -> Void) {
        self.action = action
    }

    public func callAsFunction(_ request: ShareSheetRequest) {
        action(request)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { true }
}

import Combine
import CoreData

/// A live-updating fetch of one entity type against an explicit
/// `NSManagedObjectContext`, for the one situation `@FetchRequest` cannot
/// cover: a view that needs Core Data results from a context other than
/// whatever SwiftUI's own `\.managedObjectContext` environment key resolves
/// to for it.
///
/// `@FetchRequest` always reads that single ambient key. Trips claimed it at
/// `BhavikApp`'s `WindowGroup` level (see `ModuleManagedObjectContexts.swift`),
/// so a second module's `@FetchRequest` declared on the same top-level view —
/// `HomeView`'s Fuel summary, `AppSettingsView`'s Fuel counts — cannot bind to
/// its own store through that key. This fetches directly against whatever
/// context it's handed instead, and stays current the way `@FetchRequest`
/// does: by subscribing to that context's own save notifications and
/// re-fetching.
///
/// Cleanup goes through Combine's own `AnyCancellable`, cancelled by its
/// `deinit` when this object deallocates, rather than a manual
/// `removeObserver` in a `deinit` of our own — this class is `@MainActor`,
/// and reading a main-actor stored property from a plain (nonisolated)
/// `deinit` is exactly the kind of thing Swift 6's strict concurrency
/// checking rejects.
@MainActor
public final class ManagedObjectFetch<Object: NSManagedObject>: ObservableObject {
    @Published public private(set) var results: [Object] = []

    private let request: NSFetchRequest<Object>
    private weak var context: NSManagedObjectContext?
    private var saveSubscription: AnyCancellable?

    public init(_ request: NSFetchRequest<Object>) {
        self.request = request
    }

    /// Call from a `.task(id: context)` (or similar) on first appearance —
    /// the environment value a view is handed isn't available until SwiftUI
    /// actually builds it, so this can't simply run from `init`. Safe to call
    /// again with the same context; only a genuinely new one re-subscribes.
    public func start(context: NSManagedObjectContext) {
        guard self.context !== context else { return }
        self.context = context
        refresh()
        saveSubscription = NotificationCenter.default
            .publisher(for: .NSManagedObjectContextDidSave, object: context)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        guard let context else { return }
        results = (try? context.fetch(request)) ?? []
    }
}

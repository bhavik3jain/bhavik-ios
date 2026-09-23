import Foundation

/// Which trackers the home screen shows, and in what order.
///
/// Identifies trackers by plain string IDs so Core needn't know the app's own
/// module enum. A stored layout is never trusted as-is: it may have been
/// written by an older or newer build on another device, so it's always
/// passed through `resolved(against:)` with the IDs this build knows about.
public struct TrackerLayout: Codable, Equatable, Sendable {
    /// Every tracker, visible or not, in display order.
    public private(set) var order: [String]
    public private(set) var hidden: Set<String>

    public init(order: [String], hidden: Set<String> = []) {
        self.order = order
        self.hidden = hidden
    }

    /// The known trackers in their given order, all visible.
    public static func `default`(for known: [String]) -> TrackerLayout {
        TrackerLayout(order: known).resolved(against: known)
    }

    /// Fits this layout to the trackers that actually exist. Stored IDs this
    /// build doesn't know are dropped; known IDs the stored order lacks are
    /// appended, visible — so a tracker added in a later version turns up at
    /// the end rather than never appearing on a device whose layout predates it.
    public func resolved(against known: [String]) -> TrackerLayout {
        let knownSet = Set(known)
        var seen = Set<String>()
        // Dedupes as well as filters: another device's data is only as good as
        // whatever build wrote it.
        var order = self.order.filter { knownSet.contains($0) && seen.insert($0).inserted }
        order += known.filter { seen.insert($0).inserted }
        var layout = TrackerLayout(order: order, hidden: hidden.intersection(knownSet))
        // Hiding the last visible tracker is refused below, but a layout can
        // still arrive with none left — say, the only visible one was a tracker
        // this build has dropped. An empty home screen reads as data loss.
        if layout.visible.isEmpty, let first = layout.order.first {
            layout.hidden.remove(first)
        }
        return layout
    }

    /// The trackers to show, in display order.
    public var visible: [String] {
        order.filter { !hidden.contains($0) }
    }

    public func isHidden(_ id: String) -> Bool {
        hidden.contains(id)
    }

    /// False for the last visible tracker, so the home screen can't be emptied.
    public func canHide(_ id: String) -> Bool {
        !isHidden(id) && visible.count > 1
    }

    /// Hides or shows a tracker. Hiding the last visible one is ignored — see
    /// `canHide(_:)`.
    public mutating func setHidden(_ isHidden: Bool, for id: String) {
        guard order.contains(id) else { return }
        if isHidden {
            guard canHide(id) else { return }
            hidden.insert(id)
        } else {
            hidden.remove(id)
        }
    }

    /// Reorders `order` with the same semantics as SwiftUI's `onMove`:
    /// `destination` is an offset in the list *before* the move. Written out
    /// rather than calling SwiftUI's `move(fromOffsets:toOffset:)` so this type
    /// stays free of SwiftUI.
    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let source = source.filteredIndexSet { order.indices.contains($0) }
        guard !source.isEmpty else { return }
        let destination = min(max(destination, 0), order.count)
        let moving = source.map { order[$0] }
        for index in source.reversed() {
            order.remove(at: index)
        }
        let insertAt = destination - source.count(in: 0..<destination)
        order.insert(contentsOf: moving, at: insertAt)
    }
}

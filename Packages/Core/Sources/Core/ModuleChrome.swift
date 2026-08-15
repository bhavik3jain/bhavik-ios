import SwiftUI

/// The way back to the hub from inside a module.
///
/// Modules are presented as full-screen covers, which carry no dismiss control
/// of their own, so each one puts a Home tab alongside its own tabs. Selecting
/// it closes the module rather than showing a screen, which is why it needs the
/// handling below rather than being an ordinary tab.
public enum ModuleTab {
    /// The value the Home tab carries. Unlikely to collide with a module's own
    /// tab names.
    public static let home = "module.home"
}

private struct HomeTabDismissal: ViewModifier {
    @Binding var selection: String
    let fallback: String
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.onChange(of: selection) { _, current in
            guard current == ModuleTab.home else { return }
            // Put the selection back before leaving, so the module opens on its
            // own first tab next time rather than on the Home tab.
            selection = fallback
            dismiss()
        }
    }
}

public extension View {
    /// Closes the module when its Home tab is selected.
    ///
    /// - Parameters:
    ///   - selection: the `TabView`'s selection.
    ///   - fallback: the tab to restore before leaving.
    func dismissesOnHomeTab(_ selection: Binding<String>, restoringTo fallback: String) -> some View {
        modifier(HomeTabDismissal(selection: selection, fallback: fallback))
    }
}

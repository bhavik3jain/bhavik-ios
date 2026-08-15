import SwiftUI

/// Puts a way back to the hub on a module's screens.
///
/// Modules are presented as full-screen covers, which come with no dismiss
/// control of their own, so each one carries this instead.
public struct ModuleDismissButton: ToolbarContent {
    @Environment(\.dismiss) private var dismiss
    private let accent: ModuleAccent

    public init(accent: ModuleAccent) {
        self.accent = accent
    }

    public var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                dismiss()
            } label: {
                Label("Trackers", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline)
            }
            .tint(accent.color)
        }
    }
}

public extension View {
    /// Adds the hub back button to a module's root screen, alongside whatever
    /// else the screen puts in its toolbar.
    ///
    /// Everything goes in one `toolbar` call: a screen that declares two of
    /// them can end up with the items from the second drawn but inert.
    func moduleChrome<Extra: ToolbarContent>(
        accent: ModuleAccent,
        @ToolbarContentBuilder items: () -> Extra
    ) -> some View {
        toolbar {
            ModuleDismissButton(accent: accent)
            items()
        }
    }

    /// The back button on its own, for screens with no toolbar of their own.
    func moduleChrome(accent: ModuleAccent) -> some View {
        toolbar { ModuleDismissButton(accent: accent) }
    }
}

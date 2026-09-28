import SwiftUI

public extension View {
    /// A form-like screen held to a readable width in the Mac's sidebar
    /// layout, centred like a System Settings pane. Across a full window a
    /// balance sat a foot from the account it belonged to. No-op on the phone.
    func readableWidthInSidebar(_ maxWidth: CGFloat = 820) -> some View {
        modifier(ReadableWidthInSidebar(maxWidth: maxWidth))
    }
}

private struct ReadableWidthInSidebar: ViewModifier {
    let maxWidth: CGFloat
    @Environment(\.moduleLayout) private var layout

    func body(content: Content) -> some View {
        if layout == .sidebar {
            content
                .frame(maxWidth: maxWidth)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}

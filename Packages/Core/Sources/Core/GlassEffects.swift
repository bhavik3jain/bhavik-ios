import SwiftUI

/// Liquid Glass where the system has it, and a sensible equivalent where it
/// doesn't.
///
/// The app deploys to iOS 18, so it can't call the iOS 26 glass APIs directly.
/// Keeping the availability checks here means the screens read as intent —
/// "this is the primary action" — rather than being peppered with version
/// checks, and the fallback is decided once instead of per call site.
public extension View {
    /// The main call to action on a screen.
    ///
    /// Glass belongs to controls floating above content, which is exactly what
    /// a primary button is; content itself is deliberately left alone.
    @ViewBuilder
    func primaryActionStyle(tint: Color) -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent).tint(tint)
        } else {
            buttonStyle(.borderedProminent).tint(tint)
        }
    }

    /// Lets the tab bar shrink out of the way as a long list is scrolled.
    @ViewBuilder
    func minimizesTabBarOnScroll() -> some View {
        if #available(iOS 26, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }
}
